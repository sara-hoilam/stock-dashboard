-- Ticker Alpha — the scrolling ticker tape above the nav
--
-- Apply after 0008. Safe to re-run.
--
-- No new table. Everything the tape needs is already being written by the
-- worker: the index ETFs and watchlist in ledger.quote, the large-cap
-- universe in ledger.heatmap, and the day's movers in ledger.mover. This
-- function is only the union of those three, deduplicated, with the indexes
-- pinned to the front so the tape opens on the market rather than on whatever
-- happens to be biggest.

create or replace function public.get_ticker_tape(p_limit integer default 180)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with pooled as (
    -- Index ETFs first, in a fixed order, so the tape reads the same way
    -- every session.
    select q.symbol, q.name, q.price, q.change_pct,
           0 as tier,
           array_position(array['SPY','QQQ','DIA','IWM'], q.symbol)::double precision as ord
    from ledger.quote q
    where q.symbol in ('SPY','QQQ','DIA','IWM') and q.price is not null

    union all
    -- The large-cap universe, biggest first. These are the S&P 500 and
    -- Nasdaq 100 names the heatmap already tracks.
    select h.symbol, h.name, h.price, h.change_pct,
           1 as tier,
           -coalesce(h.market_cap, 0) as ord
    from ledger.heatmap h
    where h.price is not null

    union all
    -- The rest of the watchlist.
    select q.symbol, q.name, q.price, q.change_pct,
           2 as tier,
           -coalesce(q.market_cap, 0) as ord
    from ledger.quote q
    where q.price is not null

    union all
    -- Whatever moved today, which is often not a mega-cap at all.
    select m.symbol, m.name, m.price, m.change_pct,
           3 as tier,
           m.rank::double precision as ord
    from ledger.mover m
    where m.price is not null
  ),
  ranked as (
    select distinct on (symbol) symbol, name, price, change_pct, tier, ord
    from pooled
    order by symbol, tier, ord
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', r.symbol, 'name', r.name,
           'price', r.price, 'changePct', r.change_pct)
         order by r.tier, r.ord), '[]'::jsonb)
  from (
    select * from ranked
    order by tier, ord
    limit greatest(4, least(coalesce(p_limit, 180), 400))
  ) r;
$$;

do $$
begin
  execute 'revoke all on function public.get_ticker_tape(integer) from public';
  execute 'grant execute on function public.get_ticker_tape(integer) to anon, authenticated';
end $$;
