-- Alpha Ticker — market data for the landing page
--
-- Apply after 0004. Safe to re-run.
--
-- This is the second source. EDGAR knows what a company earned; it knows
-- nothing about what the stock did today. Prices, market capitalisation, the
-- day's movers and sector performance come from Financial Modeling Prep.
--
-- The FMP key is a paid secret, so the browser never calls FMP. The worker
-- fetches and writes here; the page reads through the same anon-key surface
-- as everything else.

-- ---------------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------------

-- The watchlist shown in Market Summary, one row per symbol.
create table if not exists ledger.quote (
  symbol      text primary key,
  name        text,
  price       double precision,
  change      double precision,
  change_pct  double precision,
  volume      double precision,
  market_cap  double precision,
  exchange    text,
  updated_at  timestamptz not null default now()
);

-- The day's biggest movers. `kind` is gainer | loser | active.
create table if not exists ledger.mover (
  kind        text    not null,
  rank        integer not null,
  symbol      text    not null,
  name        text,
  price       double precision,
  change      double precision,
  change_pct  double precision,
  exchange    text,
  as_of       date,
  updated_at  timestamptz not null default now(),
  primary key (kind, rank)
);

create table if not exists ledger.sector_perf (
  sector      text primary key,
  change_pct  double precision,
  as_of       date,
  updated_at  timestamptz not null default now()
);

-- Five-minute bars for the chart, stored whole because they are only ever
-- read as one series.
create table if not exists ledger.intraday (
  symbol      text primary key,
  points      jsonb not null,
  as_of       date,
  updated_at  timestamptz not null default now()
);

alter table ledger.quote       enable row level security;
alter table ledger.mover       enable row level security;
alter table ledger.sector_perf enable row level security;
alter table ledger.intraday    enable row level security;

-- ---------------------------------------------------------------------------
-- Reads — the landing page's whole payload in one call
-- ---------------------------------------------------------------------------
create or replace function public.get_market_overview()
returns jsonb
language sql
stable
security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'asOf', (select max(as_of) from ledger.sector_perf),
    'updatedAt', (select max(updated_at) from ledger.quote),

    -- Breadth: the share of the watchlist that rose. Stated as a number so
    -- the page can show the basis rather than just the verdict.
    'breadth', (
      select case when count(*) = 0 then null
             else jsonb_build_object(
               'up', count(*) filter (where change_pct > 0),
               'total', count(*),
               'avgChange', round(avg(change_pct)::numeric, 2))
             end
      from ledger.quote),

    'sectors', coalesce((
      select jsonb_agg(jsonb_build_object('sector', sector, 'changePct', change_pct)
             order by change_pct desc)
      from ledger.sector_perf), '[]'::jsonb),

    'topStock', (
      select jsonb_build_object('symbol', symbol, 'name', name,
                                'changePct', change_pct, 'price', price)
      from ledger.mover where kind = 'gainer' order by rank limit 1),

    'worstStock', (
      select jsonb_build_object('symbol', symbol, 'name', name,
                                'changePct', change_pct, 'price', price)
      from ledger.mover where kind = 'loser' order by rank limit 1),

    'leader', (
      select jsonb_build_object('symbol', symbol, 'changePct', change_pct)
      from ledger.quote
      where symbol in ('SPY','QQQ','IWM','DIA')
      order by change_pct desc nulls last limit 1)
  );
$$;

-- The Market Summary list, in one of three orders.
create or replace function public.get_market_summary(p_view text default 'market_cap',
                                                     p_limit integer default 12)
returns jsonb
language sql
stable
security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', s.symbol, 'name', s.name, 'price', s.price,
           'change', s.change, 'changePct', s.change_pct,
           'marketCap', s.market_cap) order by s.ord), '[]'::jsonb)
  from (
    -- Gainers and losers come from the market-wide movers list; market cap
    -- ranks the watchlist we actually track.
    select q.symbol, q.name, q.price, q.change, q.change_pct, q.market_cap,
           row_number() over (order by q.market_cap desc nulls last) as ord
    from ledger.quote q
    where p_view = 'market_cap'
    union all
    select m.symbol, m.name, m.price, m.change, m.change_pct, null::double precision,
           m.rank
    from ledger.mover m
    where (p_view = 'gainers' and m.kind = 'gainer')
       or (p_view = 'losers'  and m.kind = 'loser')
       or (p_view = 'active'  and m.kind = 'active')
  ) s
  where s.ord <= greatest(1, least(coalesce(p_limit, 12), 50));
$$;

create or replace function public.get_intraday(p_symbol text)
returns jsonb
language sql
stable
security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
           'symbol', i.symbol, 'asOf', i.as_of, 'points', i.points,
           'quote', (select jsonb_build_object(
                              'price', q.price, 'change', q.change,
                              'changePct', q.change_pct, 'name', q.name)
                     from ledger.quote q where q.symbol = i.symbol))
  from ledger.intraday i
  where i.symbol = upper(p_symbol);
$$;

-- ---------------------------------------------------------------------------
-- Writes — worker only
-- ---------------------------------------------------------------------------
create or replace function public.upsert_quotes(p_rows jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  insert into ledger.quote (symbol, name, price, change, change_pct, volume,
                            market_cap, exchange, updated_at)
  select distinct on (upper(r->>'symbol'))
         upper(r->>'symbol'), r->>'name',
         (r->>'price')::double precision, (r->>'change')::double precision,
         (r->>'change_pct')::double precision, (r->>'volume')::double precision,
         (r->>'market_cap')::double precision, r->>'exchange', now()
  from jsonb_array_elements(p_rows) r
  where r->>'symbol' is not null
  order by upper(r->>'symbol')
  on conflict (symbol) do update
    set name = excluded.name, price = excluded.price, change = excluded.change,
        change_pct = excluded.change_pct, volume = excluded.volume,
        market_cap = coalesce(excluded.market_cap, ledger.quote.market_cap),
        exchange = excluded.exchange, updated_at = now();
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.replace_movers(p_kind text, p_rows jsonb, p_as_of date)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  delete from ledger.mover where kind = p_kind;
  insert into ledger.mover (kind, rank, symbol, name, price, change, change_pct,
                            exchange, as_of, updated_at)
  select p_kind, (r->>'rank')::integer, upper(r->>'symbol'), r->>'name',
         (r->>'price')::double precision, (r->>'change')::double precision,
         (r->>'change_pct')::double precision, r->>'exchange', p_as_of, now()
  from jsonb_array_elements(p_rows) r
  where r->>'symbol' is not null;
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.replace_sectors(p_rows jsonb, p_as_of date)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  delete from ledger.sector_perf;
  insert into ledger.sector_perf (sector, change_pct, as_of, updated_at)
  select r->>'sector', (r->>'change_pct')::double precision, p_as_of, now()
  from jsonb_array_elements(p_rows) r
  where r->>'sector' is not null;
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.upsert_intraday(p_symbol text, p_points jsonb,
                                                  p_as_of date)
returns void
language sql volatile security definer
set search_path = ledger, pg_temp
as $$
  insert into ledger.intraday (symbol, points, as_of, updated_at)
  values (upper(p_symbol), p_points, p_as_of, now())
  on conflict (symbol) do update
    set points = excluded.points, as_of = excluded.as_of, updated_at = now();
$$;

-- ---------------------------------------------------------------------------
-- Grants
-- ---------------------------------------------------------------------------
do $$
declare f text;
begin
  foreach f in array array[
    'public.get_market_overview()',
    'public.get_market_summary(text, integer)',
    'public.get_intraday(text)'
  ] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;

  foreach f in array array[
    'public.upsert_quotes(jsonb)',
    'public.replace_movers(text, jsonb, date)',
    'public.replace_sectors(jsonb, date)',
    'public.upsert_intraday(text, jsonb, date)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
