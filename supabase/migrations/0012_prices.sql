-- Ticker Alpha — daily prices and a full quote for the company report
--
-- Apply after 0011. Safe to re-run.
--
-- The report page can be opened for any of ~12,000 companies, so prices
-- cannot be pre-fetched the way the 60-odd names on Markets Today are. This
-- follows the pattern the filings already use: the page asks, the worker
-- fetches, the page picks the answer up a moment later.

create table if not exists ledger.price_daily (
  symbol     text primary key,
  bars       jsonb not null,          -- [{d,o,h,l,c,v}, ...] oldest first
  as_of      date,
  updated_at timestamptz not null default now()
);

create table if not exists ledger.quote_detail (
  symbol         text primary key,
  name           text,
  price          double precision,
  change         double precision,
  change_pct     double precision,
  open           double precision,
  previous_close double precision,
  day_low        double precision,
  day_high       double precision,
  year_low       double precision,
  year_high      double precision,
  volume         double precision,
  market_cap     double precision,
  shares         double precision,
  avg_50         double precision,
  avg_200        double precision,
  pe             double precision,
  pb             double precision,
  dividend_yield double precision,
  exchange       text,
  updated_at     timestamptz not null default now()
);

-- What the page has asked for and the worker has not yet fetched.
create table if not exists ledger.price_request (
  symbol       text primary key,
  requested_at timestamptz not null default now(),
  done_at      timestamptz
);

alter table ledger.price_daily   enable row level security;
alter table ledger.quote_detail  enable row level security;
alter table ledger.price_request enable row level security;

-- ---------------------------------------------------------------------------
-- Reads
-- ---------------------------------------------------------------------------

-- Chart and panel together: the page draws both or neither.
create or replace function public.get_prices(p_symbol text)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
    'bars', coalesce((select b.bars from ledger.price_daily b
                      where b.symbol = upper(p_symbol)), '[]'::jsonb),
    'asOf', (select b.as_of from ledger.price_daily b where b.symbol = upper(p_symbol)),
    'quote', (
      select to_jsonb(x) - 'symbol' - 'updated_at'
      from (select q.* from ledger.quote_detail q
            where q.symbol = upper(p_symbol)) x),
    'stale', (
      select coalesce(max(d.updated_at) < now() - interval '12 hours', true)
      from ledger.price_daily d where d.symbol = upper(p_symbol)));
$$;

-- ---------------------------------------------------------------------------
-- Request — the page may ask, but only for a plausible symbol
-- ---------------------------------------------------------------------------
create or replace function public.request_prices(p_symbol text)
returns jsonb
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare sym text := upper(trim(coalesce(p_symbol, '')));
begin
  if sym !~ '^[A-Z][A-Z.\-]{0,9}$' then
    return jsonb_build_object('queued', false, 'reason', 'not a ticker');
  end if;

  insert into ledger.price_request (symbol, requested_at, done_at)
  values (sym, now(), null)
  on conflict (symbol) do update
    -- Re-asking within the hour is the page polling, not a new request.
    set requested_at = case
          when ledger.price_request.requested_at < now() - interval '1 hour'
            or ledger.price_request.done_at is not null
          then now() else ledger.price_request.requested_at end,
        done_at = case
          when ledger.price_request.done_at < now() - interval '12 hours'
          then null else ledger.price_request.done_at end;

  return jsonb_build_object('queued', true, 'symbol', sym);
end;
$$;

-- ---------------------------------------------------------------------------
-- Writes — worker only
-- ---------------------------------------------------------------------------
create or replace function public.upsert_prices(p_symbol text, p_bars jsonb,
                                                p_quote jsonb, p_as_of date)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare sym text := upper(p_symbol);
begin
  if p_bars is not null and jsonb_array_length(p_bars) > 0 then
    insert into ledger.price_daily (symbol, bars, as_of, updated_at)
    values (sym, p_bars, p_as_of, now())
    on conflict (symbol) do update
      set bars = excluded.bars, as_of = excluded.as_of, updated_at = now();
  end if;

  if p_quote is not null and p_quote <> 'null'::jsonb then
    insert into ledger.quote_detail (
      symbol, name, price, change, change_pct, open, previous_close,
      day_low, day_high, year_low, year_high, volume, market_cap, shares,
      avg_50, avg_200, pe, pb, dividend_yield, exchange, updated_at)
    select sym, q.name, q.price, q.change, q.change_pct, q.open, q.previous_close,
           q.day_low, q.day_high, q.year_low, q.year_high, q.volume,
           q.market_cap, q.shares, q.avg_50, q.avg_200, q.pe, q.pb,
           q.dividend_yield, q.exchange, now()
    from jsonb_to_record(p_quote) as q(
      name text, price double precision, change double precision,
      change_pct double precision, open double precision,
      previous_close double precision, day_low double precision,
      day_high double precision, year_low double precision,
      year_high double precision, volume double precision,
      market_cap double precision, shares double precision,
      avg_50 double precision, avg_200 double precision,
      pe double precision, pb double precision,
      dividend_yield double precision, exchange text)
    on conflict (symbol) do update set
      name = excluded.name, price = excluded.price, change = excluded.change,
      change_pct = excluded.change_pct, open = excluded.open,
      previous_close = excluded.previous_close, day_low = excluded.day_low,
      day_high = excluded.day_high, year_low = excluded.year_low,
      year_high = excluded.year_high, volume = excluded.volume,
      market_cap = excluded.market_cap, shares = excluded.shares,
      avg_50 = excluded.avg_50, avg_200 = excluded.avg_200,
      pe = excluded.pe, pb = excluded.pb,
      dividend_yield = excluded.dividend_yield, exchange = excluded.exchange,
      updated_at = now();
  end if;

  update ledger.price_request set done_at = now() where symbol = sym;
  return 1;
end;
$$;

create or replace function public.pending_prices(p_limit integer default 5)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(r.symbol order by r.requested_at), '[]'::jsonb)
  from (select symbol, requested_at from ledger.price_request
        where done_at is null
        order by requested_at
        limit greatest(1, least(coalesce(p_limit, 5), 25))) r;
$$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.get_prices(text)',
    'public.request_prices(text)'
  ] loop
    execute format('revoke all on function %s from public', f);
    execute format('grant execute on function %s to anon, authenticated', f);
  end loop;
  foreach f in array array[
    'public.upsert_prices(text, jsonb, jsonb, date)',
    'public.pending_prices(integer)'
  ] loop
    execute format('revoke all on function %s from public, anon, authenticated', f);
    execute format('grant execute on function %s to service_role', f);
  end loop;
end $$;
