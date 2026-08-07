-- Ticker Alpha — rebuild trade flow when the daily series is sparse
--
-- Apply after 0044. Safe to re-run.
--
-- A shallow FMP pull (limit=100, page cap 100) only covered ~10 Form 4 days.
-- That left ledger.trade_flow_daily with a handful of recent nonzero rows, so
-- get_trade_flow skipped its table fallback (which only ran when count = 0).
-- Rebuild whenever active days are thinner than a quarter of the window.

create or replace function public.get_trade_flow(p_days integer default 60)
returns jsonb
language plpgsql stable security definer
set search_path = ledger, pg_temp
as $$
declare
  v_days integer := greatest(1, least(coalesce(p_days, 60), 120));
  v_cut  date    := current_date - (v_days - 1);
  v_min_active integer := greatest(8, v_days / 4);
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

  -- Empty or thin series: rebuild from the rows kept for the Markets tables.
  if coalesce(v_ins_n, 0) < v_min_active then
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

  if coalesce(v_con_n, 0) < v_min_active then
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
  execute 'revoke all on function public.get_trade_flow(integer) from public';
  execute 'grant execute on function public.get_trade_flow(integer) to anon, authenticated';
end $$;
