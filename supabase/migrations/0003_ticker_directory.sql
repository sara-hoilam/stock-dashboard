-- Ledger — separate the ticker directory from the company
--
-- Apply after 0002.
--
-- Why: 0001 keyed the directory by CIK, one ticker per company. The SEC
-- directory has 10,412 tickers across 8,000 CIKs — 1,464 companies carry more
-- than one, because of dual-class shares, units, warrants and foreign
-- listings. Keying by CIK silently dropped 2,412 of them, so searching GOOG
-- instead of GOOGL would have found nothing.
--
-- The financial data is still per company (one CIK, one income statement).
-- Only the lookup is per ticker.

create table if not exists ledger.ticker (
  ticker     text primary key,
  cik        integer not null,
  name       text    not null,
  updated_at timestamptz not null default now()
);
create index if not exists ticker_cik_idx  on ledger.ticker (cik);
create index if not exists ticker_name_idx on ledger.ticker (lower(name));

alter table ledger.ticker enable row level security;

-- ---------------------------------------------------------------------------
-- Directory refresh — now keyed by ticker
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
  -- `distinct on` guards against a repeated ticker inside one batch: Postgres
  -- rejects an ON CONFLICT that would touch the same row twice.
  insert into ledger.ticker (ticker, cik, name, updated_at)
  select distinct on (upper(r->>'ticker'))
         upper(r->>'ticker'), (r->>'cik')::integer, r->>'name', now()
  from jsonb_array_elements(p_rows) r
  where r->>'ticker' is not null and r->>'cik' is not null
  order by upper(r->>'ticker')
  on conflict (ticker) do update
    set cik = excluded.cik, name = excluded.name, updated_at = now();
  get diagnostics n = row_count;
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reads, resolving through the directory
-- ---------------------------------------------------------------------------
create or replace function public.search_companies(q text, lim int default 12)
returns jsonb
language sql
stable
security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object('ticker', s.ticker, 'cik', s.cik, 'name', s.name)),
    '[]'::jsonb)
  from (
    select t.ticker, t.cik, t.name
    from ledger.ticker t
    where coalesce(q, '') <> ''
      and (t.ticker like upper(q) || '%' or t.name ilike '%' || q || '%')
    order by (t.ticker = upper(q)) desc,
             (t.ticker like upper(q) || '%') desc,
             -- a company we already hold is more useful than one we do not
             (exists (select 1 from ledger.quarter x where x.cik = t.cik)) desc,
             length(t.ticker), t.ticker
    limit greatest(1, least(coalesce(lim, 12), 25))
  ) s;
$$;

create or replace function public.get_company(p_ticker text)
returns jsonb
language sql
stable
security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'ticker',             c.ticker,
    'name',               c.name,
    'cik',                c.cik,
    'exchange',           c.exchange,
    'sic',                c.sic,
    'fiscalYearEndMonth', c.fye_month,
    'checkedAt',          c.checked_at,
    'source', jsonb_build_object(
      'facts',   'https://data.sec.gov/api/xbrl/companyfacts/CIK'
                 || lpad(c.cik::text, 10, '0') || '.json',
      'filings', 'https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK='
                 || lpad(c.cik::text, 10, '0') || '&type=10-'),
    'quarters', coalesce((
      select jsonb_agg(jsonb_build_object(
               'end',        to_char(q.period_end, 'YYYY-MM-DD'),
               'start',      to_char(q.start_date, 'YYYY-MM-DD'),
               'fy',         q.fy,
               'fq',         q.fq,
               'label',      'Q' || q.fq || ' ' || q.fy,
               'basis',      q.basis,
               'form',       q.form,
               'accession',  q.accession,
               'filed',      to_char(q.filed_date, 'YYYY-MM-DD'),
               'lines',      q.lines,
               'provenance', q.provenance)
             order by q.period_end desc)
      from ledger.quarter q where q.cik = c.cik), '[]'::jsonb))
  from ledger.company c
  where c.cik = (select t.cik from ledger.ticker t where t.ticker = upper(p_ticker));
$$;

create or replace function public.get_segments(p_ticker text, p_end date)
returns jsonb
language sql
stable
security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'name', b.name, 'source', b.source, 'basis', b.basis, 'rows', b.rows)),
    '[]'::jsonb)
  from ledger.breakdown b
  where b.cik = (select t.cik from ledger.ticker t where t.ticker = upper(p_ticker))
    and b.period_end = p_end;
$$;

create or replace function public.request_backfill(p_ticker text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ledger, pg_temp
as $$
declare v_cik integer; v_recent integer;
begin
  select cik into v_cik from ledger.ticker where ticker = upper(p_ticker);
  if v_cik is null then
    return jsonb_build_object('queued', false, 'reason', 'not an SEC-registered ticker');
  end if;

  select count(*) into v_recent
  from ledger.backfill_request
  where upper(ticker) = upper(p_ticker)
    and requested_at > now() - interval '10 minutes';

  if v_recent = 0 then
    insert into ledger.backfill_request (ticker) values (upper(p_ticker));
  end if;
  return jsonb_build_object('queued', true);
end;
$$;

create or replace function public.ledger_stats()
returns jsonb
language sql
stable
security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'tickers_in_directory',   (select count(*) from ledger.ticker),
    'companies_in_directory', (select count(distinct cik) from ledger.ticker),
    'companies_with_data',    (select count(distinct cik) from ledger.quarter),
    'quarters',               (select count(*) from ledger.quarter),
    'breakdowns',             (select count(*) from ledger.breakdown),
    'filings_ok',             (select count(*) from ledger.filing where status = 'ok'),
    'filings_failed',         (select count(*) from ledger.filing where status = 'failed'),
    'backfill_pending',       (select count(*) from ledger.backfill_request
                                where done_at is null),
    'newest_filing',          (select max(filed_date) from ledger.quarter));
$$;

-- Grants for the redefined functions.
do $$
declare f text;
begin
  foreach f in array array[
    'public.upsert_directory(jsonb)',
    'public.ledger_stats()'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;

  foreach f in array array[
    'public.search_companies(text, integer)',
    'public.get_company(text)',
    'public.get_segments(text, date)',
    'public.request_backfill(text)'
  ] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
end $$;
