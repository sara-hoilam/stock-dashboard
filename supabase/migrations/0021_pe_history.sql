-- Ticker Alpha — FMP historical P/E for the company report
--
-- Apply after 0020. Safe to re-run.
--
-- The Market tab used to rebuild trailing P/E from filed diluted EPS. That
-- misleads when a filer only tags some quarters (common for FPIs on 6-Ks):
-- four "quarters" can be four different years' Q2s. Store FMP's own quarterly
-- key-metrics P/E instead; the price panel's current P/E already comes from
-- FMP ratios-ttm.

alter table ledger.price_daily add column if not exists pe_history jsonb;

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

drop function if exists public.upsert_company_extras(text, jsonb, text, text);

create or replace function public.upsert_company_extras(
    p_symbol text, p_monthly jsonb, p_sector text, p_industry text,
    p_pe_history jsonb default null)
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
         updated_at = now()
   where symbol = upper(p_symbol);
  return 1;
end;
$$;

do $$
begin
  execute 'revoke all on function public.get_company_extras(text) from public';
  execute 'grant execute on function public.get_company_extras(text) to anon, authenticated';
  execute 'revoke all on function public.upsert_company_extras(text, jsonb, text, text, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_company_extras(text, jsonb, text, text, jsonb) to service_role';
end $$;
