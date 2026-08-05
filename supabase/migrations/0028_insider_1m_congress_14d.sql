-- Ticker Alpha — insider $1M / 1%-of-shares filter; congress 14-day window
--
-- Apply after 0027. Safe to re-run.
--
-- Insider rows stay when abs(amount) > $1M, or when shares transacted are at
-- least 1% of estimated shares outstanding (stored as shares_out). Congress
-- still requires a disclosed range above $0.5M; the UI asks for 14 days.

alter table ledger.insider_trade
  add column if not exists shares_out double precision;

create or replace function public.replace_trades(p_insiders jsonb, p_congress jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  delete from ledger.insider_trade where id is not null;
  insert into ledger.insider_trade
    (filed, symbol, side, shares, amount, person, title, shares_out)
  select nullif(r->>'filed','')::date, upper(r->>'symbol'), r->>'side',
         (r->>'shares')::double precision, (r->>'amount')::double precision,
         r->>'person', nullif(r->>'title',''),
         nullif(r->>'shares_out','')::double precision
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
  v_con_min double precision := 500000;   -- $0.5M (congress range high)
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
    select count(*)::integer into v_con_total
    from ledger.congress_trade g
    where g.disclosed >= v_cut
      and coalesce((
            select max(replace(m[1], ',', '')::double precision)
            from regexp_matches(coalesce(g.amount, ''), '[\d,]+', 'g') as m
          ), 0) > v_con_min;

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
        and coalesce((
              select max(replace(m[1], ',', '')::double precision)
              from regexp_matches(coalesce(g.amount, ''), '[\d,]+', 'g') as m
            ), 0) > v_con_min
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
    'minCongressAmount', v_con_min,
    'minSharesPct', v_pct);
end;
$$;

do $$
begin
  execute 'revoke all on function public.replace_trades(jsonb, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.replace_trades(jsonb, jsonb) to service_role';
  execute 'revoke all on function public.get_trades(integer, integer, integer, text) from public';
  execute 'grant execute on function public.get_trades(integer, integer, integer, text) to anon, authenticated';
end $$;
