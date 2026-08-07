-- Ticker Alpha — a decade of closes, for correlation over calendar months
--
-- Apply after 0053. Safe to re-run.
--
-- ledger.price_daily holds 300 calendar days of OHLCV, which is what a
-- candlestick chart needs and all it needs. The portfolio's correlation
-- heatmap asks a different question: how did this holding move with the rest
-- of the portfolio in every January of the last ten years. Each cell wants
-- daily observations, and ten Januaries is about 210 of them -- so the series
-- has to reach back ten years, and 300 days cannot answer at any lookback
-- beyond one year.
--
-- Stored separately and close-only rather than by widening price_daily. A
-- decade of OHLCV is ~211KB per symbol against ~82KB for date and close
-- alone, and the candlestick chart would then download ten years to draw six
-- months. Two series, each the shape of its own job.

create table if not exists ledger.price_close_long (
  symbol      text primary key,
  closes      jsonb not null,            -- [{d:'YYYY-MM-DD', c:123.45}, ...]
  first_day   date,
  last_day    date,
  updated_at  timestamptz not null default now()
);

alter table ledger.price_close_long enable row level security;

-- ---------------------------------------------------------------------------
-- Read — several symbols at once, because a portfolio asks for all of them
-- ---------------------------------------------------------------------------
create or replace function public.get_long_closes(p_symbols text[])
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_object_agg(l.symbol, jsonb_build_object(
           'closes', l.closes, 'from', l.first_day, 'to', l.last_day,
           -- A week old is fine: these are years of history, and the recent
           -- end is already covered by price_daily.
           'stale', l.updated_at < now() - interval '7 days')), '{}'::jsonb)
  from ledger.price_close_long l
  where l.symbol = any (select upper(unnest(coalesce(p_symbols, '{}'::text[]))));
$$;

-- ---------------------------------------------------------------------------
-- Request — the page may ask, for plausible symbols only
-- ---------------------------------------------------------------------------
create table if not exists ledger.long_close_request (
  symbol       text primary key,
  requested_at timestamptz not null default now(),
  done_at      timestamptz
);

alter table ledger.long_close_request enable row level security;

create or replace function public.request_long_closes(p_symbols text[])
returns jsonb
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare sym text; n integer := 0;
begin
  foreach sym in array coalesce(p_symbols, '{}'::text[])
  loop
    sym := upper(trim(sym));
    continue when sym !~ '^[A-Z][A-Z.\-]{0,9}$';
    insert into ledger.long_close_request (symbol, requested_at, done_at)
    values (sym, now(), null)
    on conflict (symbol) do update
      set requested_at = case
            when ledger.long_close_request.requested_at < now() - interval '1 hour'
              or ledger.long_close_request.done_at is not null
            then now() else ledger.long_close_request.requested_at end,
          done_at = case
            when ledger.long_close_request.done_at < now() - interval '7 days'
            then null else ledger.long_close_request.done_at end;
    n := n + 1;
  end loop;
  return jsonb_build_object('queued', n);
end;
$$;

create or replace function public.pending_long_closes(p_limit integer default 5)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(r.symbol order by r.requested_at), '[]'::jsonb)
  from (select symbol, requested_at from ledger.long_close_request
        where done_at is null
        order by requested_at
        limit greatest(1, least(coalesce(p_limit, 5), 25))) r;
$$;

create or replace function public.upsert_long_closes(p_symbol text, p_closes jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare sym text := upper(p_symbol); n integer;
begin
  if p_closes is null or jsonb_typeof(p_closes) <> 'array'
     or jsonb_array_length(p_closes) = 0 then
    -- Close the request even so: a symbol FMP has no history for must not sit
    -- at the head of the queue for ever.
    update ledger.long_close_request set done_at = now() where symbol = sym;
    return 0;
  end if;

  n := jsonb_array_length(p_closes);
  insert into ledger.price_close_long (symbol, closes, first_day, last_day, updated_at)
  values (sym, p_closes,
          (p_closes->0->>'d')::date,
          (p_closes->(n - 1)->>'d')::date,
          now())
  on conflict (symbol) do update
    set closes = excluded.closes, first_day = excluded.first_day,
        last_day = excluded.last_day, updated_at = now();

  update ledger.long_close_request set done_at = now() where symbol = sym;
  return n;
end;
$$;

do $$
begin
  execute 'revoke all on function public.get_long_closes(text[]) from public';
  execute 'grant execute on function public.get_long_closes(text[]) to anon, authenticated';
  execute 'revoke all on function public.request_long_closes(text[]) from public';
  execute 'grant execute on function public.request_long_closes(text[]) to anon, authenticated';
  execute 'revoke all on function public.pending_long_closes(integer) from public, anon, authenticated';
  execute 'grant execute on function public.pending_long_closes(integer) to service_role';
  execute 'revoke all on function public.upsert_long_closes(text, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_long_closes(text, jsonb) to service_role';
end $$;
