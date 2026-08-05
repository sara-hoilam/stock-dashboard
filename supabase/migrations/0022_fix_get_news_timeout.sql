-- Ticker Alpha — stop get_news timing out on topic counts
--
-- Apply after 0021. Safe to re-run.
--
-- 0011 counted every chip against ledger.news with a correlated ILIKE on
-- title and summary. That is correct, and too slow for the anon statement
-- timeout: get_news returned 500 ("canceling statement due to statement
-- timeout") while the lighter get_news_feed still worked.
--
-- Counts still use the same match rules as the filter; they are computed
-- once when the worker writes news, and get_news only reads them.

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
               'word', w.word,
               'query', coalesce(w.query, w.word),
               'count', w.count,
               'kind', w.kind)
             order by case w.kind when 'topic' then 0 else 1 end,
                      case when w.kind = 'topic' then -w.count
                           else coalesce(w.ord, 999) end,
                      w.word)
      from ledger.news_keyword w
      where w.count > 0), '[]'::jsonb),

    'newest', (select max(published) from ledger.news));
$$;

create or replace function public.upsert_news(p_rows jsonb, p_keywords jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
set statement_timeout = '60s'
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
  insert into ledger.news_keyword (word, query, count, kind, ord, updated_at)
  select distinct on (r->>'word')
         r->>'word', coalesce(nullif(r->>'query',''), r->>'word'),
         0, r->>'kind', (r->>'ord')::integer, now()
  from jsonb_array_elements(p_keywords) r
  where r->>'word' is not null
  order by r->>'word';

  delete from ledger.news where published < now() - interval '7 days';

  -- Same match rules the filter uses, once per refresh rather than once per
  -- page view. statement_timeout is raised above so a large corpus cannot
  -- abort the write the way it aborted the anon read.
  update ledger.news_keyword w
     set count = (
           select count(*)::integer from ledger.news n
           where n.symbol = upper(coalesce(w.query, w.word))
              or n.title   ilike '%' || coalesce(w.query, w.word) || '%'
              or n.summary ilike '%' || coalesce(w.query, w.word) || '%'),
         updated_at = now();

  return n;
end;
$$;

-- Refresh counts already on disk so the page recovers before the next worker
-- tick. Safe if news_keyword is empty.
do $$
begin
  perform set_config('statement_timeout', '60s', true);
  update ledger.news_keyword w
     set count = (
           select count(*)::integer from ledger.news n
           where n.symbol = upper(coalesce(w.query, w.word))
              or n.title   ilike '%' || coalesce(w.query, w.word) || '%'
              or n.summary ilike '%' || coalesce(w.query, w.word) || '%'),
         updated_at = now()
   where w.word is not null;
end $$;

do $$
begin
  execute 'revoke all on function public.get_news(text, integer, integer) from public';
  execute 'grant execute on function public.get_news(text, integer, integer) to anon, authenticated';
  execute 'revoke all on function public.upsert_news(jsonb, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_news(jsonb, jsonb) to service_role';
end $$;
