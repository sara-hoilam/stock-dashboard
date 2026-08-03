-- Ticker Alpha — curated news topics, and market-summary views of equal depth
--
-- Apply after 0009. Safe to re-run.

-- ---------------------------------------------------------------------------
-- Topics
-- ---------------------------------------------------------------------------
-- A chip's label and the text it searches for are now separate: "The Fed"
-- searches for "Fed", "Nvidia" searches for the NVDA ticker. Without this
-- column a chip could only ever filter by its own visible text.
alter table ledger.news_keyword add column if not exists query text;

create or replace function public.get_news(p_q text default null,
                                           p_limit integer default 24,
                                           p_offset integer default 0)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'total', (
      select count(*) from ledger.news n
      where coalesce(p_q, '') = ''
         or n.symbol = upper(p_q)
         or n.title ilike '%' || p_q || '%'
         or n.summary ilike '%' || p_q || '%'),

    'articles', coalesce((
      select jsonb_agg(jsonb_build_object(
               'url', a.url, 'title', a.title, 'summary', a.summary,
               'image', a.image, 'publisher', a.publisher,
               'symbol', a.symbol, 'published', a.published)
             order by a.published desc)
      from (
        select * from ledger.news n
        where coalesce(p_q, '') = ''
           or n.symbol = upper(p_q)
           or n.title ilike '%' || p_q || '%'
           or n.summary ilike '%' || p_q || '%'
        order by n.published desc
        limit greatest(1, least(coalesce(p_limit, 24), 60))
        offset greatest(0, coalesce(p_offset, 0))
      ) a), '[]'::jsonb),

    'keywords', coalesce((
      select jsonb_agg(jsonb_build_object(
               'word', word, 'query', coalesce(query, word),
               'count', count, 'kind', kind)
             -- Broad subjects first, then the largest companies, each group
             -- in the order the worker chose.
             order by case kind when 'topic' then 0 else 1 end, count desc, word)
      from ledger.news_keyword), '[]'::jsonb),

    'newest', (select max(published) from ledger.news));
$$;

create or replace function public.upsert_news(p_rows jsonb, p_keywords jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  insert into ledger.news (url, title, summary, image, publisher, symbol,
                           published, kind, updated_at)
  select distinct on (r->>'url')
         r->>'url', r->>'title', r->>'summary', r->>'image', r->>'publisher',
         nullif(r->>'symbol',''), nullif(r->>'published','')::timestamptz,
         r->>'kind', now()
  from jsonb_array_elements(p_rows) r
  where r->>'url' is not null and r->>'title' is not null
  order by r->>'url'
  on conflict (url) do update
    set title = excluded.title, summary = excluded.summary,
        image = excluded.image, publisher = excluded.publisher,
        symbol = excluded.symbol, published = excluded.published,
        updated_at = now();
  get diagnostics n = row_count;

  delete from ledger.news_keyword where word is not null;
  insert into ledger.news_keyword (word, query, count, kind, updated_at)
  select distinct on (r->>'word')
         r->>'word', coalesce(nullif(r->>'query',''), r->>'word'),
         (r->>'count')::integer, r->>'kind', now()
  from jsonb_array_elements(p_keywords) r
  where r->>'word' is not null
  order by r->>'word';

  delete from ledger.news where published < now() - interval '7 days';
  return n;
end;
$$;

-- ---------------------------------------------------------------------------
-- Market summary
-- ---------------------------------------------------------------------------
-- The three views used to read from different tables, so they came back
-- different lengths: 18 by market cap but only 8 gainers, because FMP returns
-- 50 movers and barely any clear the $1B floor.
--
-- All three now rank the same universe -- everything Ticker Alpha prices,
-- which is the watchlist, the heatmap large caps and the day's movers -- so
-- each view returns the same number of rows. "Gainers" therefore means the
-- best performers among the names tracked here, not the whole market.
create or replace function public.get_market_summary(p_view text default 'market_cap',
                                                     p_limit integer default 12)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with universe as (
    select q.symbol, q.name, q.price, q.change, q.change_pct, q.market_cap, 0 as pref
    from ledger.quote q where q.price is not null
    union all
    select h.symbol, h.name, h.price, null::double precision, h.change_pct,
           h.market_cap, 1
    from ledger.heatmap h where h.price is not null
    union all
    select m.symbol, m.name, m.price, m.change, m.change_pct,
           null::double precision, 2
    from ledger.mover m where m.price is not null
  ),
  -- One row per symbol, preferring the table that carries the most detail.
  uniq as (
    select distinct on (symbol) symbol, name, price, change, change_pct, market_cap
    from universe order by symbol, pref
  ),
  ordered as (
    select u.*, row_number() over (order by
             case when p_view = 'market_cap' then -coalesce(u.market_cap, 0)
                  when p_view = 'losers'     then u.change_pct
                  else                           -u.change_pct end
             nulls last) as ord
    from uniq u
    where p_view <> 'market_cap' or u.market_cap is not null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', s.symbol, 'name', s.name, 'price', s.price,
           'change', s.change, 'changePct', s.change_pct,
           'marketCap', s.market_cap) order by s.ord), '[]'::jsonb)
  from ordered s
  where s.ord <= greatest(1, least(coalesce(p_limit, 12), 50));
$$;

do $$
begin
  execute 'revoke all on function public.get_news(text, integer, integer) from public';
  execute 'grant execute on function public.get_news(text, integer, integer) to anon, authenticated';
  execute 'revoke all on function public.get_market_summary(text, integer) from public';
  execute 'grant execute on function public.get_market_summary(text, integer) to anon, authenticated';
  execute 'revoke all on function public.upsert_news(jsonb, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_news(jsonb, jsonb) to service_role';
end $$;
