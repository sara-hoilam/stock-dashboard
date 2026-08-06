-- Ticker Alpha — congress: drop $0.5M floor; trade-flow fallback from tables
--
-- Apply after 0041. Safe to re-run.
--
-- Markets Today was filtering congress disclosures to ranges above $0.5M, which
-- left the Congress table empty most weeks. The 60-day inflow/outflow chart
-- also went blank whenever ledger.trade_flow_daily was empty even though the
-- trade tables still had rows — fall back to aggregating those tables.

create or replace function public.get_trades(
  p_limit integer default 20,
  p_offset integer default 0,
  p_days integer default 7,
  p_kind text default null
)
returns jsonb
language plpgsql stable security definer
set search_path = ledger, pg_temp
as $$
declare
  v_limit  integer := greatest(1, least(coalesce(p_limit, 20), 100));
  v_offset integer := greatest(0, coalesce(p_offset, 0));
  v_days   integer := greatest(1, least(coalesce(p_days, 7), 30));
  v_kind   text    := lower(nullif(trim(coalesce(p_kind, '')), ''));
  v_cut    date    := current_date - v_days;
  v_ins_min double precision := 1000000;  -- $1M
  v_pct    double precision := 0.01;      -- 1% of shares outstanding
  v_insiders jsonb := '[]'::jsonb;
  v_congress jsonb := '[]'::jsonb;
  v_ins_total integer := 0;
  v_con_total integer := 0;
begin
  if v_kind is null or v_kind = 'insider' or v_kind = 'insiders' then
    select count(*)::integer into v_ins_total
    from ledger.insider_trade i
    where i.filed >= v_cut
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
    -- No minimum amount: show every disclosure in the window.
    select count(*)::integer into v_con_total
    from ledger.congress_trade g
    where g.disclosed >= v_cut;

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

create or replace function public.get_trade_flow(p_days integer default 60)
returns jsonb
language plpgsql stable security definer
set search_path = ledger, pg_temp
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 60), 120));
  v_cut  date    := current_date - (v_days - 1);
  v_ins  jsonb;
  v_con  jsonb;
  v_ins_n integer := 0;
  v_con_n integer := 0;
begin
  select coalesce(jsonb_agg(jsonb_build_object(
           'day', f.day, 'inflow', f.inflow, 'outflow', f.outflow)
         order by f.day), '[]'::jsonb),
         count(*) filter (where f.inflow > 0 or f.outflow > 0)
    into v_ins, v_ins_n
    from ledger.trade_flow_daily f
   where f.kind = 'insider' and f.day >= v_cut;

  select coalesce(jsonb_agg(jsonb_build_object(
           'day', f.day, 'inflow', f.inflow, 'outflow', f.outflow)
         order by f.day), '[]'::jsonb),
         count(*) filter (where f.inflow > 0 or f.outflow > 0)
    into v_con, v_con_n
    from ledger.trade_flow_daily f
   where f.kind = 'congress' and f.day >= v_cut;

  -- When the worker has not written trade_flow_daily (or wrote only zeros),
  -- rebuild bars from the rows still stored for the Markets tables.
  if coalesce(v_ins_n, 0) = 0 then
    select coalesce(jsonb_agg(jsonb_build_object(
             'day', d.day, 'inflow', d.inflow, 'outflow', d.outflow)
           order by d.day), '[]'::jsonb)
      into v_ins
      from (
        select i.filed as day,
               sum(case when i.amount > 0 then i.amount else 0 end) as inflow,
               sum(case when i.amount < 0 then abs(i.amount) else 0 end) as outflow
          from ledger.insider_trade i
         where i.filed >= v_cut
           and (
             abs(coalesce(i.amount, 0)) > 1000000
             or (
               coalesce(i.shares_out, 0) > 0
               and coalesce(i.shares, 0) / i.shares_out >= 0.01
             )
           )
         group by i.filed
      ) d;
  end if;

  if coalesce(v_con_n, 0) = 0 then
    select coalesce(jsonb_agg(jsonb_build_object(
             'day', d.day, 'inflow', d.inflow, 'outflow', d.outflow)
           order by d.day), '[]'::jsonb)
      into v_con
      from (
        select g.disclosed as day,
               sum(case
                     when lower(coalesce(g.side, '')) ~ '^(buy|purchase|receive)'
                       or lower(coalesce(g.side, '')) like '%purchase%'
                       or lower(coalesce(g.side, '')) like '%receive%'
                     then coalesce((
                       select (min(v) + max(v)) / 2.0
                         from (
                           select replace(m[1], ',', '')::double precision as v
                             from regexp_matches(coalesce(g.amount, ''), '[\d,]+', 'g') as m
                         ) nums
                     ), 0)
                     else 0
                   end) as inflow,
               sum(case
                     when lower(coalesce(g.side, '')) ~ '^(sell|sale)'
                       or lower(coalesce(g.side, '')) like '%sale%'
                       or lower(coalesce(g.side, '')) like '%sell%'
                       or lower(coalesce(g.side, '')) like '%exchange%'
                     then coalesce((
                       select (min(v) + max(v)) / 2.0
                         from (
                           select replace(m[1], ',', '')::double precision as v
                             from regexp_matches(coalesce(g.amount, ''), '[\d,]+', 'g') as m
                         ) nums
                     ), 0)
                     else 0
                   end) as outflow
          from ledger.congress_trade g
         where g.disclosed >= v_cut
         group by g.disclosed
      ) d;
  end if;

  return jsonb_build_object(
    'days', v_days,
    'from', v_cut,
    'to', current_date,
    'insider', coalesce(v_ins, '[]'::jsonb),
    'congress', coalesce(v_con, '[]'::jsonb));
end;
$$;

do $$
begin
  execute 'revoke all on function public.get_trades(integer, integer, integer, text) from public';
  execute 'grant execute on function public.get_trades(integer, integer, integer, text) to anon, authenticated';
  execute 'revoke all on function public.get_trade_flow(integer) from public';
  execute 'grant execute on function public.get_trade_flow(integer) to anon, authenticated';
end $$;
