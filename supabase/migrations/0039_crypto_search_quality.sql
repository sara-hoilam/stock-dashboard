-- Ticker Alpha — fix crypto search quality (BITCOINUSD meme-coin trap)
--
-- Apply after 0038. Safe to re-run.
--
-- FMP labels BITCOINUSD as "HarryPotterObamaSonic10Inu…"; real Bitcoin is
-- BTCUSD. Searching "bitcoin" was ranking the ticker-prefix hit first.
-- Drop mismatched long *USD stems and prefer name matches in search.

-- Remove already-synced crypto rows whose long USD stem is absent from the name.
delete from ledger.market_symbol m
 where m.kind = 'crypto'
   and m.symbol ~ 'USD$'
   and length(m.symbol) > 3
   and length(m.symbol) - 3 >= 6
   and strpos(
         upper(regexp_replace(m.name, '[^A-Za-z0-9]', '', 'g')),
         left(m.symbol, length(m.symbol) - 3)
       ) = 0;

-- Prefer name matches over ticker-prefix-only hits (BITCOINUSD vs Bitcoin USD).
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
