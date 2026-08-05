-- Ticker Alpha — insider role title for the Markets Today People column
--
-- Apply after 0025. Safe to re-run.
--
-- FMP's typeOfOwner ("officer: Chief Financial Officer", "director", …) is
-- normalised by the worker into a short title (CFO, Director, …) and shown
-- above the reporting person's name, stacked like ticker / company.

alter table ledger.insider_trade
  add column if not exists title text;

create or replace function public.replace_trades(p_insiders jsonb, p_congress jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  delete from ledger.insider_trade where id is not null;
  insert into ledger.insider_trade (filed, symbol, side, shares, amount, person, title)
  select nullif(r->>'filed','')::date, upper(r->>'symbol'), r->>'side',
         (r->>'shares')::double precision, (r->>'amount')::double precision,
         r->>'person', nullif(r->>'title','')
  from jsonb_array_elements(p_insiders) r
  where r->>'symbol' is not null;
  get diagnostics n = row_count;

  delete from ledger.congress_trade where id is not null;
  insert into ledger.congress_trade (disclosed, traded, symbol, person,
                                     chamber, side, amount)
  select nullif(r->>'disclosed','')::date, nullif(r->>'traded','')::date,
         upper(r->>'symbol'), r->>'person', r->>'chamber', r->>'side', r->>'amount'
  from jsonb_array_elements(p_congress) r
  where r->>'symbol' is not null;
  return n;
end;
$$;

create or replace function public.get_trades(p_limit integer default 12)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'insiders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'filed', i.filed, 'symbol', i.symbol,
               'name', coalesce(t.name, c.name),
               'side', i.side, 'shares', i.shares,
               'amount', i.amount, 'person', i.person,
               'title', i.title)
             order by i.filed desc nulls last, i.amount desc nulls last)
      from (
        select * from ledger.insider_trade
        order by filed desc nulls last, amount desc nulls last
        limit greatest(1, least(coalesce(p_limit, 12), 50))
      ) i
      left join ledger.ticker  t on t.ticker  = i.symbol
      left join ledger.company c on c.ticker  = i.symbol), '[]'::jsonb),

    'congress', coalesce((
      select jsonb_agg(jsonb_build_object(
               'disclosed', g.disclosed, 'traded', g.traded, 'symbol', g.symbol,
               'name', coalesce(t.name, c.name),
               'person', g.person, 'chamber', g.chamber,
               'side', g.side, 'amount', g.amount)
             order by g.disclosed desc nulls last)
      from (
        select * from ledger.congress_trade
        order by disclosed desc nulls last
        limit greatest(1, least(coalesce(p_limit, 12), 50))
      ) g
      left join ledger.ticker  t on t.ticker  = g.symbol
      left join ledger.company c on c.ticker  = g.symbol), '[]'::jsonb));
$$;

do $$
begin
  execute 'revoke all on function public.replace_trades(jsonb, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.replace_trades(jsonb, jsonb) to service_role';
  execute 'revoke all on function public.get_trades(integer) from public';
  execute 'grant execute on function public.get_trades(integer) to anon, authenticated';
end $$;
