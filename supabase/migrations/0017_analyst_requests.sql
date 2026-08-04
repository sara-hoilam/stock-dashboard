-- Ticker Alpha — a queue of its own for analyst coverage
--
-- Apply after 0016. Safe to re-run.
--
-- 0016 filled ledger.analyst as a passenger on the price fetch, which only runs
-- when the page finds prices missing or more than twelve hours old. A company
-- whose prices are already fresh therefore never got coverage, and the section
-- on its report sat on a spinner that nothing was ever going to resolve. Every
-- company but the one used to develop the feature was in that state.
--
-- Coverage now asks the way prices do: the page requests, the worker drains,
-- the page picks the answer up. Same table shape, same guards.

create table if not exists ledger.analyst_request (
  symbol       text primary key,
  requested_at timestamptz not null default now(),
  done_at      timestamptz
);

alter table ledger.analyst_request enable row level security;

-- The page may ask, but only for a plausible symbol.
create or replace function public.request_analyst(p_symbol text)
returns jsonb
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare sym text := upper(trim(coalesce(p_symbol, '')));
begin
  if sym !~ '^[A-Z][A-Z.\-]{0,9}$' then
    return jsonb_build_object('queued', false, 'reason', 'not a ticker');
  end if;

  insert into ledger.analyst_request (symbol, requested_at, done_at)
  values (sym, now(), null)
  on conflict (symbol) do update
    -- Re-asking within the hour is the page polling, not a new request.
    set requested_at = case
          when ledger.analyst_request.requested_at < now() - interval '1 hour'
            or ledger.analyst_request.done_at is not null
          then now() else ledger.analyst_request.requested_at end,
        -- A day old is fine for analyst actions, which is what get_analyst
        -- already calls stale.
        done_at = case
          when ledger.analyst_request.done_at < now() - interval '24 hours'
          then null else ledger.analyst_request.done_at end;

  return jsonb_build_object('queued', true, 'symbol', sym);
end;
$$;

create or replace function public.pending_analyst(p_limit integer default 5)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(r.symbol order by r.requested_at), '[]'::jsonb)
  from (select symbol, requested_at from ledger.analyst_request
        where done_at is null
        order by requested_at
        limit greatest(1, least(coalesce(p_limit, 5), 25))) r;
$$;

-- Replaces 0016's. Two changes: the request is closed whatever came back, so
-- a company no house covers cannot spin the queue forever; and a field FMP
-- did not return this time keeps the value it had, so one failing endpoint
-- cannot blank a section that was complete a minute ago.
create or replace function public.upsert_analyst(p_symbol text, p_row jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare sym text := upper(p_symbol);
begin
  insert into ledger.analyst (symbol, target, target_counts, consensus,
                              grades, news, updated_at)
  values (sym, p_row->'target', p_row->'targetCounts',
          p_row->'consensus', p_row->'grades', p_row->'news', now())
  on conflict (symbol) do update
    set target        = coalesce(excluded.target,        ledger.analyst.target),
        target_counts = coalesce(excluded.target_counts, ledger.analyst.target_counts),
        consensus     = coalesce(excluded.consensus,     ledger.analyst.consensus),
        grades        = coalesce(excluded.grades,        ledger.analyst.grades),
        news          = coalesce(excluded.news,          ledger.analyst.news),
        updated_at    = now();

  update ledger.analyst_request set done_at = now() where symbol = sym;
  return 1;
end;
$$;

do $$
begin
  execute 'revoke all on function public.request_analyst(text) from public';
  execute 'grant execute on function public.request_analyst(text) to anon, authenticated';
  execute 'revoke all on function public.pending_analyst(integer) from public, anon, authenticated';
  execute 'grant execute on function public.pending_analyst(integer) to service_role';
  execute 'revoke all on function public.upsert_analyst(text, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_analyst(text, jsonb) to service_role';
end $$;
