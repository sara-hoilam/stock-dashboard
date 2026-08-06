-- Ticker Alpha — clear entire portfolio (authenticated owner only)
--
-- Apply after 0046. Safe to re-run.
-- Deletes every transaction in the signed-in user's primary portfolio.
-- The portfolio row itself is kept so the next add does not need re-create.

create or replace function public.clear_portfolio()
returns jsonb
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_pf  uuid;
  v_n   integer := 0;
begin
  if v_uid is null then
    return jsonb_build_object('error', 'not signed in');
  end if;

  select id into v_pf
    from public.portfolio
   where user_id = v_uid
   order by created_at
   limit 1;

  if v_pf is null then
    return jsonb_build_object('cleared', true, 'deleted', 0);
  end if;

  delete from public.portfolio_transaction
   where portfolio_id = v_pf;
  get diagnostics v_n = row_count;

  return jsonb_build_object(
    'cleared', true,
    'deleted', v_n,
    'portfolioId', v_pf);
end;
$$;

do $$
begin
  execute 'revoke all on function public.clear_portfolio() from public, anon';
  execute 'grant execute on function public.clear_portfolio() to authenticated';
end $$;
