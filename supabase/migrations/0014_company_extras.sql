-- Ticker Alpha — benchmark, seasonality and industry valuation
--
-- Apply after 0013. Safe to re-run.
--
-- Three things the company report needs beyond its own price:
--   * a sector benchmark to plot against. FMP sells no per-industry price
--     index, so the sector SPDR stands in -- eleven ETFs cover every US
--     listing, and being shared they are fetched once, not once per company.
--   * ten years of month-end closes, which is what monthly seasonality is
--     built from. 130 numbers rather than the 2,600 daily ones.
--   * price/earnings by industry and sector. This plan serves only recent
--     dates, so it is a reference value rather than a series, and it is
--     stored once for the whole market.

alter table ledger.price_daily add column if not exists monthly  jsonb;
alter table ledger.price_daily add column if not exists sector   text;
alter table ledger.price_daily add column if not exists industry text;

create table if not exists ledger.benchmark (
  symbol     text primary key,          -- the sector SPDR, e.g. XLY
  closes     jsonb not null,            -- [{d, c}, ...] oldest first
  updated_at timestamptz not null default now()
);

create table if not exists ledger.industry_pe (
  kind       text not null,             -- 'industry' | 'sector'
  name       text not null,
  pe         double precision,
  as_of      date,
  updated_at timestamptz not null default now(),
  primary key (kind, name)
);

alter table ledger.benchmark   enable row level security;
alter table ledger.industry_pe enable row level security;

-- The sector-to-ETF map lives here as well as in the worker, so the read side
-- can resolve a benchmark without the page having to know the mapping.
create or replace function ledger.sector_etf(p_sector text)
returns text
language sql immutable
as $$
  select case p_sector
    when 'Technology'             then 'XLK'
    when 'Financial Services'     then 'XLF'
    when 'Healthcare'             then 'XLV'
    when 'Consumer Cyclical'      then 'XLY'
    when 'Consumer Defensive'     then 'XLP'
    when 'Industrials'            then 'XLI'
    when 'Energy'                 then 'XLE'
    when 'Utilities'              then 'XLU'
    when 'Real Estate'            then 'XLRE'
    when 'Basic Materials'        then 'XLB'
    when 'Communication Services' then 'XLC'
  end;
$$;

-- ---------------------------------------------------------------------------
-- Read
-- ---------------------------------------------------------------------------
-- One call for the four panels that sit above the chart builder. The company's
-- own PE line is not here: it is computed in the page from the EDGAR quarters
-- it already holds, which is a better source than any vendor ratio.
create or replace function public.get_company_extras(p_symbol text)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with me as (
    select * from ledger.price_daily where symbol = upper(p_symbol)
  )
  select jsonb_build_object(
    'monthly',  coalesce((select m.monthly from me m), '[]'::jsonb),
    'sector',   (select m.sector from me m),
    'industry', (select m.industry from me m),

    'benchmark', (
      select jsonb_build_object('symbol', b.symbol, 'closes', b.closes)
      from ledger.benchmark b
      where b.symbol = (select ledger.sector_etf(m.sector) from me m)),

    'industryPe', (
      select p.pe from ledger.industry_pe p
      where p.kind = 'industry' and p.name = (select m.industry from me m)),
    'sectorPe', (
      select p.pe from ledger.industry_pe p
      where p.kind = 'sector' and p.name = (select m.sector from me m)),
    'peAsOf', (select max(as_of) from ledger.industry_pe));
$$;

-- ---------------------------------------------------------------------------
-- Writes — worker only
-- ---------------------------------------------------------------------------
create or replace function public.upsert_company_extras(
    p_symbol text, p_monthly jsonb, p_sector text, p_industry text)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
begin
  update ledger.price_daily
     set monthly  = coalesce(p_monthly, monthly),
         sector   = coalesce(p_sector, sector),
         industry = coalesce(p_industry, industry),
         updated_at = now()
   where symbol = upper(p_symbol);
  return 1;
end;
$$;

create or replace function public.upsert_benchmark(p_symbol text, p_closes jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
begin
  insert into ledger.benchmark (symbol, closes, updated_at)
  values (upper(p_symbol), p_closes, now())
  on conflict (symbol) do update
    set closes = excluded.closes, updated_at = now();
  return 1;
end;
$$;

create or replace function public.replace_industry_pe(p_rows jsonb, p_as_of date)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  delete from ledger.industry_pe where name is not null;
  insert into ledger.industry_pe (kind, name, pe, as_of, updated_at)
  select distinct on (r->>'kind', r->>'name')
         r->>'kind', r->>'name', (r->>'pe')::double precision, p_as_of, now()
  from jsonb_array_elements(p_rows) r
  where r->>'name' is not null
  order by r->>'kind', r->>'name';
  get diagnostics n = row_count;
  return n;
end;
$$;

do $$
declare f text;
begin
  execute 'revoke all on function public.get_company_extras(text) from public';
  execute 'grant execute on function public.get_company_extras(text) to anon, authenticated';
  foreach f in array array[
    'public.upsert_company_extras(text, jsonb, text, text)',
    'public.upsert_benchmark(text, jsonb)',
    'public.replace_industry_pe(jsonb, date)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
