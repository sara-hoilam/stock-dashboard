-- Ticker Alpha — watchlist prices for any followed ticker
--
-- Apply after 0022. Safe to re-run.
--
-- The Markets Today watchlist was filling prices from get_market_summary's
-- top-50 market-cap list. Names people follow that sit outside that list
-- (HOOD, and any smaller ticker) rendered as "—" even when ledger.quote or
-- an intraday series already had a price.
--
-- get_watchlist now falls back to the last intraday / daily close when the
-- quote row is missing. get_symbol_quotes serves the same shape for an
-- arbitrary list, so an unsigned-in local watchlist can resolve prices too.

create or replace function public.get_symbol_quotes(p_symbols text[])
returns jsonb
language sql stable security definer
set search_path = ledger, public, pg_temp
as $$
  with wanted as (
    select upper(trim(s)) as symbol
    from unnest(coalesce(p_symbols, array[]::text[])) as s
    where coalesce(trim(s), '') <> ''
  ),
  priced as (
    select w.symbol,
           coalesce(q.name, c.name, t.name) as name,
           coalesce(
             q.price,
             nullif(i.points->-1->>'c', '')::double precision,
             nullif(d.bars->-1->>'c', '')::double precision
           ) as price,
           q.change_pct as change_pct,
           q.market_cap as market_cap
    from wanted w
    left join ledger.quote q on q.symbol = w.symbol
    left join ledger.intraday i on i.symbol = w.symbol
    left join ledger.price_daily d on d.symbol = w.symbol
    left join ledger.ticker t on t.ticker = w.symbol
    left join ledger.company c on c.ticker = w.symbol
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', p.symbol,
           'name', p.name,
           'price', p.price,
           'changePct', p.change_pct,
           'marketCap', p.market_cap)
         order by p.symbol), '[]'::jsonb)
  from priced p;
$$;

create or replace function public.get_watchlist(p_list uuid default null)
returns jsonb
language sql stable security definer
set search_path = public, ledger, pg_temp
as $$
  with me as (select auth.uid() as uid),
  list as (
    select w.id, w.name
    from public.watchlist w, me
    where w.user_id = me.uid
      and (p_list is null and w.is_default or w.id = p_list)
    limit 1
  )
  select case when auth.uid() is null then jsonb_build_object('error', 'not signed in')
  else jsonb_build_object(
    'list', (select jsonb_build_object('id', id, 'name', name) from list),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'symbol', i.symbol,
               'note', i.note,
               'addedAt', i.added_at,
               'name', coalesce(q.name, c.name, t.name),
               'price', coalesce(
                  q.price,
                  nullif(intra.points->-1->>'c', '')::double precision,
                  nullif(daily.bars->-1->>'c', '')::double precision),
               'changePct', q.change_pct,
               'marketCap', q.market_cap)
             order by coalesce(i.sort_order, 2147483647), i.symbol)
      from public.watchlist_item i
      join list l on l.id = i.watchlist_id
      left join ledger.quote       q     on q.symbol = i.symbol
      left join ledger.intraday    intra on intra.symbol = i.symbol
      left join ledger.price_daily daily on daily.symbol = i.symbol
      left join ledger.ticker      t     on t.ticker = i.symbol
      left join ledger.company     c     on c.ticker = i.symbol), '[]'::jsonb))
  end;
$$;

do $$
begin
  execute 'revoke all on function public.get_symbol_quotes(text[]) from public';
  execute 'grant execute on function public.get_symbol_quotes(text[]) to anon, authenticated';
  execute 'revoke all on function public.get_watchlist(uuid) from public, anon';
  execute 'grant execute on function public.get_watchlist(uuid) to authenticated';
end $$;
