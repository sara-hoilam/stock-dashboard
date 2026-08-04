-- Ticker Alpha — watchlist history, popularity, and merging an anonymous list
--
-- Apply after 0017. Safe to re-run.
--
-- Three things the watchlist feature needs beyond the tables in 0017:
--   * a record of every add and remove, not just what is currently on a list
--   * how many people watch a symbol, for the count beside the star
--   * a way to hand a list built before signing in to the account afterwards

-- ---------------------------------------------------------------------------
-- History
-- ---------------------------------------------------------------------------
-- watchlist_item says what is on a list now. It cannot say that someone added
-- NVDA in March and dropped it in June, which is the question worth asking of
-- a watchlist. Written by trigger so it cannot be forgotten at a call site.
create table if not exists public.watchlist_event (
  id       bigserial primary key,
  user_id  uuid not null references auth.users (id) on delete cascade,
  symbol   text not null,
  action   text not null check (action in ('add', 'remove')),
  at       timestamptz not null default now()
);
create index if not exists watchlist_event_user_idx on public.watchlist_event (user_id, at desc);
create index if not exists watchlist_event_symbol_idx on public.watchlist_event (symbol, at desc);

alter table public.watchlist_event enable row level security;

do $$
begin
  -- Readable by its owner; nobody writes it by hand.
  drop policy if exists watchlist_event_own on public.watchlist_event;
  create policy watchlist_event_own on public.watchlist_event
    for select using (user_id = auth.uid());
end $$;

create or replace function public.log_watchlist_change()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
declare v_user uuid; v_row record;
begin
  v_row := coalesce(new, old);
  select w.user_id into v_user from public.watchlist w where w.id = v_row.watchlist_id;
  if v_user is null then
    return v_row;                         -- list already gone; nothing to log
  end if;
  insert into public.watchlist_event (user_id, symbol, action)
  values (v_user, v_row.symbol, case when tg_op = 'INSERT' then 'add' else 'remove' end);
  return v_row;
end;
$$;

drop trigger if exists watchlist_item_logged on public.watchlist_item;
create trigger watchlist_item_logged
  after insert or delete on public.watchlist_item
  for each row execute function public.log_watchlist_change();

-- ---------------------------------------------------------------------------
-- Popularity
-- ---------------------------------------------------------------------------
-- "N watchlists include NVDA". Definer because it counts across every user's
-- rows, which row-level security would otherwise hide -- it returns totals
-- only, never who, so nothing about another account leaks through it.
create or replace function public.watchlist_counts(p_symbols text[] default null)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select coalesce(jsonb_object_agg(s.symbol, s.n), '{}'::jsonb)
  from (
    select i.symbol, count(distinct w.user_id) as n
    from public.watchlist_item i
    join public.watchlist w on w.id = i.watchlist_id
    where p_symbols is null or i.symbol = any (p_symbols)
    group by i.symbol
  ) s;
$$;

-- ---------------------------------------------------------------------------
-- Merging a list built before signing in
-- ---------------------------------------------------------------------------
-- A visitor can build a watchlist without an account; it lives in their
-- browser until they sign in. This folds it into the account in one call,
-- keeping whatever is already there rather than replacing it -- a merge, not
-- an overwrite, because the account's list is the one they meant to keep.
create or replace function public.merge_watchlist(p_symbols text[])
returns jsonb
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_uid   uuid := auth.uid();
  v_list  uuid;
  v_added integer := 0;
  v_sym   text;
begin
  if v_uid is null then
    return jsonb_build_object('error', 'not signed in');
  end if;

  select id into v_list from public.watchlist
   where user_id = v_uid and is_default limit 1;
  if v_list is null then
    insert into public.watchlist (user_id, name, is_default)
    values (v_uid, 'My watchlist', true)
    returning id into v_list;
  end if;

  foreach v_sym in array coalesce(p_symbols, '{}')
  loop
    v_sym := upper(trim(v_sym));
    continue when v_sym !~ '^[A-Z][A-Z.\-]{0,9}$';
    insert into public.watchlist_item (watchlist_id, symbol)
    values (v_list, v_sym)
    on conflict (watchlist_id, symbol) do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;

  return jsonb_build_object('list', v_list, 'added', v_added);
end;
$$;

-- ---------------------------------------------------------------------------
-- Is this one symbol on my list? Cheap enough for the star on every page.
-- ---------------------------------------------------------------------------
create or replace function public.is_watched(p_symbol text)
returns jsonb
language sql stable security definer
set search_path = public, pg_temp
as $$
  select jsonb_build_object(
    'symbol', upper(p_symbol),
    'watching', coalesce((
      select true from public.watchlist_item i
      join public.watchlist w on w.id = i.watchlist_id
      where w.user_id = auth.uid() and i.symbol = upper(p_symbol) limit 1), false),
    'watchers', coalesce((
      select count(distinct w.user_id) from public.watchlist_item i
      join public.watchlist w on w.id = i.watchlist_id
      where i.symbol = upper(p_symbol)), 0));
$$;

do $$
begin
  -- Counts are public: an anonymous visitor sees "N watchers" before signing
  -- in, which is the point of showing it.
  execute 'revoke all on function public.watchlist_counts(text[]) from public';
  execute 'grant execute on function public.watchlist_counts(text[]) to anon, authenticated';
  execute 'revoke all on function public.is_watched(text) from public';
  execute 'grant execute on function public.is_watched(text) to anon, authenticated';
  -- Writing needs an account.
  execute 'revoke all on function public.merge_watchlist(text[]) from public, anon';
  execute 'grant execute on function public.merge_watchlist(text[]) to authenticated';
end $$;
