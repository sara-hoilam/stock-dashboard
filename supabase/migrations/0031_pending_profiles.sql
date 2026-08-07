-- Ticker Alpha — backfill queue for FMP company profiles
--
-- Apply after 0030. Safe to re-run.
--
-- The flip-card About face needs ledger.price_daily.profile. That column is
-- filled during fetch_prices, but companies that already had fresh bars never
-- re-ran, so profile stayed null. This queue lists those symbols so the
-- worker can fill them with a cheap /profile call (no full price refetch).

create or replace function public.pending_profiles(p_limit integer default 20)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(s.symbol order by s.updated_at desc), '[]'::jsonb)
  from (
    select p.symbol, p.updated_at
    from ledger.price_daily p
    where p.profile is null
    order by p.updated_at desc nulls last
    limit greatest(1, least(coalesce(p_limit, 20), 80))
  ) s;
$$;

do $$
begin
  execute 'revoke all on function public.pending_profiles(integer) from public';
  execute 'grant execute on function public.pending_profiles(integer) to service_role';
end $$;
