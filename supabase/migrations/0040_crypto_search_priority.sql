-- Ticker Alpha — prioritize major crypto pairs in search
--
-- Apply after 0039. Safe to re-run.
--
-- Queries like "bitcoin", "ethereum", "solana" should surface BTCUSD / ETHUSD /
-- SOLUSD above lesser *USD tokens that also match the name.

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
  -- Common coin names / tickers → canonical FMP USD pair.
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
      ('polygon', 'MATICUSD'), ('matic', 'MATICUSD'), ('maticusd', 'MATICUSD'),
      ('binance', 'BNBUSD'), ('bnb', 'BNBUSD'), ('bnbusd', 'BNBUSD'),
      ('toncoin', 'TONUSD'), ('ton', 'TONUSD'), ('tonusd', 'TONUSD'),
      ('shiba', 'SHIBUSD'), ('shib', 'SHIBUSD'), ('shibusd', 'SHIBUSD')
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
           case m.kind when 'etf' then 1 else 2 end as kind_rank
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
              -- Exact alias → canonical pair (bitcoin → BTCUSD) first.
              (exists (
                 select 1 from crypto_alias a
                  where a.alias = p.qlow and a.symbol = c.ticker)) desc,
              -- Major pairs whose name/ticker still match the query.
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
  execute 'revoke all on function public.search_companies(text, integer) from public';
  execute 'grant execute on function public.search_companies(text, integer) to anon, authenticated';
end $$;
