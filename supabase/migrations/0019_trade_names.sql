-- Ticker Alpha — company names on the insider and congressional tables
--
-- Apply after 0018. Safe to re-run.
--
-- The tables showed a column of bare symbols. A reader who follows the market
-- closely still does not know every small cap a senator has traded, and the
-- name is already in ledger.ticker -- it was simply never joined.
--
-- Left joins on purpose: a symbol absent from the directory keeps its row and
-- shows the ticker alone, which is what the page did before.

create or replace function public.get_trades(p_limit integer default 12)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'insiders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'filed', i.filed, 'symbol', i.symbol,
               'name', coalesce(t.name, c.name),
               'side', i.side, 'shares', i.shares,
               'amount', i.amount, 'person', i.person)
             order by i.filed desc nulls last, i.amount desc nulls last)
      from (
        select * from ledger.insider_trade
        order by filed desc nulls last, amount desc nulls last
        limit greatest(1, least(coalesce(p_limit, 12), 50))
      ) i
      left join ledger.ticker  t on t.ticker  = i.symbol
      left join ledger.company c on c.ticker  = i.symbol), '[]'::jsonb),

    'congress', coalesce((
      select jsonb_agg(jsonb_build_object(
               'disclosed', g.disclosed, 'traded', g.traded, 'symbol', g.symbol,
               'name', coalesce(t.name, c.name),
               'person', g.person, 'chamber', g.chamber,
               'side', g.side, 'amount', g.amount)
             order by g.disclosed desc nulls last)
      from (
        select * from ledger.congress_trade
        order by disclosed desc nulls last
        limit greatest(1, least(coalesce(p_limit, 12), 50))
      ) g
      left join ledger.ticker  t on t.ticker  = g.symbol
      left join ledger.company c on c.ticker  = g.symbol), '[]'::jsonb));
$$;

do $$
begin
  execute 'revoke all on function public.get_trades(integer) from public';
  execute 'grant execute on function public.get_trades(integer) to anon, authenticated';
end $$;
