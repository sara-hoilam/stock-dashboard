-- Ticker Alpha — backfill employee headcount for revenue / employee
--
-- Apply after 0032. Safe to re-run.
--
-- get_company_extras was coalescing a missing employee_history to [], so the
-- page could not tell "not fetched yet" from "fetched, none found", and never
-- asked for a refresh once profile existed. Return null when unset, and queue
-- symbols that still need a headcount write.

create or replace function public.get_company_extras(p_symbol text)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with me as (
    select * from ledger.price_daily where symbol = upper(p_symbol)
  )
  select jsonb_build_object(
    'monthly',  coalesce((select m.monthly from me m), '[]'::jsonb),
    'sector',   (select m.sector from me m),
    'industry', (select m.industry from me m),
    'peHistory', coalesce((select m.pe_history from me m), '[]'::jsonb),
    'profile',  (select m.profile from me m),
    -- null = not fetched yet (page should request a refresh); [] = fetched empty
    'employeeHistory', (select m.employee_history from me m),

    'benchmark', (
      select jsonb_build_object('symbol', b.symbol, 'closes', b.closes)
      from ledger.benchmark b
      where b.symbol = (select ledger.sector_etf(m.sector) from me m)),

    'industryPe', (
      select p.pe from ledger.industry_pe p
      where p.kind = 'industry' and p.name = (select m.industry from me m)),
    'sectorPe', (
      select p.pe from ledger.industry_pe p
      where p.kind = 'sector' and p.name = (select m.sector from me m)),
    'peAsOf', (select max(as_of) from ledger.industry_pe));
$$;

create or replace function public.pending_employee_history(p_limit integer default 20)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(s.symbol order by s.updated_at desc), '[]'::jsonb)
  from (
    select p.symbol, p.updated_at
    from ledger.price_daily p
    where p.employee_history is null
    order by p.updated_at desc nulls last
    limit greatest(1, least(coalesce(p_limit, 20), 80))
  ) s;
$$;

do $$
begin
  execute 'revoke all on function public.get_company_extras(text) from public';
  execute 'grant execute on function public.get_company_extras(text) to anon, authenticated';
  execute 'revoke all on function public.pending_employee_history(integer) from public';
  execute 'grant execute on function public.pending_employee_history(integer) to service_role';
end $$;
