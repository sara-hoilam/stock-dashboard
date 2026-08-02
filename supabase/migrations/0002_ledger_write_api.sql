-- Ledger — write API for the ingest worker
--
-- Apply after 0001. Supabase SQL Editor → paste → Run.
--
-- Why this exists: the `ledger` schema is deliberately not exposed to
-- PostgREST, which means the worker cannot POST to the tables either. Rather
-- than expose the schema (and weaken the read side), the worker gets a small
-- set of write functions in `public`, executable by `service_role` alone.
--
-- The service_role key never reaches a browser — it lives only in the
-- worker's environment — so this surface is not publicly reachable.

-- ---------------------------------------------------------------------------
-- Ticker directory, refreshed daily from sec.gov/files/company_tickers.json
-- ---------------------------------------------------------------------------
create or replace function public.upsert_directory(p_rows jsonb)
returns integer
language plpgsql
volatile
security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  insert into ledger.company (cik, ticker, name)
  select (r->>'cik')::integer, r->>'ticker', r->>'name'
  from jsonb_array_elements(p_rows) r
  on conflict (cik) do update
    set ticker     = excluded.ticker,
        name       = excluded.name,
        updated_at = now();
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- One company's full model, written atomically
-- ---------------------------------------------------------------------------
-- Takes the payload edgar.build_company() produces (plus any breakdowns) and
-- replaces that company's quarters and breakdowns in a single transaction, so
-- a reader never sees a half-written company.
create or replace function public.ingest_company(p jsonb)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ledger, pg_temp
as $$
declare
  v_cik integer := (p->>'cik')::integer;
  v_q   integer := 0;
  v_b   integer := 0;
begin
  insert into ledger.company (cik, ticker, name, exchange, sic, fye_month, checked_at, updated_at)
  values (v_cik, p->>'ticker', p->>'name', p->>'exchange', p->>'sic',
          nullif(p->>'fye_month','')::smallint, now(), now())
  on conflict (cik) do update
    set ticker     = excluded.ticker,
        name       = excluded.name,
        exchange   = coalesce(excluded.exchange, ledger.company.exchange),
        sic        = coalesce(excluded.sic, ledger.company.sic),
        fye_month  = coalesce(excluded.fye_month, ledger.company.fye_month),
        checked_at = now(),
        updated_at = now();

  -- Filings we have seen, for bookkeeping and retry.
  insert into ledger.filing (accession, cik, form, filed_date, period_end, status, parsed_at)
  select r->>'accession', v_cik, r->>'form',
         (r->>'filed')::date, nullif(r->>'periodEnd','')::date,
         coalesce(r->>'status','ok'), now()
  from jsonb_array_elements(coalesce(p->'filings','[]'::jsonb)) r
  where r->>'accession' is not null
  on conflict (accession) do update
    set status    = excluded.status,
        parsed_at = now();

  -- Quarters: replace wholesale. A restatement can change earlier quarters,
  -- so the newest parse of a company always wins.
  delete from ledger.quarter where cik = v_cik;

  insert into ledger.quarter
    (cik, period_end, fy, fq, start_date, basis, form, accession, filed_date, lines, provenance)
  select v_cik,
         (r->>'end')::date,
         (r->>'fy')::smallint,
         (r->>'fq')::smallint,
         nullif(r->>'start','')::date,
         r->>'basis',
         r->>'form',
         r->>'accession',
         nullif(r->>'filed','')::date,
         coalesce(r->'lines','{}'::jsonb),
         r->'provenance'
  from jsonb_array_elements(coalesce(p->'quarters','[]'::jsonb)) r
  where r->>'end' is not null;
  get diagnostics v_q = row_count;

  insert into ledger.breakdown (cik, period_end, name, source, basis, rows)
  select v_cik, (r->>'period_end')::date, r->>'name', r->>'source', r->>'basis',
         coalesce(r->'rows','[]'::jsonb)
  from jsonb_array_elements(coalesce(p->'breakdowns','[]'::jsonb)) r
  where r->>'period_end' is not null
    and exists (select 1 from ledger.quarter q
                 where q.cik = v_cik and q.period_end = (r->>'period_end')::date)
  on conflict (cik, period_end, name) do update
    set source = excluded.source,
        basis  = excluded.basis,
        rows   = excluded.rows;
  get diagnostics v_b = row_count;

  return jsonb_build_object('cik', v_cik, 'quarters', v_q, 'breakdowns', v_b);
end;
$$;

-- ---------------------------------------------------------------------------
-- Backfill queue
-- ---------------------------------------------------------------------------
-- Claim one pending request. `skip locked` means several workers would not
-- collide, though only one should ever run against the SEC.
create or replace function public.claim_backfill()
returns jsonb
language plpgsql
volatile
security definer
set search_path = ledger, pg_temp
as $$
declare v_id bigint; v_ticker text;
begin
  update ledger.backfill_request b
     set claimed_at = now()
   where b.id = (select id from ledger.backfill_request
                  where claimed_at is null and done_at is null
                  order by requested_at
                  limit 1 for update skip locked)
  returning b.id, b.ticker into v_id, v_ticker;

  if v_id is null then
    return null;
  end if;
  return jsonb_build_object('id', v_id, 'ticker', v_ticker);
end;
$$;

create or replace function public.finish_backfill(p_id bigint, p_error text default null)
returns void
language sql
volatile
security definer
set search_path = ledger, pg_temp
as $$
  update ledger.backfill_request
     set done_at = now(), error = p_error
   where id = p_id;
$$;

-- Companies whose filing list has not been checked against the SEC lately.
-- Drives the scheduled refresh.
create or replace function public.companies_due(p_hours integer default 6,
                                                p_limit integer default 50)
returns jsonb
language sql
stable
security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object('cik', cik, 'ticker', ticker)), '[]'::jsonb)
  from (
    select cik, ticker
    from ledger.company
    where checked_at is not null
      and checked_at < now() - make_interval(hours => greatest(1, p_hours))
    order by checked_at
    limit greatest(1, least(p_limit, 500))
  ) s;
$$;

-- Has this filing already been parsed? Keeps the worker from redoing work.
create or replace function public.filing_seen(p_accession text)
returns boolean
language sql
stable
security definer
set search_path = ledger, pg_temp
as $$
  select exists (select 1 from ledger.filing
                  where accession = p_accession and status = 'ok');
$$;

-- Record a filing we could not parse, so it shows as "no breakdown" rather
-- than being retried forever or, worse, guessed at.
create or replace function public.record_filing_failure(
  p_accession text, p_cik integer, p_form text,
  p_filed date, p_period_end date, p_error text)
returns void
language sql
volatile
security definer
set search_path = ledger, pg_temp
as $$
  insert into ledger.filing (accession, cik, form, filed_date, period_end,
                             status, attempts, error, parsed_at)
  values (p_accession, p_cik, p_form, p_filed, p_period_end,
          'failed', 1, left(p_error, 500), now())
  on conflict (accession) do update
    set status   = 'failed',
        attempts = ledger.filing.attempts + 1,
        error    = left(p_error, 500),
        parsed_at = now();
$$;

-- Coverage, for the worker's logs and a status endpoint later.
create or replace function public.ledger_stats()
returns jsonb
language sql
stable
security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'companies_in_directory', (select count(*) from ledger.company),
    'companies_with_data',    (select count(distinct cik) from ledger.quarter),
    'quarters',               (select count(*) from ledger.quarter),
    'breakdowns',             (select count(*) from ledger.breakdown),
    'filings_ok',             (select count(*) from ledger.filing where status = 'ok'),
    'filings_failed',         (select count(*) from ledger.filing where status = 'failed'),
    'backfill_pending',       (select count(*) from ledger.backfill_request
                                where done_at is null),
    'newest_filing',          (select max(filed_date) from ledger.quarter));
$$;

-- ---------------------------------------------------------------------------
-- Grants — the write surface belongs to the worker alone
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.upsert_directory(jsonb)',
    'public.ingest_company(jsonb)',
    'public.claim_backfill()',
    'public.finish_backfill(bigint, text)',
    'public.companies_due(integer, integer)',
    'public.filing_seen(text)',
    'public.record_filing_failure(text, integer, text, date, date, text)',
    'public.ledger_stats()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
