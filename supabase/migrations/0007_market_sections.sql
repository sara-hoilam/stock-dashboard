-- Alpha Ticker — heatmap, sector movement, insiders and congress
--
-- Apply after 0006. Safe to re-run.

create table if not exists ledger.heatmap (
  symbol      text primary key,
  name        text,
  sector      text,
  industry    text,
  market_cap  double precision,
  price       double precision,
  change_pct  double precision,
  as_of       date,
  updated_at  timestamptz not null default now()
);

create table if not exists ledger.sector_history (
  sector      text primary key,
  series      jsonb not null,           -- [{d: 'YYYY-MM-DD', v: pct}, ...]
  updated_at  timestamptz not null default now()
);

create table if not exists ledger.insider_trade (
  id          bigserial primary key,
  filed       date,
  symbol      text,
  side        text,
  shares      double precision,
  amount      double precision,
  person      text,
  updated_at  timestamptz not null default now()
);

create table if not exists ledger.congress_trade (
  id          bigserial primary key,
  disclosed   date,
  traded      date,
  symbol      text,
  person      text,
  chamber     text,
  side        text,
  amount      text,
  updated_at  timestamptz not null default now()
);

alter table ledger.heatmap         enable row level security;
alter table ledger.sector_history  enable row level security;
alter table ledger.insider_trade   enable row level security;
alter table ledger.congress_trade  enable row level security;

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

-- Grouped by sector so the treemap can lay out sector blocks without
-- regrouping in the browser.
create or replace function public.get_heatmap()
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  -- `s` is a jsonb column of the subquery, not a table, so both it and the
  -- sort key have to be qualified by the subquery's own alias.
  select coalesce(jsonb_agg(t.s order by t.cap desc), '[]'::jsonb)
  from (
    select jsonb_build_object(
             'sector', sector,
             'marketCap', sum(market_cap),
             'items', jsonb_agg(jsonb_build_object(
                        'symbol', symbol, 'name', name,
                        'marketCap', market_cap, 'changePct', change_pct)
                      order by market_cap desc)) as s,
           sum(market_cap) as cap
    from ledger.heatmap
    where market_cap is not null
    group by sector
  ) t;
$$;

create or replace function public.get_sector_movement()
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'history', coalesce((
      select jsonb_agg(jsonb_build_object('sector', sector, 'series', series)
             order by sector)
      from ledger.sector_history), '[]'::jsonb),
    'performance', coalesce((
      select jsonb_agg(jsonb_build_object('sector', sector, 'changePct', change_pct)
             order by change_pct desc)
      from ledger.sector_perf), '[]'::jsonb),
    'asOf', (select max(as_of) from ledger.sector_perf));
$$;

create or replace function public.get_trades(p_limit integer default 12)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'insiders', coalesce((
      select jsonb_agg(jsonb_build_object(
               'filed', filed, 'symbol', symbol, 'side', side,
               'shares', shares, 'amount', amount, 'person', person)
             order by filed desc, abs(amount) desc nulls last)
      from (select * from ledger.insider_trade
            order by filed desc, abs(amount) desc nulls last
            limit greatest(1, least(p_limit, 50))) i), '[]'::jsonb),
    'congress', coalesce((
      select jsonb_agg(jsonb_build_object(
               'disclosed', disclosed, 'traded', traded, 'symbol', symbol,
               'person', person, 'chamber', chamber, 'side', side, 'amount', amount)
             order by disclosed desc)
      from (select * from ledger.congress_trade
            order by disclosed desc
            limit greatest(1, least(p_limit, 50))) c), '[]'::jsonb));
$$;

-- ---------------------------------------------------------------------------
-- Writes — worker only
-- ---------------------------------------------------------------------------
create or replace function public.replace_heatmap(p_rows jsonb, p_as_of date)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  delete from ledger.heatmap where symbol is not null;
  insert into ledger.heatmap (symbol, name, sector, industry, market_cap,
                              price, change_pct, as_of, updated_at)
  select distinct on (upper(r->>'symbol'))
         upper(r->>'symbol'), r->>'name', r->>'sector', r->>'industry',
         (r->>'market_cap')::double precision, (r->>'price')::double precision,
         (r->>'change_pct')::double precision, p_as_of, now()
  from jsonb_array_elements(p_rows) r
  where r->>'symbol' is not null
  order by upper(r->>'symbol');
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.replace_sector_history(p_rows jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  delete from ledger.sector_history where sector is not null;
  insert into ledger.sector_history (sector, series, updated_at)
  select r->>'sector', r->'series', now()
  from jsonb_array_elements(p_rows) r
  where r->>'sector' is not null;
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.replace_trades(p_insiders jsonb, p_congress jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  delete from ledger.insider_trade where id is not null;
  insert into ledger.insider_trade (filed, symbol, side, shares, amount, person)
  select nullif(r->>'filed','')::date, upper(r->>'symbol'), r->>'side',
         (r->>'shares')::double precision, (r->>'amount')::double precision,
         r->>'person'
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

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.get_heatmap()',
    'public.get_sector_movement()',
    'public.get_trades(integer)'
  ] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;

  foreach f in array array[
    'public.replace_heatmap(jsonb, date)',
    'public.replace_sector_history(jsonb)',
    'public.replace_trades(jsonb, jsonb)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
