-- Ticker Alpha — analyst coverage for the company report
--
-- Apply after 0015. Safe to re-run.
--
-- Consensus targets, the buy/hold/sell tally, the most recent action from each
-- house, and the wire story behind each target change. All of it is FMP's own
-- data -- price-target-consensus, price-target-summary, grades-consensus,
-- grades and price-target-news -- so nothing on this page depends on a scraped
-- or undocumented source.
--
-- Stored per company and filled on demand, the same way prices are: the report
-- opens for any listed company, so none of this can be pre-fetched.

create table if not exists ledger.analyst (
  symbol        text primary key,
  target        jsonb,      -- {high, low, consensus, median}
  target_counts jsonb,      -- coverage over the last month/quarter/year
  consensus     jsonb,      -- {strongBuy, buy, hold, sell, strongSell, rating}
  grades        jsonb,      -- [{date, house, from, to, action}, ...]
  news          jsonb,      -- [{published, title, url, house, target}, ...]
  updated_at    timestamptz not null default now()
);

alter table ledger.analyst enable row level security;

create or replace function public.get_analyst(p_symbol text)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(
    (select jsonb_build_object(
       'target', a.target, 'targetCounts', a.target_counts,
       'consensus', a.consensus, 'grades', a.grades, 'news', a.news,
       'updatedAt', a.updated_at,
       -- A day old is fine for analyst actions; a week is not.
       'stale', a.updated_at < now() - interval '24 hours')
     from ledger.analyst a where a.symbol = upper(p_symbol)),
    jsonb_build_object('stale', true));
$$;

create or replace function public.upsert_analyst(p_symbol text, p_row jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
begin
  insert into ledger.analyst (symbol, target, target_counts, consensus,
                              grades, news, updated_at)
  values (upper(p_symbol), p_row->'target', p_row->'targetCounts',
          p_row->'consensus', p_row->'grades', p_row->'news', now())
  on conflict (symbol) do update
    set target        = excluded.target,
        target_counts = excluded.target_counts,
        consensus     = excluded.consensus,
        grades        = excluded.grades,
        news          = excluded.news,
        updated_at    = now();
  return 1;
end;
$$;

do $$
begin
  execute 'revoke all on function public.get_analyst(text) from public';
  execute 'grant execute on function public.get_analyst(text) to anon, authenticated';
  execute 'revoke all on function public.upsert_analyst(text, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_analyst(text, jsonb) to service_role';
end $$;
