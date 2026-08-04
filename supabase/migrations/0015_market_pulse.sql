-- Market pulse — the four metrics above Market Summary, plus Fear & Greed.
--
-- FMP does not publish a Fear & Greed index or a single "total US market cap"
-- figure. Coverage market cap is summed from the heatmap universe we already
-- store; SPY and breadth come from quotes; Fear & Greed is pulled by the
-- worker from CNN's public dataviz endpoint (not FMP) and cached here.
--
-- Apply in the Supabase SQL editor after 0014, then restart the ingest worker.

create table if not exists ledger.sentiment (
  key          text primary key,          -- e.g. 'fear_greed'
  score        double precision not null,
  rating       text,
  previous     double precision,
  source       text,
  updated_at   timestamptz not null default now()
);

alter table ledger.sentiment enable row level security;

create or replace function public.upsert_sentiment(p_key text, p_score double precision,
                                                   p_rating text default null,
                                                   p_previous double precision default null,
                                                   p_source text default null)
returns void
language sql volatile security definer
set search_path = ledger, pg_temp
as $$
  insert into ledger.sentiment (key, score, rating, previous, source, updated_at)
  values (p_key, p_score, p_rating, p_previous, p_source, now())
  on conflict (key) do update
    set score = excluded.score, rating = excluded.rating,
        previous = excluded.previous, source = excluded.source,
        updated_at = now();
$$;

-- Everything the pulse bar needs in one round trip.
create or replace function public.get_market_pulse()
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'asOf', (select max(as_of) from ledger.heatmap),

    -- Cap-weighted coverage of the heatmap universe (not the whole US market —
    -- FMP has no such aggregate). Change is the same weights on day moves.
    'marketCap', (
      select case when coalesce(sum(market_cap), 0) = 0 then null
             else jsonb_build_object(
               'value', sum(market_cap),
               'changePct', round((sum(market_cap * change_pct)
                                   / nullif(sum(market_cap), 0))::numeric, 2))
             end
      from ledger.heatmap
      where market_cap is not null and change_pct is not null),

    'spy', (
      select jsonb_build_object('symbol', symbol, 'price', price,
                                'changePct', change_pct, 'name', name)
      from ledger.quote where symbol = 'SPY'),

    'breadth', (
      select case when count(*) = 0 then null
             else jsonb_build_object(
               'up', count(*) filter (where change_pct > 0),
               'total', count(*),
               'avgChange', round(avg(change_pct)::numeric, 2),
               'score', round((100.0 * count(*) filter (where change_pct > 0)
                               / count(*))::numeric, 0))
             end
      from ledger.quote),

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

do $$
begin
  execute 'revoke all on function public.upsert_sentiment(text, double precision, text, double precision, text) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_sentiment(text, double precision, text, double precision, text) to service_role';
  execute 'revoke all on function public.get_market_pulse() from public';
  execute 'grant execute on function public.get_market_pulse() to anon, authenticated';
end $$;
