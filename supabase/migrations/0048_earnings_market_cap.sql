-- Ticker Alpha — market cap on the earnings calendar
--
-- Apply after 0047. Safe to re-run.
--
-- Three things were wrong with the Earnings page, and all three come back to
-- the same gap: `ledger.earnings_event` knew a symbol and a date and nothing
-- else, so market cap had to be borrowed from `ledger.quote` — which covers a
-- few hundred symbols out of the ~1,100 that can report on one day. Everything
-- else sorted as cap 0 and fell back to alphabetical order, so a busy day
-- showed forty companies whose ticker began with "A".
--
-- FMP's company-screener returns the whole above-$1B universe (~5,800 rows) in
-- one call, so the worker now stamps each event with its cap and name. That
-- makes three things possible:
--
--   * the week strip can pick the four largest companies of each day,
--   * the day list can be ordered by size and returned in full, and
--   * companies below $1B — shells, OTC tickers, delisted stubs — can be left
--     off the calendar entirely unless the visitor watchlists them.

alter table ledger.earnings_event add column if not exists market_cap double precision;
alter table ledger.earnings_event add column if not exists name       text;

create index if not exists earnings_event_date_cap_idx
  on ledger.earnings_event (date, market_cap desc nulls last);

-- Same contract as 0029 plus market_cap / name; rows that omit them still load,
-- which is what keeps an older worker working against this migration.
create or replace function public.replace_earnings(p_rows jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  delete from ledger.earnings_event where date is not null;
  insert into ledger.earnings_event
    (date, symbol, eps_actual, eps_estimated, revenue_actual, revenue_estimated,
     time, fiscal_date, market_cap, name, updated_at)
  select nullif(r->>'date','')::date, upper(r->>'symbol'),
         nullif(r->>'eps_actual','')::double precision,
         nullif(r->>'eps_estimated','')::double precision,
         nullif(r->>'revenue_actual','')::double precision,
         nullif(r->>'revenue_estimated','')::double precision,
         nullif(r->>'time',''),
         nullif(r->>'fiscal_date','')::date,
         nullif(r->>'market_cap','')::double precision,
         nullif(r->>'name',''),
         now()
  from jsonb_array_elements(p_rows) r
  where nullif(r->>'date','') is not null
    and nullif(r->>'symbol','') is not null
  on conflict (date, symbol) do update set
    eps_actual = excluded.eps_actual,
    eps_estimated = excluded.eps_estimated,
    revenue_actual = excluded.revenue_actual,
    revenue_estimated = excluded.revenue_estimated,
    time = excluded.time,
    fiscal_date = excluded.fiscal_date,
    market_cap = excluded.market_cap,
    name = excluded.name,
    updated_at = now();
  get diagnostics n = row_count;
  return n;
end;
$$;

-- The 0029 signatures have to go rather than be overloaded: PostgREST resolves
-- by argument name, and a call passing only p_date would match both versions
-- and fail as ambiguous.
drop function if exists public.get_earnings_week(date);
drop function if exists public.get_earnings_day(date, integer);

-- Seven-day strip centred on p_date (Sunday..Saturday of that week).
--
-- p_symbols is the visitor's watchlist: those companies are always counted,
-- however small. Everything else has to clear p_min_cap.
create or replace function public.get_earnings_week(p_date date default current_date,
                                                    p_symbols text[] default null,
                                                    p_min_cap double precision default 1e9)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with anchor as (
    select coalesce(p_date, current_date) as d
  ),
  bounds as (
    -- PostgreSQL: date - extract(dow) lands on Sunday for that week.
    select (d - extract(dow from d)::integer) as week_start from anchor
  ),
  days as (
    select (week_start + g.i) as day
    from bounds, generate_series(0, 6) as g(i)
  ),
  watched as (
    select distinct upper(trim(s)) as symbol
    from unnest(coalesce(p_symbols, array[]::text[])) s
    where nullif(trim(s), '') is not null
  ),
  kept as (
    select e.date, e.symbol, coalesce(e.market_cap, q.market_cap) as cap
    from ledger.earnings_event e
    left join ledger.quote q on q.symbol = e.symbol
    where e.date between (select week_start from bounds)
                     and (select week_start + 6 from bounds)
      and (coalesce(e.market_cap, q.market_cap, 0) >= coalesce(p_min_cap, 0)
           or e.symbol in (select symbol from watched))
  ),
  counts as (
    select k.date, count(*)::integer as n,
           (array_agg(k.symbol order by coalesce(k.cap, 0) desc, k.symbol))[1:4] as sample
    from kept k
    group by k.date
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', d.day,
           'count', coalesce(c.n, 0),
           'sample', coalesce(to_jsonb(c.sample), '[]'::jsonb))
         order by d.day), '[]'::jsonb)
  from days d
  left join counts c on c.date = d.day;
$$;

-- Everything reporting on one day, largest first. The page scrolls the whole
-- list, so p_limit is a safety valve rather than a page size.
create or replace function public.get_earnings_day(p_date date default current_date,
                                                   p_limit integer default 500,
                                                   p_symbols text[] default null,
                                                   p_min_cap double precision default 1e9)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with watched as (
    select distinct upper(trim(s)) as symbol
    from unnest(coalesce(p_symbols, array[]::text[])) s
    where nullif(trim(s), '') is not null
  ),
  page as (
    select e.date, e.symbol, e.eps_actual, e.eps_estimated,
           e.revenue_actual, e.revenue_estimated, e.time, e.fiscal_date,
           coalesce(t.name, c.name, q.name, e.name) as name,
           coalesce(e.market_cap, q.market_cap) as market_cap,
           q.price, q.change_pct
    from ledger.earnings_event e
    left join ledger.ticker  t on t.ticker = e.symbol
    left join ledger.company c on c.ticker = e.symbol
    left join ledger.quote   q on q.symbol = e.symbol
    where e.date = coalesce(p_date, current_date)
      and (coalesce(e.market_cap, q.market_cap, 0) >= coalesce(p_min_cap, 0)
           or e.symbol in (select symbol from watched))
    order by coalesce(e.market_cap, q.market_cap, 0) desc, e.symbol
    limit greatest(1, least(coalesce(p_limit, 500), 1000))
  ),
  -- One indexed pass for the whole page. 0029 ran a correlated subquery per
  -- event, including a title ILIKE, which was affordable only while the list
  -- was capped at forty rows.
  headline as (
    select distinct on (n.symbol) n.symbol, n.title
    from ledger.news n
    where n.symbol in (select symbol from page)
    order by n.symbol, n.published desc nulls last
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', p.date, 'symbol', p.symbol, 'name', p.name,
           'epsActual', p.eps_actual, 'epsEstimated', p.eps_estimated,
           'revenueActual', p.revenue_actual, 'revenueEstimated', p.revenue_estimated,
           'time', p.time, 'fiscalDate', p.fiscal_date,
           'marketCap', p.market_cap, 'price', p.price, 'changePct', p.change_pct,
           'headline', h.title)
         order by coalesce(p.market_cap, 0) desc, p.symbol), '[]'::jsonb)
  from page p
  left join headline h on h.symbol = p.symbol;
$$;

do $$
begin
  execute 'revoke all on function public.replace_earnings(jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.replace_earnings(jsonb) to service_role';
  execute 'revoke all on function public.get_earnings_week(date, text[], double precision) from public';
  execute 'grant execute on function public.get_earnings_week(date, text[], double precision) to anon, authenticated';
  execute 'revoke all on function public.get_earnings_day(date, integer, text[], double precision) from public';
  execute 'grant execute on function public.get_earnings_day(date, integer, text[], double precision) to anon, authenticated';
end $$;
