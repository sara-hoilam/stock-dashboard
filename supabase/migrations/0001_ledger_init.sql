-- Ledger — initial schema
--
-- Apply to a NEW, EMPTY Supabase project (not the Minion AI one).
-- Supabase SQL Editor → paste → Run. Or: supabase db push.
--
-- Design notes
--   * All tables live in the `ledger` schema, which is NOT exposed to the API.
--     PostgREST cannot reach them at all.
--   * The browser only ever calls four SECURITY DEFINER functions in `public`.
--     They are the entire public surface. Anon has execute on those and
--     nothing else.
--   * Every SECURITY DEFINER function pins `search_path`, so a hijacked
--     search path cannot redirect a table reference.
--   * Nothing here is a system of record: every row is reproducible from SEC
--     EDGAR. Losing this database costs a re-ingest, not data.

create schema if not exists ledger;

-- Keep the API surface off the data. anon/authenticated get no rights here.
revoke all on schema ledger from public;
revoke all on schema ledger from anon, authenticated;

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- Every SEC filer that carries a ticker. Refreshed daily from
-- sec.gov/files/company_tickers.json.
create table if not exists ledger.company (
  cik         integer primary key,
  ticker      text        not null,
  name        text        not null,
  exchange    text,
  sic         text,
  fye_month   smallint,
  checked_at  timestamptz,               -- last time we asked SEC for filings
  updated_at  timestamptz not null default now()
);
create index if not exists company_ticker_idx on ledger.company (upper(ticker));
create index if not exists company_name_idx   on ledger.company (lower(name));

-- One row per periodic filing we have seen, whether or not it parsed.
-- `status` is what keeps the pipeline honest: a filing that fails to parse is
-- recorded as failed and surfaces as "no breakdown", never as a guess.
create table if not exists ledger.filing (
  accession   text primary key,
  cik         integer not null references ledger.company(cik) on delete cascade,
  form        text    not null,
  filed_date  date    not null,
  period_end  date,
  status      text    not null default 'pending'
              check (status in ('pending','ok','failed','skipped')),
  attempts    smallint not null default 0,
  error       text,
  parsed_at   timestamptz
);
create index if not exists filing_cik_idx     on ledger.filing (cik, filed_date desc);
create index if not exists filing_pending_idx on ledger.filing (status, filed_date)
  where status in ('pending','failed');

-- One row per fiscal quarter. `lines` holds the income-statement and cash-flow
-- figures exactly as edgar.py produces them; `provenance` records which were
-- reported and which were computed.
create table if not exists ledger.quarter (
  cik         integer  not null references ledger.company(cik) on delete cascade,
  period_end  date     not null,
  fy          smallint not null,
  fq          smallint not null check (fq between 1 and 4),
  start_date  date,
  basis       text     not null check (basis in ('reported','derived')),
  form        text,
  accession   text,
  filed_date  date,
  lines       jsonb    not null,
  provenance  jsonb,
  updated_at  timestamptz not null default now(),
  primary key (cik, period_end)
);
create index if not exists quarter_lookup_idx on ledger.quarter (cik, period_end desc);

-- Revenue breakdowns. A company can disclose several cuts of the same revenue
-- (by segment, by product, by geography), so this is one row per cut.
create table if not exists ledger.breakdown (
  cik         integer not null,
  period_end  date    not null,
  name        text    not null,
  source      text,
  basis       text,
  rows        jsonb   not null,
  primary key (cik, period_end, name),
  foreign key (cik, period_end)
    references ledger.quarter(cik, period_end) on delete cascade
);

-- Companies a visitor asked for that we have not ingested yet. The worker
-- polls this; the browser subscribes to `quarter` via Realtime to know when
-- the answer lands.
create table if not exists ledger.backfill_request (
  id           bigserial primary key,
  ticker       text        not null,
  requested_at timestamptz not null default now(),
  claimed_at   timestamptz,
  done_at      timestamptz,
  error        text
);
create index if not exists backfill_open_idx on ledger.backfill_request (requested_at)
  where done_at is null;

-- Belt and braces: the schema is unexposed and ungranted, but enable RLS so
-- that exposing it later still denies by default.
alter table ledger.company          enable row level security;
alter table ledger.filing           enable row level security;
alter table ledger.quarter          enable row level security;
alter table ledger.breakdown        enable row level security;
alter table ledger.backfill_request enable row level security;

-- ---------------------------------------------------------------------------
-- Public API — the only things the browser can call
-- ---------------------------------------------------------------------------

-- Typeahead. Exact ticker first, then ticker prefix, then name match.
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
    select c.ticker, c.cik, c.name
    from ledger.company c
    where coalesce(q, '') <> ''
      and (upper(c.ticker) like upper(q) || '%' or c.name ilike '%' || q || '%')
    order by (upper(c.ticker) = upper(q)) desc,
             (upper(c.ticker) like upper(q) || '%') desc,
             c.ticker
    limit greatest(1, least(coalesce(lim, 12), 25))
  ) s;
$$;

-- Everything the dashboard needs for one company, in the shape the existing
-- frontend already expects from /api/company.
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
  where upper(c.ticker) = upper(p_ticker);
$$;

-- The revenue breakdowns for one quarter.
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
  join ledger.company c on c.cik = b.cik
  where upper(c.ticker) = upper(p_ticker)
    and b.period_end = p_end;
$$;

-- Ask the worker to ingest a company we do not hold yet. Only tickers that
-- exist in the SEC directory can be queued, and repeat asks inside ten minutes
-- collapse into one, so this cannot be used to make us hammer the SEC.
create or replace function public.request_backfill(p_ticker text)
returns jsonb
language plpgsql
volatile
security definer
set search_path = ledger, pg_temp
as $$
declare
  v_cik    integer;
  v_recent integer;
begin
  select cik into v_cik from ledger.company where upper(ticker) = upper(p_ticker);
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

-- ---------------------------------------------------------------------------
-- Grants — deny by default, then hand out exactly four functions
-- ---------------------------------------------------------------------------

revoke all on function public.search_companies(text, int) from public;
revoke all on function public.get_company(text)           from public;
revoke all on function public.get_segments(text, date)    from public;
revoke all on function public.request_backfill(text)      from public;

grant execute on function public.search_companies(text, int) to anon, authenticated;
grant execute on function public.get_company(text)           to anon, authenticated;
grant execute on function public.get_segments(text, date)    to anon, authenticated;
grant execute on function public.request_backfill(text)      to anon, authenticated;

-- The ingest worker connects with the service_role key, which bypasses RLS and
-- needs no grants here.

-- ---------------------------------------------------------------------------
-- Realtime — let the browser see a backfill land without polling
-- ---------------------------------------------------------------------------
-- Run once; harmless if the publication already contains the table.
do $$
begin
  alter publication supabase_realtime add table ledger.quarter;
exception
  when duplicate_object then null;
  when undefined_object then null;
end $$;
