-- Ticker Alpha — the Google Analytics identifiers, kept against the account
--
-- Apply after 0024. Safe to re-run.
--
-- ---------------------------------------------------------------------------
-- Why these two columns exist
-- ---------------------------------------------------------------------------
-- GA4 knows what happened and Supabase knows who it happened to, and neither
-- can answer a question that needs both -- "do the people who build a
-- watchlist in week one still read the news page in week four" is two
-- datasets or it is nothing. The client id is what joins them, so it is
-- written once per account and read in SQL later.
--
-- It is also what the Measurement Protocol needs. A renewal charged by the
-- billing provider happens with no browser present, so the purchase event has
-- to be sent from the server, and the server has to be told which visitor it
-- belongs to. Without a stored client id that event arrives unattributed and
-- the whole subscription funnel ends at the last thing the browser saw.
--
-- Neither value identifies a person. The client id is a random number this
-- browser was given by the tag; it is not an advertising id and carries
-- nothing from any other site.

alter table public.profile
  add column if not exists ga_client_id  text,
  add column if not exists ga_session_id text;

comment on column public.profile.ga_client_id is
  'GA4 client id (cid). Durable: set once and never overwritten, because a '
  'replacement orphans every event already reported under the old one.';
comment on column public.profile.ga_session_id is
  'GA4 session id. The latest one seen; sessions expire, so this is a hint '
  'for server-side events rather than a key.';

-- ---------------------------------------------------------------------------
-- The client id is written once
-- ---------------------------------------------------------------------------
-- Enforced here rather than in the browser because the browser is not the only
-- thing that can update this row, and a rule that lives in one caller is a
-- rule that is already broken somewhere else. A visitor who clears their
-- cookies is issued a new client id on their next visit; taking it would quietly
-- disconnect the account from everything it had already reported.
create or replace function public.keep_first_ga_client_id()
returns trigger
language plpgsql
set search_path = public, pg_temp
as $$
begin
  if old.ga_client_id is not null and old.ga_client_id is distinct from new.ga_client_id then
    new.ga_client_id := old.ga_client_id;
  end if;
  return new;
end;
$$;

drop trigger if exists profile_keep_ga_client_id on public.profile;
create trigger profile_keep_ga_client_id
  before update on public.profile
  for each row execute function public.keep_first_ga_client_id();

-- ---------------------------------------------------------------------------
-- What the page calls
-- ---------------------------------------------------------------------------
-- A definer function rather than a REST PATCH so that the row is created when
-- an account predates the profile trigger, and so the caller cannot reach any
-- column but these two. It writes for auth.uid() and takes no user id: an
-- argument the caller chooses is an argument the caller can get wrong.
create or replace function public.set_ga_ids(p_client_id text, p_session_id text default null)
returns jsonb
language plpgsql volatile security definer
set search_path = public, pg_temp
as $$
declare
  v_uid uuid := auth.uid();
  v_cid text := nullif(trim(coalesce(p_client_id, '')), '');
  v_sid text := nullif(trim(coalesce(p_session_id, '')), '');
begin
  if v_uid is null then
    return jsonb_build_object('error', 'not signed in');
  end if;

  -- gtag reports these as "1234567890.1234567890" and "1712345678". Anything
  -- else did not come from the tag, and storing it would only make the join
  -- fail later, somewhere harder to look at.
  if v_cid is null or v_cid !~ '^[0-9]+\.[0-9]+$' then
    return jsonb_build_object('error', 'not a client id');
  end if;
  if v_sid is not null and v_sid !~ '^[0-9]{1,20}$' then
    v_sid := null;
  end if;

  insert into public.profile (id, ga_client_id, ga_session_id)
  values (v_uid, v_cid, v_sid)
  on conflict (id) do update
    set ga_client_id  = coalesce(public.profile.ga_client_id, excluded.ga_client_id),
        ga_session_id = coalesce(excluded.ga_session_id, public.profile.ga_session_id),
        updated_at    = now();

  return jsonb_build_object('ok', true);
end;
$$;

do $$
begin
  execute 'revoke all on function public.set_ga_ids(text, text) from public, anon';
  execute 'grant execute on function public.set_ga_ids(text, text) to authenticated';
end $$;
