-- Ticker Alpha — upsert_news must qualify its keyword UPDATE
--
-- Apply after 0024. Safe to re-run.
--
-- Supabase rejects unqualified UPDATE/DELETE ("UPDATE requires a WHERE
-- clause"). 0022 recomputed topic counts with:
--
--   update ledger.news_keyword w set count = (...), updated_at = now();
--
-- That aborts every news refresh and restarts the Render worker. The same
-- predicate used for the keyword wipe (`word is not null`) is enough: every
-- row has a non-null primary key.

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
         updated_at = now()
   where w.word is not null;

  return n;
end;
$$;

do $$
begin
  execute 'revoke all on function public.upsert_news(jsonb, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_news(jsonb, jsonb) to service_role';
end $$;
