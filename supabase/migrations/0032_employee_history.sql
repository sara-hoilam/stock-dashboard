-- Ticker Alpha — FMP historical employee counts for revenue / employee
--
-- Apply after 0031. Safe to re-run.
--
-- FMP's historical-employee-count is annual (from 10-Ks). The revenue-by-quarter
-- chart joins each quarter's filed revenue to the latest headcount on or before
-- that quarter's period end to plot revenue per employee on a second Y-axis.

alter table ledger.price_daily add column if not exists employee_history jsonb;

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
    'employeeHistory', coalesce((select m.employee_history from me m), '[]'::jsonb),

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

drop function if exists public.upsert_company_extras(text, jsonb, text, text, jsonb, jsonb);

create or replace function public.upsert_company_extras(
    p_symbol text, p_monthly jsonb, p_sector text, p_industry text,
    p_pe_history jsonb default null, p_profile jsonb default null,
    p_employee_history jsonb default null)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
begin
  update ledger.price_daily
     set monthly  = coalesce(p_monthly, monthly),
         sector   = coalesce(p_sector, sector),
         industry = coalesce(p_industry, industry),
         pe_history = coalesce(p_pe_history, pe_history),
         profile  = coalesce(p_profile, profile),
         employee_history = coalesce(p_employee_history, employee_history),
         updated_at = now()
   where symbol = upper(p_symbol);
  return 1;
end;
$$;

do $$
begin
  execute 'revoke all on function public.get_company_extras(text) from public';
  execute 'grant execute on function public.get_company_extras(text) to anon, authenticated';
  execute 'revoke all on function public.upsert_company_extras(text, jsonb, text, text, jsonb, jsonb, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_company_extras(text, jsonb, text, text, jsonb, jsonb, jsonb) to service_role';
end $$;
