-- Ticker Alpha — optional symbol filter on get_trades
--
-- Apply after 0043. Safe to re-run.
--
-- Portfolio page passes the user's held tickers so Insider / Congress panels
-- only show filings for those symbols. Markets Today omits p_symbols (all).

create or replace function public.get_trades(
  p_limit integer default 20,
  p_offset integer default 0,
  p_days integer default 7,
  p_kind text default null,
  p_symbols text[] default null
)
returns jsonb
language plpgsql stable security definer
set search_path = ledger, pg_temp
as $$
declare
  v_limit  integer := greatest(1, least(coalesce(p_limit, 20), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_days   integer := greatest(1, least(coalesce(p_days, 7), 90));
  v_kind   text    := lower(nullif(trim(coalesce(p_kind, '')), ''));
  v_cut    date    := current_date - v_days;
  v_ins_min double precision := 1000000;  -- $1M
  v_pct    double precision := 0.01;      -- 1% of shares outstanding
  v_syms   text[];
  v_insiders jsonb := '[]'::jsonb;
  v_congress jsonb := '[]'::jsonb;
  v_ins_total integer := 0;
  v_con_total integer := 0;
begin
  select array_agg(distinct upper(trim(s)))
    into v_syms
    from unnest(coalesce(p_symbols, array[]::text[])) as s
   where upper(trim(s)) ~ '^[A-Z][A-Z.\-]{0,9}$';

  if v_kind is null or v_kind = 'insider' or v_kind = 'insiders' then
    select count(*)::integer into v_ins_total
    from ledger.insider_trade i
    where i.filed >= v_cut
      and (v_syms is null or i.symbol = any (v_syms))
      and (
        abs(coalesce(i.amount, 0)) > v_ins_min
        or (
          coalesce(i.shares_out, 0) > 0
          and coalesce(i.shares, 0) / i.shares_out >= v_pct
        )
      );

    select coalesce(jsonb_agg(jsonb_build_object(
             'filed', x.filed, 'symbol', x.symbol,
             'name', x.name, 'side', x.side, 'shares', x.shares,
             'amount', x.amount, 'person', x.person, 'title', x.title,
             'sharesOut', x.shares_out)
           order by x.filed desc nulls last, x.amount desc nulls last), '[]'::jsonb)
      into v_insiders
    from (
      select i.filed, i.symbol, i.side, i.shares, i.amount, i.person, i.title,
             i.shares_out, coalesce(t.name, c.name) as name
      from ledger.insider_trade i
      left join ledger.ticker  t on t.ticker = i.symbol
      left join ledger.company c on c.ticker = i.symbol
      where i.filed >= v_cut
        and (v_syms is null or i.symbol = any (v_syms))
        and (
          abs(coalesce(i.amount, 0)) > v_ins_min
          or (
            coalesce(i.shares_out, 0) > 0
            and coalesce(i.shares, 0) / i.shares_out >= v_pct
          )
        )
      order by i.filed desc nulls last, i.amount desc nulls last
      limit v_limit offset v_offset
    ) x;
  end if;

  if v_kind is null or v_kind = 'congress' then
    select count(*)::integer into v_con_total
    from ledger.congress_trade g
    where g.disclosed >= v_cut
      and (v_syms is null or g.symbol = any (v_syms));

    select coalesce(jsonb_agg(jsonb_build_object(
             'disclosed', x.disclosed, 'traded', x.traded, 'symbol', x.symbol,
             'name', x.name, 'person', x.person, 'chamber', x.chamber,
             'side', x.side, 'amount', x.amount)
           order by x.disclosed desc nulls last), '[]'::jsonb)
      into v_congress
    from (
      select g.disclosed, g.traded, g.symbol, g.person, g.chamber, g.side, g.amount,
             coalesce(t.name, c.name) as name
      from ledger.congress_trade g
      left join ledger.ticker  t on t.ticker = g.symbol
      left join ledger.company c on c.ticker = g.symbol
      where g.disclosed >= v_cut
        and (v_syms is null or g.symbol = any (v_syms))
      order by g.disclosed desc nulls last
      limit v_limit offset v_offset
    ) x;
  end if;

  return jsonb_build_object(
    'insiders', v_insiders,
    'congress', v_congress,
    'insidersTotal', v_ins_total,
    'congressTotal', v_con_total,
    'days', v_days,
    'limit', v_limit,
    'offset', v_offset,
    'minInsiderAmount', v_ins_min,
    'minCongressAmount', 0,
    'minSharesPct', v_pct);
end;
$$;

do $$
begin
  -- New signature with p_symbols; drop prior 4-arg overload if present.
  begin
    execute 'drop function if exists public.get_trades(integer, integer, integer, text)';
  exception when others then null;
  end;
  execute 'revoke all on function public.get_trades(integer, integer, integer, text, text[]) from public';
  execute 'grant execute on function public.get_trades(integer, integer, integer, text, text[]) to anon, authenticated';
end $$;
