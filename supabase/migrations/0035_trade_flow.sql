-- Ticker Alpha — daily insider / congress inflow & outflow for Markets Today
--
-- Apply after 0028. Safe to re-run.
--
-- The Congress & Insiders tables stay on a short recent window. The bar charts
-- under them need sixty days of summed buy (inflow) and sell (outflow)
-- dollars, so the worker writes a compact daily series here.

create table if not exists ledger.trade_flow_daily (
  kind        text not null check (kind in ('insider', 'congress')),
  day         date not null,
  inflow      double precision not null default 0,
  outflow     double precision not null default 0,
  updated_at  timestamptz not null default now(),
  primary key (kind, day)
);

alter table ledger.trade_flow_daily enable row level security;

create or replace function public.replace_trade_flow(p_rows jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  -- Full replace of the retained window: the worker always sends the last
  -- ~60 days, so anything older would just stale the chart.
  delete from ledger.trade_flow_daily;

  insert into ledger.trade_flow_daily (kind, day, inflow, outflow, updated_at)
  select lower(r->>'kind'),
         (r->>'day')::date,
         coalesce((r->>'inflow')::double precision, 0),
         coalesce((r->>'outflow')::double precision, 0),
         now()
  from jsonb_array_elements(coalesce(p_rows, '[]'::jsonb)) r
  where r->>'kind' in ('insider', 'congress')
    and nullif(r->>'day', '') is not null
  on conflict (kind, day) do update
    set inflow = excluded.inflow,
        outflow = excluded.outflow,
        updated_at = now();

  get diagnostics n = row_count;
  return n;
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
begin
  return jsonb_build_object(
    'days', v_days,
    'from', v_cut,
    'to', current_date,
    'insider', coalesce((
      select jsonb_agg(jsonb_build_object(
               'day', f.day, 'inflow', f.inflow, 'outflow', f.outflow)
             order by f.day)
      from ledger.trade_flow_daily f
      where f.kind = 'insider' and f.day >= v_cut), '[]'::jsonb),
    'congress', coalesce((
      select jsonb_agg(jsonb_build_object(
               'day', f.day, 'inflow', f.inflow, 'outflow', f.outflow)
             order by f.day)
      from ledger.trade_flow_daily f
      where f.kind = 'congress' and f.day >= v_cut), '[]'::jsonb));
end;
$$;

do $$
begin
  execute 'revoke all on function public.replace_trade_flow(jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.replace_trade_flow(jsonb) to service_role';
  execute 'revoke all on function public.get_trade_flow(integer) from public';
  execute 'grant execute on function public.get_trade_flow(integer) to anon, authenticated';
end $$;
