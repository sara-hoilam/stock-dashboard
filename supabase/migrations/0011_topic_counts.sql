-- Ticker Alpha — count topics against the stored corpus, not the fetched batch
--
-- Apply after 0010. Safe to re-run.
--
-- The worker counted each topic across the articles it had just fetched, but
-- ledger.news keeps a seven-day window, so every chip undercounted: "Nasdaq"
-- read 2 and its filter returned 21. A count that does not match what clicking
-- it produces is worse than no count.
--
-- news_keyword is now a catalogue -- label, query, kind, position -- and the
-- count is computed here, over the same rows the filter searches, so the two
-- cannot disagree. A topic with nothing behind it does not come back at all.

alter table ledger.news_keyword add column if not exists ord integer;

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
               'word', k.word, 'query', k.q, 'count', k.n, 'kind', k.kind)
             -- Subjects by how much news there is; companies by size, which
             -- is the order the worker wrote and the reason they are listed.
             order by case k.kind when 'topic' then 0 else 1 end,
                      case when k.kind = 'topic' then -k.n
                           else coalesce(k.ord, 999) end,
                      k.word)
      from (
        select w.word, w.kind, w.ord, coalesce(w.query, w.word) as q,
               (select count(*) from ledger.news n
                where n.symbol = upper(coalesce(w.query, w.word))
                   or n.title   ilike '%' || coalesce(w.query, w.word) || '%'
                   or n.summary ilike '%' || coalesce(w.query, w.word) || '%') as n
        from ledger.news_keyword w
      ) k
      where k.n > 0), '[]'::jsonb),

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
  insert into ledger.news_keyword (word, query, count, kind, ord, updated_at)
  select distinct on (r->>'word')
         r->>'word', coalesce(nullif(r->>'query',''), r->>'word'),
         0, r->>'kind', (r->>'ord')::integer, now()
  from jsonb_array_elements(p_keywords) r
  where r->>'word' is not null
  order by r->>'word';

  delete from ledger.news where published < now() - interval '7 days';
  return n;
end;
$$;

do $$
begin
  execute 'revoke all on function public.get_news(text, integer, integer) from public';
  execute 'grant execute on function public.get_news(text, integer, integer) to anon, authenticated';
  execute 'revoke all on function public.upsert_news(jsonb, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_news(jsonb, jsonb) to service_role';
end $$;
