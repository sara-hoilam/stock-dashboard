-- Ticker Alpha — classify portfolio holdings via market_symbol (ETF / crypto)
--
-- Apply after 0040. Safe to re-run.
--
-- The Total Assets donut previously used a small hardcoded ETF list, so tickers
-- like SPYI were counted as Stocks. Prefer ledger.market_symbol.kind.

create or replace function public.get_market_symbols(p_symbols text[])
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', m.symbol,
           'name', m.name,
           'kind', m.kind,
           'exchange', m.exchange)
         order by m.symbol), '[]'::jsonb)
    from ledger.market_symbol m
   where m.symbol = any (
           select upper(trim(s))
             from unnest(coalesce(p_symbols, array[]::text[])) as s
            where upper(trim(s)) ~ '^[A-Z][A-Z.\-]{0,9}$');
$$;

create or replace function public.get_portfolio()
returns jsonb
language plpgsql stable security definer
set search_path = public, ledger, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_pf  uuid;
  v_name text;
  v_ccy  text;
begin
  if v_uid is null then
    return jsonb_build_object('error', 'not signed in');
  end if;

  select id, name, base_currency into v_pf, v_name, v_ccy
    from public.portfolio
   where user_id = v_uid
   order by created_at
   limit 1;

  if v_pf is null then
    return jsonb_build_object(
      'portfolio', null,
      'positions', '[]'::jsonb,
      'transactions', '[]'::jsonb);
  end if;

  return jsonb_build_object(
    'portfolio', jsonb_build_object(
      'id', v_pf, 'name', v_name, 'baseCurrency', v_ccy),
    'positions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'symbol', p.symbol,
               'quantity', p.quantity,
               'costIn', p.cost_in,
               'proceeds', p.proceeds,
               'dividends', p.dividends,
               'avgCost', case when p.quantity <> 0
                               then p.cost_in / p.quantity else null end,
               'firstTrade', p.first_trade,
               'lastTrade', p.last_trade,
               'unrealizedPl', (
                  select x.unrealized_pl from public.portfolio_transaction x
                   where x.portfolio_id = p.portfolio_id and x.symbol = p.symbol
                     and x.unrealized_pl is not null
                   order by x.trade_date desc, x.id desc limit 1),
               'realizedPl', (
                  select coalesce(sum(x.realized_pl), 0)
                    from public.portfolio_transaction x
                   where x.portfolio_id = p.portfolio_id and x.symbol = p.symbol
                     and x.realized_pl is not null),
               'name', coalesce(q.name, qd.name, c.name, t.name, m.name),
               'assetKind', m.kind,
               'price', coalesce(q.price, qd.price),
               'changePct', coalesce(q.change_pct, qd.change_pct),
               'previousClose', qd.previous_close,
               'marketCap', coalesce(q.market_cap, qd.market_cap))
             order by p.symbol)
      from public.portfolio_position p
      left join ledger.quote          q  on q.symbol  = p.symbol
      left join ledger.quote_detail   qd on qd.symbol = p.symbol
      left join ledger.ticker         t  on t.ticker  = p.symbol
      left join ledger.company        c  on c.ticker  = p.symbol
      left join ledger.market_symbol  m  on m.symbol  = p.symbol
      where p.portfolio_id = v_pf), '[]'::jsonb),
    'transactions', coalesce((
      select jsonb_agg(jsonb_build_object(
               'id', x.id,
               'symbol', x.symbol,
               'kind', x.kind,
               'tradeDate', x.trade_date,
               'quantity', x.quantity,
               'price', x.price,
               'fee', x.fee,
               'note', x.note,
               'unrealizedPl', x.unrealized_pl,
               'realizedPl', x.realized_pl,
               'createdAt', x.created_at)
             order by x.trade_date desc, x.id desc)
      from public.portfolio_transaction x
      where x.portfolio_id = v_pf), '[]'::jsonb));
end;
$$;

do $$
begin
  execute 'revoke all on function public.get_market_symbols(text[]) from public';
  execute 'grant execute on function public.get_market_symbols(text[]) to anon, authenticated';
end $$;
