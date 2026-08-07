-- Ticker Alpha — FMP ETF + cryptocurrency symbols for search / portfolio
--
-- Apply after 0037. Safe to re-run.
--
-- SEC company_tickers.json misses many ETFs (e.g. VOO) and all crypto.
-- The worker syncs FMP etf-list + cryptocurrency-list into ledger.market_symbol.
-- search_companies unions them with SEC tickers; company.html opens a
-- chart-only view for these (no SEC filings).

create table if not exists ledger.market_symbol (
  symbol     text primary key,
  name       text not null,
  kind       text not null check (kind in ('etf', 'crypto')),
  exchange   text,
  updated_at timestamptz not null default now()
);
create index if not exists market_symbol_kind_idx
  on ledger.market_symbol (kind);
create index if not exists market_symbol_name_idx
  on ledger.market_symbol (name);

alter table ledger.market_symbol enable row level security;

-- Upsert a batch of market symbols (worker / service_role).
create or replace function public.upsert_market_symbols(p_rows jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    return 0;
  end if;

  insert into ledger.market_symbol (symbol, name, kind, exchange, updated_at)
  select upper(trim(r->>'symbol')),
         trim(r->>'name'),
         lower(trim(r->>'kind')),
         nullif(trim(r->>'exchange'), ''),
         now()
  from jsonb_array_elements(p_rows) r
  where nullif(trim(r->>'symbol'), '') is not null
    and nullif(trim(r->>'name'), '') is not null
    and lower(trim(r->>'kind')) in ('etf', 'crypto')
    and upper(trim(r->>'symbol')) ~ '^[A-Z][A-Z.\-]{0,9}$'
  on conflict (symbol) do update set
    name = excluded.name,
    kind = excluded.kind,
    exchange = excluded.exchange,
    updated_at = now();

  get diagnostics n = row_count;
  return n;
end;
$$;

-- Look up one FMP market symbol (ETF / crypto).
create or replace function public.get_market_symbol(p_symbol text)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select case when m.symbol is null then null
         else jsonb_build_object(
           'symbol', m.symbol,
           'name', m.name,
           'kind', m.kind,
           'exchange', m.exchange)
         end
  from (select upper(trim(coalesce(p_symbol, ''))) as sym) q
  left join ledger.market_symbol m on m.symbol = q.sym
  where q.sym ~ '^[A-Z][A-Z.\-]{0,9}$';
$$;

-- Search SEC tickers + FMP ETF/crypto. SEC wins on ticker collisions.
create or replace function public.search_companies(q text, lim int default 12)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with params as (
    select trim(coalesce(q, '')) as q,
           greatest(1, least(coalesce(lim, 12), 25)) as lim
  ),
  sec as (
    select t.ticker,
           t.name,
           t.cik,
           'stock'::text as kind,
           0 as kind_rank
      from ledger.ticker t, params p
     where p.q <> ''
       and (t.ticker like upper(p.q) || '%' or t.name ilike '%' || p.q || '%')
  ),
  mkt as (
    select m.symbol as ticker,
           m.name,
           null::integer as cik,
           m.kind,
           case m.kind when 'etf' then 1 else 2 end as kind_rank
      from ledger.market_symbol m, params p
     where p.q <> ''
       and (m.symbol like upper(p.q) || '%' or m.name ilike '%' || p.q || '%')
       -- Prefer the SEC row when the same ticker exists there (e.g. SPY).
       and not exists (
             select 1 from ledger.ticker t where t.ticker = m.symbol)
  ),
  combined as (
    select * from sec
    union all
    select * from mkt
  )
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'ticker', s.ticker,
      'cik', s.cik,
      'name', s.name,
      'kind', s.kind)),
    '[]'::jsonb)
  from (
    select c.ticker, c.cik, c.name, c.kind
      from combined c, params p
     order by (c.ticker = upper(p.q)) desc,
              (c.ticker like upper(p.q) || '%') desc,
              c.kind_rank,
              (exists (select 1 from ledger.quarter x where x.cik = c.cik)) desc,
              length(c.ticker), c.ticker
     limit (select lim from params)
  ) s;
$$;

do $$
begin
  execute 'revoke all on function public.upsert_market_symbols(jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_market_symbols(jsonb) to service_role';

  execute 'revoke all on function public.get_market_symbol(text) from public';
  execute 'grant execute on function public.get_market_symbol(text) to anon, authenticated';

  execute 'revoke all on function public.search_companies(text, integer) from public';
  execute 'grant execute on function public.search_companies(text, integer) to anon, authenticated';
end $$;
