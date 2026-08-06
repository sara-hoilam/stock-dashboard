-- Portfolio add-form fields: unrealized / realized P/L on each transaction.
-- Apply after 0034. Safe to re-run.

alter table public.portfolio_transaction
  add column if not exists unrealized_pl numeric(20,8),
  add column if not exists realized_pl   numeric(20,8);

create or replace function public.add_portfolio_transaction(
  p_symbol        text,
  p_kind          text,
  p_trade_date    date,
  p_quantity      numeric,
  p_price         numeric,
  p_fee           numeric default 0,
  p_note          text default null,
  p_unrealized_pl numeric default null,
  p_realized_pl   numeric default null
)
returns jsonb
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := auth.uid();
  v_pf   uuid;
  v_sym  text := upper(trim(coalesce(p_symbol, '')));
  v_kind text := lower(trim(coalesce(p_kind, '')));
  v_id   bigint;
  v_held numeric;
begin
  if v_uid is null then
    return jsonb_build_object('error', 'not signed in');
  end if;
  if v_sym !~ '^[A-Z][A-Z.\-]{0,9}$' then
    return jsonb_build_object('error', 'not a ticker');
  end if;
  if v_kind not in ('buy','sell','dividend','split','fee','deposit','withdrawal') then
    return jsonb_build_object('error', 'bad kind');
  end if;
  if p_trade_date is null then
    return jsonb_build_object('error', 'trade date required');
  end if;
  if v_kind in ('buy','sell') and (p_quantity is null or p_quantity <= 0) then
    return jsonb_build_object('error', 'quantity must be positive');
  end if;
  if v_kind in ('buy','sell') and (p_price is null or p_price < 0) then
    return jsonb_build_object('error', 'price required');
  end if;

  select id into v_pf from public.portfolio
   where user_id = v_uid order by created_at limit 1;
  if v_pf is null then
    insert into public.portfolio (user_id, name, base_currency)
    values (v_uid, 'My portfolio', 'USD')
    returning id into v_pf;
  end if;

  if v_kind = 'sell' then
    select coalesce(sum(case kind when 'buy' then quantity
                                  when 'sell' then -quantity else 0 end), 0)
      into v_held
      from public.portfolio_transaction
     where portfolio_id = v_pf and symbol = v_sym;
    if p_quantity > v_held then
      return jsonb_build_object('error', 'sell exceeds holdings',
                                'held', v_held);
    end if;
  end if;

  insert into public.portfolio_transaction
    (portfolio_id, symbol, kind, trade_date, quantity, price, fee, note,
     unrealized_pl, realized_pl)
  values (v_pf, v_sym, v_kind, p_trade_date, p_quantity, p_price,
          coalesce(p_fee, 0), p_note, p_unrealized_pl, p_realized_pl)
  returning id into v_id;

  return jsonb_build_object(
    'id', v_id,
    'portfolioId', v_pf,
    'symbol', v_sym,
    'kind', v_kind,
    'tradeDate', p_trade_date,
    'quantity', p_quantity,
    'price', p_price,
    'unrealizedPl', p_unrealized_pl,
    'realizedPl', p_realized_pl);
end;
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
               'name', coalesce(q.name, qd.name, c.name, t.name),
               'price', coalesce(q.price, qd.price),
               'changePct', coalesce(q.change_pct, qd.change_pct),
               'previousClose', qd.previous_close,
               'marketCap', coalesce(q.market_cap, qd.market_cap))
             order by p.symbol)
      from public.portfolio_position p
      left join ledger.quote        q  on q.symbol  = p.symbol
      left join ledger.quote_detail qd on qd.symbol = p.symbol
      left join ledger.ticker       t  on t.ticker  = p.symbol
      left join ledger.company      c  on c.ticker  = p.symbol
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

create or replace function public.merge_portfolio(p_transactions jsonb)
returns jsonb
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_pf  uuid;
  v_row jsonb;
  v_n   integer := 0;
  v_sym text;
  v_kind text;
begin
  if v_uid is null then
    return jsonb_build_object('error', 'not signed in');
  end if;
  if p_transactions is null or jsonb_typeof(p_transactions) <> 'array' then
    return jsonb_build_object('merged', 0);
  end if;

  select id into v_pf from public.portfolio
   where user_id = v_uid order by created_at limit 1;
  if v_pf is null then
    insert into public.portfolio (user_id, name, base_currency)
    values (v_uid, 'My portfolio', 'USD')
    returning id into v_pf;
  end if;

  for v_row in select * from jsonb_array_elements(p_transactions)
  loop
    v_sym  := upper(trim(coalesce(v_row->>'symbol', '')));
    v_kind := lower(trim(coalesce(v_row->>'kind', 'buy')));
    if v_sym !~ '^[A-Z][A-Z.\-]{0,9}$' then continue; end if;
    if v_kind not in ('buy','sell','dividend','split','fee','deposit','withdrawal')
      then continue; end if;
    if (v_row->>'tradeDate') is null then continue; end if;

    insert into public.portfolio_transaction
      (portfolio_id, symbol, kind, trade_date, quantity, price, fee, note,
       unrealized_pl, realized_pl)
    values (
      v_pf, v_sym, v_kind,
      (v_row->>'tradeDate')::date,
      nullif(v_row->>'quantity', '')::numeric,
      nullif(v_row->>'price', '')::numeric,
      coalesce(nullif(v_row->>'fee', '')::numeric, 0),
      v_row->>'note',
      nullif(v_row->>'unrealizedPl', '')::numeric,
      nullif(v_row->>'realizedPl', '')::numeric);
    v_n := v_n + 1;
  end loop;

  return jsonb_build_object('merged', v_n, 'portfolioId', v_pf);
end;
$$;

do $$
begin
  -- Drop the previous 7-arg overload so PostgREST resolves the new one.
  begin
    execute 'drop function if exists public.add_portfolio_transaction(text,text,date,numeric,numeric,numeric,text)';
  exception when undefined_function then null;
  end;

  execute 'revoke all on function public.add_portfolio_transaction(text,text,date,numeric,numeric,numeric,text,numeric,numeric) from public, anon';
  execute 'grant execute on function public.add_portfolio_transaction(text,text,date,numeric,numeric,numeric,text,numeric,numeric) to authenticated';
  execute 'revoke all on function public.get_portfolio() from public, anon';
  execute 'grant execute on function public.get_portfolio() to authenticated';
  execute 'revoke all on function public.merge_portfolio(jsonb) from public, anon';
  execute 'grant execute on function public.merge_portfolio(jsonb) to authenticated';
end $$;
