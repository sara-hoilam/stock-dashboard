-- Ticker Alpha — market news
--
-- Apply after 0007. Safe to re-run.

create table if not exists ledger.news (
  url        text primary key,
  title      text not null,
  summary    text,
  image      text,
  publisher  text,
  symbol     text,
  published  timestamptz,
  kind       text,
  updated_at timestamptz not null default now()
);
create index if not exists news_published_idx on ledger.news (published desc);
create index if not exists news_symbol_idx    on ledger.news (symbol);

create table if not exists ledger.news_keyword (
  word       text primary key,
  count      integer not null,
  kind       text,
  updated_at timestamptz not null default now()
);

alter table ledger.news         enable row level security;
alter table ledger.news_keyword enable row level security;

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

-- One call serves the whole page: the article list, the filter chips, and a
-- short digest for the ticker feed.
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
      select jsonb_agg(jsonb_build_object('word', word, 'count', count, 'kind', kind)
             order by kind, count desc)
      from ledger.news_keyword), '[]'::jsonb),

    'newest', (select max(published) from ledger.news));
$$;

-- The scrolling ticker: everything from the last day, trimmed to a headline
-- and a couple of sentences.
create or replace function public.get_news_feed(p_hours integer default 24,
                                                p_limit integer default 30)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'url', f.url, 'title', f.title, 'summary', f.summary,
           'symbol', f.symbol, 'published', f.published) order by f.published desc), '[]'::jsonb)
  from (
    select n.url, n.title,
           -- Two sentences is enough to know whether to read the rest.
           case when length(n.summary) > 220
                then left(n.summary, 217) || '…' else n.summary end as summary,
           n.symbol, n.published
    from ledger.news n
    where n.published > now() - make_interval(hours => greatest(1, p_hours))
    order by n.published desc
    limit greatest(1, least(coalesce(p_limit, 30), 60))
  ) f;
$$;

-- ---------------------------------------------------------------------------
-- Writes — worker only
-- ---------------------------------------------------------------------------
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
  insert into ledger.news_keyword (word, count, kind, updated_at)
  select distinct on (r->>'word')
         r->>'word', (r->>'count')::integer, r->>'kind', now()
  from jsonb_array_elements(p_keywords) r
  where r->>'word' is not null
  order by r->>'word';

  -- A rolling window; older articles are not what this page is for.
  delete from ledger.news where published < now() - interval '7 days';
  return n;
end;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.get_news(text, integer, integer)',
    'public.get_news_feed(integer, integer)'
  ] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
  execute 'revoke all on function public.upsert_news(jsonb, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_news(jsonb, jsonb) to service_role';
end $$;
