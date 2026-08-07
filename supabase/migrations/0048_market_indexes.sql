-- Ticker Alpha — major indexes on the Markets pulse, search, and holdings
--
-- Apply after 0047. Safe to re-run.
--
-- FMP serves index quotes as ^GSPC / ^IXIC / ^DJI. We store them under the
-- searchable tickers SPX / IXIC / DJI (caret is not allowed in market_symbol).
-- Constituent weights are market-cap shares of the members we can price.

-- Allow kind = index on market_symbol (search + company.html market-only view).
alter table ledger.market_symbol drop constraint if exists market_symbol_kind_check;
alter table ledger.market_symbol
  add constraint market_symbol_kind_check
  check (kind in ('etf', 'crypto', 'index'));

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
    and lower(trim(r->>'kind')) in ('etf', 'crypto', 'index')
    and upper(trim(r->>'symbol')) ~ '^[A-Z][A-Z0-9.\-]{0,9}$'
  on conflict (symbol) do update set
    name = excluded.name,
    kind = excluded.kind,
    exchange = excluded.exchange,
    updated_at = now();

  get diagnostics n = row_count;
  return n;
end;
$$;

-- Index constituent holdings (worker-written).
create table if not exists ledger.index_holding (
  index_symbol text not null,
  symbol       text not null,
  name         text,
  industry     text,
  weight_pct   double precision,
  rank         integer,
  updated_at   timestamptz not null default now(),
  primary key (index_symbol, symbol)
);
create index if not exists index_holding_idx
  on ledger.index_holding (index_symbol, rank);
alter table ledger.index_holding enable row level security;

create or replace function public.replace_index_holdings(
  p_index text, p_rows jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare
  n integer := 0;
  idx text := upper(trim(coalesce(p_index, '')));
begin
  if idx = '' or p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    return 0;
  end if;
  delete from ledger.index_holding where index_symbol = idx;
  insert into ledger.index_holding
    (index_symbol, symbol, name, industry, weight_pct, rank, updated_at)
  select idx,
         upper(trim(r->>'symbol')),
         nullif(trim(r->>'name'), ''),
         nullif(trim(r->>'industry'), ''),
         nullif(r->>'weightPct', '')::double precision,
         coalesce(nullif(r->>'rank', '')::integer, 0),
         now()
  from jsonb_array_elements(p_rows) r
  where nullif(trim(r->>'symbol'), '') is not null;
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.get_index_holdings(p_symbol text)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', h.symbol,
           'name', h.name,
           'industry', h.industry,
           'weightPct', h.weight_pct,
           'rank', h.rank)
           order by h.rank nulls last, h.weight_pct desc nulls last, h.symbol),
         '[]'::jsonb)
  from ledger.index_holding h
  where h.index_symbol = upper(trim(coalesce(p_symbol, '')));
$$;

-- Pulse: three major indexes + breadth + fear & greed.
create or replace function public.get_market_pulse()
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'asOf', (select max(as_of) from ledger.heatmap),

    'indexes', coalesce((
      select jsonb_agg(jsonb_build_object(
               'symbol', q.symbol,
               'name', coalesce(q.name, q.symbol),
               'price', q.price,
               'change', q.change,
               'changePct', q.change_pct)
             order by array_position(array['SPX','IXIC','DJI'], q.symbol))
      from ledger.quote q
      where q.symbol in ('SPX', 'IXIC', 'DJI')
    ), '[]'::jsonb),

    'breadth', (
      select case when count(*) = 0 then null
             else jsonb_build_object(
               'up', count(*) filter (where change_pct > 0),
               'total', count(*),
               'avgChange', round(avg(change_pct)::numeric, 2),
               'score', round((100.0 * count(*) filter (where change_pct > 0)
                               / count(*))::numeric, 0))
             end
      from ledger.quote
      where symbol not in ('SPX', 'IXIC', 'DJI')),

    'fearGreed', (
      select jsonb_build_object(
               'score', round(score::numeric, 0),
               'rating', rating,
               'previous', previous,
               'source', source,
               'updatedAt', updated_at)
      from ledger.sentiment where key = 'fear_greed')
  );
$$;

-- Search: include indexes; boost common index aliases.
create or replace function public.search_companies(q text, lim int default 12)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with params as (
    select trim(coalesce(q, '')) as q,
           lower(trim(coalesce(q, ''))) as qlow,
           greatest(1, least(coalesce(lim, 12), 25)) as lim
  ),
  crypto_alias(alias, symbol) as (
    values
      ('bitcoin', 'BTCUSD'), ('btc', 'BTCUSD'), ('btcusd', 'BTCUSD'),
      ('ethereum', 'ETHUSD'), ('eth', 'ETHUSD'), ('ethusd', 'ETHUSD'),
      ('solana', 'SOLUSD'), ('sol', 'SOLUSD'), ('solusd', 'SOLUSD'),
      ('dogecoin', 'DOGEUSD'), ('doge', 'DOGEUSD'), ('dogeusd', 'DOGEUSD'),
      ('ripple', 'XRPUSD'), ('xrp', 'XRPUSD'), ('xrpusd', 'XRPUSD'),
      ('cardano', 'ADAUSD'), ('ada', 'ADAUSD'), ('adausd', 'ADAUSD'),
      ('avalanche', 'AVAXUSD'), ('avax', 'AVAXUSD'), ('avaxusd', 'AVAXUSD'),
      ('polkadot', 'DOTUSD'), ('dot', 'DOTUSD'), ('dotusd', 'DOTUSD'),
      ('chainlink', 'LINKUSD'), ('link', 'LINKUSD'), ('linkusd', 'LINKUSD'),
      ('litecoin', 'LTCUSD'), ('ltc', 'LTCUSD'), ('ltcusd', 'LTCUSD'),
      ('polygon', 'POLUSD'), ('matic', 'POLUSD'), ('pol', 'POLUSD'), ('polusd', 'POLUSD'),
      ('binance', 'BNBUSD'), ('bnb', 'BNBUSD'), ('bnbusd', 'BNBUSD'),
      ('toncoin', 'TONUSD'), ('ton', 'TONUSD'), ('tonusd', 'TONUSD'),
      ('shiba', 'SHIBUSD'), ('shib', 'SHIBUSD'), ('shibusd', 'SHIBUSD')
  ),
  index_alias(alias, symbol) as (
    values
      ('s&p', 'SPX'), ('s&p500', 'SPX'), ('s&p 500', 'SPX'), ('sp500', 'SPX'),
      ('spx', 'SPX'), ('gspc', 'SPX'), ('snp', 'SPX'),
      ('nasdaq', 'IXIC'), ('nasdaq composite', 'IXIC'), ('ixic', 'IXIC'),
      ('comp', 'IXIC'), ('ndx', 'IXIC'),
      ('dow', 'DJI'), ('dow jones', 'DJI'), ('djia', 'DJI'), ('dji', 'DJI')
  ),
  major_crypto(symbol) as (
    select distinct symbol from crypto_alias
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
           case m.kind
             when 'index' then 0
             when 'etf' then 1
             else 2
           end as kind_rank
      from ledger.market_symbol m, params p
     where p.q <> ''
       and (m.symbol like upper(p.q) || '%' or m.name ilike '%' || p.q || '%')
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
     order by
              (exists (
                 select 1 from index_alias a
                  where a.alias = p.qlow and a.symbol = c.ticker)) desc,
              (exists (
                 select 1 from crypto_alias a
                  where a.alias = p.qlow and a.symbol = c.ticker)) desc,
              (c.ticker in (select symbol from major_crypto)
                and (c.ticker like upper(p.q) || '%'
                     or c.name ilike '%' || p.q || '%')) desc,
              (c.ticker = upper(p.q)) desc,
              (c.name ilike p.q || '%') desc,
              (c.name ilike '%' || p.q || '%') desc,
              (c.ticker like upper(p.q) || '%'
                and c.name ilike '%' || p.q || '%') desc,
              (c.ticker like upper(p.q) || '%') desc,
              c.kind_rank,
              (exists (select 1 from ledger.quarter x where x.cik = c.cik)) desc,
              length(c.ticker), c.ticker
     limit (select lim from params)
  ) s;
$$;

do $$
begin
  execute 'revoke all on function public.replace_index_holdings(text, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.replace_index_holdings(text, jsonb) to service_role';
  execute 'revoke all on function public.get_index_holdings(text) from public';
  execute 'grant execute on function public.get_index_holdings(text) to anon, authenticated';
  execute 'revoke all on function public.get_market_pulse() from public';
  execute 'grant execute on function public.get_market_pulse() to anon, authenticated';
  execute 'revoke all on function public.search_companies(text, integer) from public';
  execute 'grant execute on function public.search_companies(text, integer) to anon, authenticated';
  execute 'revoke all on function public.upsert_market_symbols(jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_market_symbols(jsonb) to service_role';
end $$;
