-- Ticker Alpha — user accounts, watchlists, and the shape of the portfolio
--
-- Apply after 0016. Safe to re-run.
--
-- ---------------------------------------------------------------------------
-- Why these tables live in `public` and not in `ledger`
-- ---------------------------------------------------------------------------
-- Everything in `ledger` is the same for every visitor, so it sits in a schema
-- PostgREST does not expose and is read through SECURITY DEFINER functions.
-- That model is wrong for user data. A definer function that forgets one
-- `where user_id = auth.uid()` hands every user's watchlist to every other
-- user, silently, and nothing in the database objects.
--
-- These tables therefore use row-level security instead: ownership is checked
-- by Postgres on every row of every query, so a mistake in application SQL
-- fails closed rather than leaking. The browser talks to them directly with
-- the signed-in user's JWT; the anon key alone reaches nothing here.
--
-- The one exception is get_watchlist(), which is a definer function because it
-- joins user rows to prices in `ledger` -- a schema the browser cannot see. It
-- filters on auth.uid() itself, and is the only place that has to.

-- ---------------------------------------------------------------------------
-- Profile — one row per account
-- ---------------------------------------------------------------------------
-- auth.users is managed by Supabase and should not be extended directly, so
-- anything of ours about a person hangs off this instead.
create table if not exists public.profile (
  id           uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Created on sign-up rather than on first write, so the rest of the app can
-- assume it exists.
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profile (id, display_name)
  values (new.id, coalesce(new.raw_user_meta_data->>'full_name',
                           new.raw_user_meta_data->>'name',
                           split_part(new.email, '@', 1)))
  on conflict (id) do nothing;
  return new;
end;
$$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------------
-- Watchlists
-- ---------------------------------------------------------------------------
-- A list rather than a bare set of symbols, because "my watchlist" becomes
-- "tech" and "dividends" the moment anyone uses it seriously, and adding that
-- later means migrating rows that already exist.
create table if not exists public.watchlist (
  id         uuid primary key default gen_random_uuid(),
  user_id    uuid not null references auth.users (id) on delete cascade,
  name       text not null default 'My watchlist',
  is_default boolean not null default false,
  created_at timestamptz not null default now(),
  unique (user_id, name)
);
create index if not exists watchlist_user_idx on public.watchlist (user_id);

-- Exactly one default per user, enforced by the index rather than by hope.
create unique index if not exists watchlist_one_default_idx
  on public.watchlist (user_id) where is_default;

create table if not exists public.watchlist_item (
  id           bigserial primary key,
  watchlist_id uuid not null references public.watchlist (id) on delete cascade,
  -- Text, not a foreign key to ledger.company: a visitor may watch a symbol
  -- this project has never ingested, and a list should not refuse it.
  symbol       text not null check (symbol = upper(symbol) and symbol <> ''),
  note         text,
  sort_order   integer,
  added_at     timestamptz not null default now(),
  unique (watchlist_id, symbol)
);
create index if not exists watchlist_item_list_idx on public.watchlist_item (watchlist_id);

-- ---------------------------------------------------------------------------
-- Portfolio — built now, filled later
-- ---------------------------------------------------------------------------
-- Transactions are the source of truth and positions are derived from them.
-- The alternative -- one row per holding carrying quantity and average cost --
-- looks simpler and cannot answer the questions a portfolio exists to answer:
-- what the realised gain was, what the cost basis is after a partial sale,
-- what the dividends came to, or what the numbers were before last March's
-- typo. Those need the history, and history cannot be reconstructed from a
-- running total.
create table if not exists public.portfolio (
  id            uuid primary key default gen_random_uuid(),
  user_id       uuid not null references auth.users (id) on delete cascade,
  name          text not null default 'My portfolio',
  base_currency text not null default 'USD',
  created_at    timestamptz not null default now(),
  unique (user_id, name)
);
create index if not exists portfolio_user_idx on public.portfolio (user_id);

create table if not exists public.portfolio_transaction (
  id           bigserial primary key,
  portfolio_id uuid not null references public.portfolio (id) on delete cascade,
  symbol       text not null check (symbol = upper(symbol) and symbol <> ''),
  kind         text not null check (kind in
                 ('buy','sell','dividend','split','fee','deposit','withdrawal')),
  trade_date   date not null,
  -- Numeric, never float: money that does not add up exactly is a bug report.
  -- Eight decimals covers fractional shares and split ratios.
  quantity     numeric(20,8),
  price        numeric(20,8),
  fee          numeric(20,8) not null default 0,
  currency     text not null default 'USD',
  note         text,
  created_at   timestamptz not null default now()
);
create index if not exists portfolio_tx_pf_idx
  on public.portfolio_transaction (portfolio_id, symbol, trade_date);

-- Current position per symbol, derived. security_invoker means the view runs
-- as the caller, so the row-level policies below apply to it unchanged.
create or replace view public.portfolio_position
with (security_invoker = true) as
  select
    t.portfolio_id,
    t.symbol,
    sum(case t.kind when 'buy' then t.quantity
                    when 'sell' then -t.quantity
                    else 0 end)                                as quantity,
    sum(case t.kind when 'buy'  then t.quantity * t.price + t.fee
                    else 0 end)                                as cost_in,
    sum(case t.kind when 'sell' then t.quantity * t.price - t.fee
                    else 0 end)                                as proceeds,
    sum(case t.kind when 'dividend' then coalesce(t.price, 0) else 0 end) as dividends,
    min(t.trade_date)                                          as first_trade,
    max(t.trade_date)                                          as last_trade
  from public.portfolio_transaction t
  group by t.portfolio_id, t.symbol
  having sum(case t.kind when 'buy' then t.quantity
                         when 'sell' then -t.quantity else 0 end) <> 0;

-- ---------------------------------------------------------------------------
-- Row-level security — the point of the whole design
-- ---------------------------------------------------------------------------
alter table public.profile               enable row level security;
alter table public.watchlist             enable row level security;
alter table public.watchlist_item        enable row level security;
alter table public.portfolio             enable row level security;
alter table public.portfolio_transaction enable row level security;

do $$
begin
  -- Own row only, for every verb. Policies are dropped first so the file can
  -- be re-run without collecting duplicates.
  drop policy if exists profile_own on public.profile;
  create policy profile_own on public.profile
    for all using (id = auth.uid()) with check (id = auth.uid());

  drop policy if exists watchlist_own on public.watchlist;
  create policy watchlist_own on public.watchlist
    for all using (user_id = auth.uid()) with check (user_id = auth.uid());

  drop policy if exists portfolio_own on public.portfolio;
  create policy portfolio_own on public.portfolio
    for all using (user_id = auth.uid()) with check (user_id = auth.uid());

  -- Children are owned through their parent, so the check is a lookup rather
  -- than a duplicated user_id column that could disagree with it.
  drop policy if exists watchlist_item_own on public.watchlist_item;
  create policy watchlist_item_own on public.watchlist_item
    for all using (exists (select 1 from public.watchlist w
                           where w.id = watchlist_id and w.user_id = auth.uid()))
    with check (exists (select 1 from public.watchlist w
                        where w.id = watchlist_id and w.user_id = auth.uid()));

  drop policy if exists portfolio_tx_own on public.portfolio_transaction;
  create policy portfolio_tx_own on public.portfolio_transaction
    for all using (exists (select 1 from public.portfolio p
                           where p.id = portfolio_id and p.user_id = auth.uid()))
    with check (exists (select 1 from public.portfolio p
                        where p.id = portfolio_id and p.user_id = auth.uid()));
end $$;

-- Signed-in users act on their own rows; the anon key reaches nothing here.
grant usage on schema public to authenticated;
grant select, insert, update, delete on
  public.profile, public.watchlist, public.watchlist_item,
  public.portfolio, public.portfolio_transaction to authenticated;
grant select on public.portfolio_position to authenticated;
grant usage, select on all sequences in schema public to authenticated;

-- ---------------------------------------------------------------------------
-- A cap, because the anon key is public and anyone may sign up
-- ---------------------------------------------------------------------------
create or replace function public.enforce_watchlist_cap()
returns trigger
language plpgsql security definer
set search_path = public, pg_temp
as $$
begin
  if (select count(*) from public.watchlist_item
      where watchlist_id = new.watchlist_id) >= 250 then
    raise exception 'watchlist is limited to 250 symbols';
  end if;
  return new;
end;
$$;

drop trigger if exists watchlist_item_cap on public.watchlist_item;
create trigger watchlist_item_cap
  before insert on public.watchlist_item
  for each row execute function public.enforce_watchlist_cap();

-- ---------------------------------------------------------------------------
-- The one definer function: watchlist joined to prices
-- ---------------------------------------------------------------------------
-- ledger is invisible to the browser, so the join has to happen here. This is
-- the only place that filters on auth.uid() by hand; everything else is RLS.
create or replace function public.get_watchlist(p_list uuid default null)
returns jsonb
language sql stable security definer
set search_path = public, ledger, pg_temp
as $$
  with me as (select auth.uid() as uid),
  list as (
    select w.id, w.name
    from public.watchlist w, me
    where w.user_id = me.uid
      and (p_list is null and w.is_default or w.id = p_list)
    limit 1
  )
  select case when auth.uid() is null then jsonb_build_object('error', 'not signed in')
  else jsonb_build_object(
    'list', (select jsonb_build_object('id', id, 'name', name) from list),
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'symbol', i.symbol,
               'note', i.note,
               'addedAt', i.added_at,
               'name', coalesce(q.name, c.name, t.name),
               'price', q.price,
               'changePct', q.change_pct,
               'marketCap', q.market_cap)
             order by coalesce(i.sort_order, 2147483647), i.symbol)
      from public.watchlist_item i
      join list l on l.id = i.watchlist_id
      left join ledger.quote   q on q.symbol = i.symbol
      left join ledger.ticker  t on t.ticker = i.symbol
      left join ledger.company c on c.ticker = i.symbol), '[]'::jsonb))
  end;
$$;

-- Create the default list on first use, so the page never has to.
create or replace function public.toggle_watchlist(p_symbol text)
returns jsonb
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_uid  uuid := auth.uid();
  v_list uuid;
  v_sym  text := upper(trim(coalesce(p_symbol, '')));
  v_had  boolean;
begin
  if v_uid is null then
    return jsonb_build_object('error', 'not signed in');
  end if;
  if v_sym !~ '^[A-Z][A-Z.\-]{0,9}$' then
    return jsonb_build_object('error', 'not a ticker');
  end if;

  select id into v_list from public.watchlist
   where user_id = v_uid and is_default limit 1;
  if v_list is null then
    insert into public.watchlist (user_id, name, is_default)
    values (v_uid, 'My watchlist', true)
    returning id into v_list;
  end if;

  delete from public.watchlist_item
   where watchlist_id = v_list and symbol = v_sym;
  get diagnostics v_had = row_count;

  if not v_had then
    insert into public.watchlist_item (watchlist_id, symbol) values (v_list, v_sym);
  end if;
  return jsonb_build_object('symbol', v_sym, 'watching', not v_had);
end;
$$;

do $$
begin
  execute 'revoke all on function public.get_watchlist(uuid) from public, anon';
  execute 'grant execute on function public.get_watchlist(uuid) to authenticated';
  execute 'revoke all on function public.toggle_watchlist(text) from public, anon';
  execute 'grant execute on function public.toggle_watchlist(text) to authenticated';
end $$;
