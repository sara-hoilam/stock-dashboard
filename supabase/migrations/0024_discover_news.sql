-- Ticker Alpha — Discover feed for Markets Today
--
-- Apply after 0023. Safe to re-run.
--
-- A curated slice of ledger.news for the carousel under Sector Movements:
-- stories about the twenty largest quoted companies, or about government /
-- policy subjects (Fed, tariffs, rates, war, …). Same corpus the News page
-- reads; filtered here so the market page does not have to.

create or replace function public.get_discover_news(p_limit integer default 12)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with top_cap as (
    select q.symbol
    from ledger.quote q
    where q.market_cap is not null
      and q.price is not null
    order by q.market_cap desc nulls last
    limit 20
  ),
  -- Prefer illustrated stories for the carousel; fall back to text-only if
  -- the illustrated pool is thin.
  ranked as (
    select n.url, n.title, n.summary, n.image, n.publisher, n.symbol, n.published,
           (n.image is not null and n.image <> '') as has_image
    from ledger.news n
    where n.published > now() - interval '7 days'
      and (
        n.symbol in (select symbol from top_cap)
        -- Ticker mentioned in the headline even when FMP left symbol null.
        or exists (
          select 1 from top_cap t
          where length(t.symbol) >= 2
            and n.title ~* ('(^|[^A-Za-z])' || t.symbol || '([^A-Za-z]|$)'))
        or n.title ~* '(fed|fomc|tariff|tariffs|interest rates?|inflation|wars?|sanctions?|white house|treasury|recession|jobs report|ukraine|gaza|china trade|central bank|congress|regulation|geopolit|s&p[[:space:]]*500|nasdaq[[:space:]]*(composite|100)|dow jones)'
        or n.summary ~* '(fed|fomc|tariff|interest rates?|inflation|wars?|sanctions?|white house|treasury|recession|jobs report|ukraine|central bank|geopolit|s&p[[:space:]]*500)'
      )
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'url', f.url,
           'title', f.title,
           'summary', case when length(f.summary) > 220
                           then left(f.summary, 217) || '…' else f.summary end,
           'image', f.image,
           'publisher', f.publisher,
           'symbol', f.symbol,
           'published', f.published)
         order by f.has_image desc, f.published desc), '[]'::jsonb)
  from (
    select *
    from ranked
    order by has_image desc, published desc
    limit greatest(1, least(coalesce(p_limit, 12), 24))
  ) f;
$$;

do $$
begin
  execute 'revoke all on function public.get_discover_news(integer) from public';
  execute 'grant execute on function public.get_discover_news(integer) to anon, authenticated';
end $$;
