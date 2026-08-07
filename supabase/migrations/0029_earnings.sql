-- Ticker Alpha — earnings calendar for the Earnings page
--
-- Apply after 0028. Safe to re-run.
--
-- The worker replaces this snapshot from FMP's earnings-calendar. The page
-- reads a week strip, the companies reporting on one day (with a recent news
-- headline when we have one), and a market-summary sidebar that carries each
-- symbol's next earnings date.

create table if not exists ledger.earnings_event (
  date               date not null,
  symbol             text not null,
  eps_actual         double precision,
  eps_estimated      double precision,
  revenue_actual     double precision,
  revenue_estimated  double precision,
  time               text,
  fiscal_date        date,
  updated_at         timestamptz not null default now(),
  primary key (date, symbol)
);
create index if not exists earnings_event_symbol_date_idx
  on ledger.earnings_event (symbol, date);
create index if not exists earnings_event_date_idx
  on ledger.earnings_event (date);

alter table ledger.earnings_event enable row level security;

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
     time, fiscal_date, updated_at)
  select nullif(r->>'date','')::date, upper(r->>'symbol'),
         nullif(r->>'eps_actual','')::double precision,
         nullif(r->>'eps_estimated','')::double precision,
         nullif(r->>'revenue_actual','')::double precision,
         nullif(r->>'revenue_estimated','')::double precision,
         nullif(r->>'time',''),
         nullif(r->>'fiscal_date','')::date,
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
    updated_at = now();
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Seven-day strip centred on p_date (Sunday..Saturday of that week).
create or replace function public.get_earnings_week(p_date date default current_date)
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
  counts as (
    select e.date, count(*)::integer as n,
           (array_agg(e.symbol order by coalesce(q.market_cap, 0) desc nulls last))[1:4] as sample
    from ledger.earnings_event e
    left join ledger.quote q on q.symbol = e.symbol
    where e.date between (select week_start from bounds)
                     and (select week_start + 6 from bounds)
    group by e.date
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', d.day,
           'count', coalesce(c.n, 0),
           'sample', coalesce(to_jsonb(c.sample), '[]'::jsonb))
         order by d.day), '[]'::jsonb)
  from days d
  left join counts c on c.date = d.day;
$$;

create or replace function public.get_earnings_day(p_date date default current_date,
                                                   p_limit integer default 40)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with ranked as (
    select e.date, e.symbol, e.eps_actual, e.eps_estimated,
           e.revenue_actual, e.revenue_estimated, e.time, e.fiscal_date,
           coalesce(t.name, c.name, q.name) as name,
           q.market_cap,
           q.price, q.change_pct,
           (select n.title from ledger.news n
             where n.symbol = e.symbol
                or n.title ilike '%' || e.symbol || '%'
             order by n.published desc nulls last
             limit 1) as headline
    from ledger.earnings_event e
    left join ledger.ticker  t on t.ticker = e.symbol
    left join ledger.company c on c.ticker = e.symbol
    left join ledger.quote   q on q.symbol = e.symbol
    where e.date = coalesce(p_date, current_date)
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'date', r.date, 'symbol', r.symbol, 'name', r.name,
           'epsActual', r.eps_actual, 'epsEstimated', r.eps_estimated,
           'revenueActual', r.revenue_actual, 'revenueEstimated', r.revenue_estimated,
           'time', r.time, 'fiscalDate', r.fiscal_date,
           'marketCap', r.market_cap, 'price', r.price, 'changePct', r.change_pct,
           'headline', r.headline)
         order by coalesce(r.market_cap, 0) desc nulls last, r.symbol), '[]'::jsonb)
  from (
    select * from ranked
    order by coalesce(market_cap, 0) desc nulls last, symbol
    limit greatest(1, least(coalesce(p_limit, 40), 80))
  ) r;
$$;

-- Market-summary shape plus each symbol's next earnings date (today or later).
create or replace function public.get_earnings_sidebar(p_view text default 'market_cap',
                                                      p_limit integer default 20,
                                                      p_symbols text[] default null)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with wanted as (
    select upper(unnest(coalesce(p_symbols, array[]::text[]))) as symbol
  ),
  universe as (
    select q.symbol, q.name, q.price, q.change, q.change_pct, q.market_cap, 0 as pref
    from ledger.quote q
    where q.price is not null
      and (
        lower(coalesce(p_view, 'market_cap')) <> 'watchlist'
        or q.symbol in (select symbol from wanted)
      )
    union all
    select h.symbol, h.name, h.price, null::double precision, h.change_pct,
           h.market_cap, 1
    from ledger.heatmap h
    where h.price is not null
      and lower(coalesce(p_view, 'market_cap')) <> 'watchlist'
    union all
    select m.symbol, m.name, m.price, m.change, m.change_pct,
           null::double precision, 2
    from ledger.mover m
    where m.price is not null
      and lower(coalesce(p_view, 'market_cap')) <> 'watchlist'
  ),
  uniq as (
    select distinct on (symbol) symbol, name, price, change, change_pct, market_cap
    from universe order by symbol, pref
  ),
  with_next as (
    select u.*,
           (select min(e.date) from ledger.earnings_event e
             where e.symbol = u.symbol and e.date >= current_date) as next_earnings
    from uniq u
  ),
  ordered as (
    -- CASE branches must share one type; watchlist sorts by symbol as a
    -- second key so we never mix text into the numeric CASE.
    select w.*, row_number() over (order by
             case when lower(coalesce(p_view, 'market_cap')) = 'market_cap'
                    then -coalesce(w.market_cap, 0)
                  when lower(p_view) = 'losers' then w.change_pct
                  when lower(p_view) = 'watchlist' then null::double precision
                  else -w.change_pct end
             nulls last,
             case when lower(coalesce(p_view, 'market_cap')) = 'watchlist'
                    then w.symbol else null end) as ord
    from with_next w
    where lower(coalesce(p_view, 'market_cap')) <> 'market_cap'
       or w.market_cap is not null
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', s.symbol, 'name', s.name, 'price', s.price,
           'change', s.change, 'changePct', s.change_pct,
           'marketCap', s.market_cap,
           'nextEarnings', s.next_earnings) order by s.ord), '[]'::jsonb)
  from ordered s
  where s.ord <= greatest(1, least(coalesce(p_limit, 20), 80));
$$;

do $$
begin
  execute 'revoke all on function public.replace_earnings(jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.replace_earnings(jsonb) to service_role';
  execute 'revoke all on function public.get_earnings_week(date) from public';
  execute 'grant execute on function public.get_earnings_week(date) to anon, authenticated';
  execute 'revoke all on function public.get_earnings_day(date, integer) from public';
  execute 'grant execute on function public.get_earnings_day(date, integer) to anon, authenticated';
  execute 'revoke all on function public.get_earnings_sidebar(text, integer, text[]) from public';
  execute 'grant execute on function public.get_earnings_sidebar(text, integer, text[]) to anon, authenticated';
end $$;
