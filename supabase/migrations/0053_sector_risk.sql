-- Ticker Alpha — risk and return per sector, for the bubble chart
--
-- Apply after 0052. Safe to re-run.
--
-- Replaces the Sector Rotations line chart, which answered "what moved this
-- month" -- a question the Sector Performance panel beside it already answers.
-- The bubble chart answers a different one: what was the return, what was the
-- volatility paid for it, and how large is the sector.
--
-- The whole matrix is computed in the worker and stored as one blob per
-- sector: seven periods times four intervals times three numbers. That is a
-- few kilobytes against the twenty years of daily closes it is derived from,
-- so changing a filter on the page is a redraw rather than a round trip, and
-- the browser never has to hold a price history to do arithmetic on it.

create table if not exists ledger.sector_risk (
  sector      text primary key,
  etf         text not null,
  cap         double precision,
  -- The fund's first trading day. XLRE launched in 2015 and XLC in 2018, so
  -- a "10Y" view of those is really their whole life; the page says so rather
  -- than comparing an eight-year record against a twenty-year one in silence.
  inception   date,
  stats       jsonb not null,
  updated_at  timestamptz not null default now()
);

alter table ledger.sector_risk enable row level security;

-- ---------------------------------------------------------------------------
-- Read
-- ---------------------------------------------------------------------------
create or replace function public.get_sector_risk()
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'updatedAt', (select max(updated_at) from ledger.sector_risk),
    'sectors', coalesce((
      select jsonb_agg(jsonb_build_object(
               'sector', s.sector, 'etf', s.etf, 'cap', s.cap,
               'inception', s.inception, 'stats', s.stats)
             order by s.cap desc nulls last, s.sector)
      from ledger.sector_risk s), '[]'::jsonb));
$$;

-- ---------------------------------------------------------------------------
-- Write — worker only
-- ---------------------------------------------------------------------------
-- Replace rather than upsert: the eleven sectors are refreshed together, and
-- a sector that stops coming back should leave the chart rather than linger
-- with numbers from last week beside ten fresh ones.
create or replace function public.replace_sector_risk(p_rows jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    return 0;                          -- a failed fetch must not empty the panel
  end if;

  delete from ledger.sector_risk;
  insert into ledger.sector_risk (sector, etf, cap, inception, stats, updated_at)
  select r->>'sector', r->>'etf',
         nullif(r->>'cap', '')::double precision,
         nullif(r->>'inception', '')::date,
         coalesce(r->'stats', '{}'::jsonb),
         now()
  from jsonb_array_elements(p_rows) r
  where coalesce(r->>'sector', '') <> '' and coalesce(r->>'etf', '') <> '';
  get diagnostics n = row_count;
  return n;
end;
$$;

do $$
begin
  execute 'revoke all on function public.get_sector_risk() from public';
  execute 'grant execute on function public.get_sector_risk() to anon, authenticated';
  execute 'revoke all on function public.replace_sector_risk(jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.replace_sector_risk(jsonb) to service_role';
end $$;
