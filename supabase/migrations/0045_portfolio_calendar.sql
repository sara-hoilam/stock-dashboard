-- Ticker Alpha — portfolio Calendar (earnings, ex-div, US economics)
--
-- Apply after 0044. Safe to re-run.
--
-- FMP's economic-calendar feeds ledger.economic_event (US releases: jobs,
-- CPI, FOMC, etc.). get_portfolio_calendar bundles earnings + dividends for
-- the caller's symbols with those macro events for a date window.

create table if not exists ledger.economic_event (
  event_date   date not null,
  event_time   text,
  country      text not null default 'US',
  currency     text,
  event        text not null,
  impact       text,
  previous     double precision,
  estimate     double precision,
  actual       double precision,
  change       double precision,
  change_pct   double precision,
  updated_at   timestamptz not null default now(),
  primary key (event_date, country, event)
);
create index if not exists economic_event_date_idx
  on ledger.economic_event (event_date);
create index if not exists economic_event_country_date_idx
  on ledger.economic_event (country, event_date);

alter table ledger.economic_event enable row level security;

create or replace function public.replace_economic_calendar(p_rows jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  delete from ledger.economic_event where event_date is not null;
  insert into ledger.economic_event
    (event_date, event_time, country, currency, event, impact,
     previous, estimate, actual, change, change_pct, updated_at)
  select nullif(r->>'date','')::date,
         nullif(r->>'time',''),
         upper(coalesce(nullif(r->>'country',''), 'US')),
         nullif(r->>'currency',''),
         coalesce(nullif(r->>'event',''), 'Event'),
         nullif(r->>'impact',''),
         nullif(r->>'previous','')::double precision,
         nullif(r->>'estimate','')::double precision,
         nullif(r->>'actual','')::double precision,
         nullif(r->>'change','')::double precision,
         nullif(r->>'changePct','')::double precision,
         now()
  from jsonb_array_elements(p_rows) r
  where nullif(r->>'date','') is not null
    and nullif(r->>'event','') is not null
  on conflict (event_date, country, event) do update set
    event_time = excluded.event_time,
    currency = excluded.currency,
    impact = excluded.impact,
    previous = excluded.previous,
    estimate = excluded.estimate,
    actual = excluded.actual,
    change = excluded.change,
    change_pct = excluded.change_pct,
    updated_at = now();
  get diagnostics n = row_count;
  return n;
end;
$$;

-- Month (or arbitrary window) bundle for the portfolio Calendar panel.
create or replace function public.get_portfolio_calendar(
  p_from date default current_date,
  p_to   date default (current_date + 30),
  p_symbols text[] default null
)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with wanted as (
    select upper(trim(s)) as symbol
    from unnest(coalesce(p_symbols, array[]::text[])) s
    where upper(trim(s)) ~ '^[A-Z][A-Z.\-]{0,9}$'
  ),
  earn as (
    select jsonb_agg(jsonb_build_object(
             'kind', 'earnings',
             'date', e.date,
             'symbol', e.symbol,
             'name', coalesce(t.name, c.name, q.name, e.symbol),
             'time', e.time,
             'epsActual', e.eps_actual,
             'epsEstimated', e.eps_estimated,
             'revenueActual', e.revenue_actual,
             'revenueEstimated', e.revenue_estimated)
           order by e.date, coalesce(q.market_cap, 0) desc nulls last, e.symbol) as rows
    from ledger.earnings_event e
    left join ledger.ticker  t on t.ticker = e.symbol
    left join ledger.company c on c.ticker = e.symbol
    left join ledger.quote   q on q.symbol = e.symbol
    where e.date between coalesce(p_from, current_date)
                     and coalesce(p_to, current_date + 30)
      and e.symbol in (select symbol from wanted)
  ),
  divs as (
    select jsonb_agg(jsonb_build_object(
             'kind', 'dividend',
             'date', d.ex_date,
             'symbol', d.symbol,
             'name', coalesce(t.name, c.name, q.name, d.symbol),
             'amount', coalesce(d.adj_amount, d.amount),
             'yield', d.yield,
             'paymentDate', d.payment_date)
           order by d.ex_date, d.symbol) as rows
    from ledger.dividend_event d
    left join ledger.ticker  t on t.ticker = d.symbol
    left join ledger.company c on c.ticker = d.symbol
    left join ledger.quote   q on q.symbol = d.symbol
    where d.ex_date between coalesce(p_from, current_date)
                        and coalesce(p_to, current_date + 30)
      and d.symbol in (select symbol from wanted)
      and coalesce(d.adj_amount, d.amount) is not null
  ),
  econ as (
    select jsonb_agg(jsonb_build_object(
             'kind', 'economics',
             'date', e.event_date,
             'time', e.event_time,
             'country', e.country,
             'event', e.event,
             'impact', e.impact,
             'previous', e.previous,
             'estimate', e.estimate,
             'actual', e.actual)
           order by e.event_date,
                    case lower(coalesce(e.impact,''))
                      when 'high' then 0 when 'medium' then 1 else 2 end,
                    e.event) as rows
    from ledger.economic_event e
    where e.event_date between coalesce(p_from, current_date)
                           and coalesce(p_to, current_date + 30)
      and e.country = 'US'
  )
  select jsonb_build_object(
    'from', coalesce(p_from, current_date),
    'to', coalesce(p_to, current_date + 30),
    'earnings', coalesce((select rows from earn), '[]'::jsonb),
    'dividends', coalesce((select rows from divs), '[]'::jsonb),
    'economics', coalesce((select rows from econ), '[]'::jsonb)
  );
$$;

do $$
begin
  execute 'revoke all on function public.replace_economic_calendar(jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.replace_economic_calendar(jsonb) to service_role';

  execute 'revoke all on function public.get_portfolio_calendar(date, date, text[]) from public';
  execute 'grant execute on function public.get_portfolio_calendar(date, date, text[]) to anon, authenticated';
end $$;
