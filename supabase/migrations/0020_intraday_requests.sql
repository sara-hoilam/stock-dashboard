-- Ticker Alpha — intraday on demand, for any company someone follows
--
-- Apply after 0019. Safe to re-run.
--
-- The worker keeps a five-minute series for a fixed list: the curated
-- watchlist plus the day's biggest movers. Everything else had none, so a
-- company added to a personal watchlist got a row in the table and an empty
-- chart. The page now falls back to daily closes, which is honest but is not
-- what the panel is for -- a followed company should show today.
--
-- Intraday asks the way prices and coverage already do: the page requests,
-- the worker drains, the page picks the answer up. Same table shape, same
-- guards. What differs is the clock. A daily bar is good for twelve hours; a
-- five-minute series is stale in five, and only while the market is open.

create table if not exists ledger.intraday_request (
  symbol       text primary key,
  requested_at timestamptz not null default now(),
  done_at      timestamptz
);

alter table ledger.intraday_request enable row level security;

-- ---------------------------------------------------------------------------
-- Is the US market open right now?
-- ---------------------------------------------------------------------------
-- Weekday, 09:30 to 16:00 New York, with a little room after the bell for the
-- last bars to land. The timezone name rather than a fixed offset, so this
-- follows daylight saving without being maintained twice a year.
--
-- Holidays are not modelled. On Thanksgiving this returns true and a viewer's
-- request is fetched and found unchanged -- one wasted call for a company
-- someone is actually looking at, roughly a dozen times a year. A holiday
-- calendar would have to be fed and would fail silently when it went stale,
-- which is the worse trade.
-- Stable rather than immutable: converting to a named zone reads the timezone
-- database, which can change under a running server.
create or replace function ledger.market_open(p_at timestamptz default now())
returns boolean
language sql stable
as $$
  select extract(isodow from (p_at at time zone 'America/New_York')) < 6
     and (p_at at time zone 'America/New_York')::time
         between '09:30'::time and '16:15'::time;
$$;

-- ---------------------------------------------------------------------------
-- Read — now says whether what it returned is worth replacing
-- ---------------------------------------------------------------------------
-- Replaces 0005's. Two additions: `stale`, so the page knows to ask, and
-- `updatedAt`, so it can say when the series was last touched. A missing row
-- still returns null, which is what the page already reads as "nothing yet".
create or replace function public.get_intraday(p_symbol text)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select jsonb_build_object(
           'symbol', i.symbol, 'asOf', i.as_of, 'points', i.points,
           'updatedAt', i.updated_at,
           -- During the session a quarter of an hour is old. Once it has
           -- closed the series cannot change, so an evening visitor refreshes
           -- it once rather than every time they open the page.
           'stale', i.updated_at < now() - case
                      when ledger.market_open() then interval '15 minutes'
                      else interval '12 hours' end,
           'quote', (select jsonb_build_object(
                              'price', q.price, 'change', q.change,
                              'changePct', q.change_pct, 'name', q.name)
                     from ledger.quote q where q.symbol = i.symbol))
  from ledger.intraday i
  where i.symbol = upper(p_symbol);
$$;

-- ---------------------------------------------------------------------------
-- Request — the page may ask, but only for a plausible symbol
-- ---------------------------------------------------------------------------
create or replace function public.request_intraday(p_symbol text)
returns jsonb
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare sym text := upper(trim(coalesce(p_symbol, '')));
begin
  if sym !~ '^[A-Z][A-Z.\-]{0,9}$' then
    return jsonb_build_object('queued', false, 'reason', 'not a ticker');
  end if;

  insert into ledger.intraday_request (symbol, requested_at, done_at)
  values (sym, now(), null)
  on conflict (symbol) do update
    -- Re-asking within five minutes is the page polling, not a new request.
    set requested_at = case
          when ledger.intraday_request.requested_at < now() - interval '5 minutes'
            or ledger.intraday_request.done_at is not null
          then now() else ledger.intraday_request.requested_at end,
        -- Reopen once the answer is as old as the series it fetched.
        done_at = case
          when ledger.intraday_request.done_at < now() - case
                 when ledger.market_open() then interval '15 minutes'
                 else interval '12 hours' end
          then null else ledger.intraday_request.done_at end;

  return jsonb_build_object('queued', true, 'symbol', sym);
end;
$$;

create or replace function public.pending_intraday(p_limit integer default 5)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(r.symbol order by r.requested_at), '[]'::jsonb)
  from (select symbol, requested_at from ledger.intraday_request
        where done_at is null
        order by requested_at
        limit greatest(1, least(coalesce(p_limit, 5), 25))) r;
$$;

-- Replaces 0005's, to close the request. The request is closed whatever came
-- back, so a symbol FMP has no series for -- a delisting, a bad ticker --
-- cannot spin the queue forever.
create or replace function public.upsert_intraday(p_symbol text, p_points jsonb,
                                                  p_as_of date)
returns void
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare sym text := upper(p_symbol);
begin
  insert into ledger.intraday (symbol, points, as_of, updated_at)
  values (sym, p_points, p_as_of, now())
  on conflict (symbol) do update
    set points = excluded.points, as_of = excluded.as_of, updated_at = now();

  update ledger.intraday_request set done_at = now() where symbol = sym;
end;
$$;

-- A symbol nobody has a series for still has to close its request, or the
-- worker draws it again on every pass and never gets past it.
create or replace function public.skip_intraday(p_symbol text)
returns void
language sql volatile security definer
set search_path = ledger, pg_temp
as $$
  update ledger.intraday_request set done_at = now()
   where symbol = upper(p_symbol);
$$;

-- ---------------------------------------------------------------------------
-- What people actually follow
-- ---------------------------------------------------------------------------
-- So the worker can keep followed companies fresh on its own cadence rather
-- than only when someone is looking. Most-watched first, because that is the
-- order in which the budget should run out. Counts only -- it returns which
-- symbols are popular, never who follows them.
create or replace function public.watchlisted_symbols(p_limit integer default 40)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_agg(s.symbol order by s.n desc, s.symbol), '[]'::jsonb)
  from (
    select i.symbol, count(distinct w.user_id) as n
    from public.watchlist_item i
    join public.watchlist w on w.id = i.watchlist_id
    group by i.symbol
    order by n desc, i.symbol
    limit greatest(1, least(coalesce(p_limit, 40), 200))
  ) s;
$$;

do $$
begin
  execute 'revoke all on function public.request_intraday(text) from public';
  execute 'grant execute on function public.request_intraday(text) to anon, authenticated';
  execute 'revoke all on function public.get_intraday(text) from public';
  execute 'grant execute on function public.get_intraday(text) to anon, authenticated';
  execute 'revoke all on function public.pending_intraday(integer) from public, anon, authenticated';
  execute 'grant execute on function public.pending_intraday(integer) to service_role';
  execute 'revoke all on function public.upsert_intraday(text, jsonb, date) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_intraday(text, jsonb, date) to service_role';
  execute 'revoke all on function public.skip_intraday(text) from public, anon, authenticated';
  execute 'grant execute on function public.skip_intraday(text) to service_role';
  execute 'revoke all on function public.watchlisted_symbols(integer) from public, anon, authenticated';
  execute 'grant execute on function public.watchlisted_symbols(integer) to service_role';
end $$;
