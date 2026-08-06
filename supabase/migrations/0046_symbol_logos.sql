-- Ticker Alpha — cached company / crypto logos (Logo.dev)
--
-- Apply after 0045. Safe to re-run.
--
-- The worker fetches logos once (S&P 500 + top crypto by market cap) and
-- stores the image bytes so the browser does not re-hit Logo.dev on every
-- page load. Clients read via get_symbol_logos; missing rows keep using
-- initials in the UI.

create table if not exists ledger.symbol_logo (
  symbol      text primary key,
  kind        text not null default 'stock'
                check (kind in ('stock', 'crypto')),
  logo_url    text,
  image_mime  text,
  image_b64   text,
  status      text not null default 'missing'
                check (status in ('ok', 'missing', 'error')),
  checked_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);
create index if not exists symbol_logo_status_idx
  on ledger.symbol_logo (status);
create index if not exists symbol_logo_kind_status_idx
  on ledger.symbol_logo (kind, status);

alter table ledger.symbol_logo enable row level security;

create or replace function public.upsert_symbol_logos(p_rows jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer := 0;
begin
  if p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    return 0;
  end if;

  insert into ledger.symbol_logo
    (symbol, kind, logo_url, image_mime, image_b64, status, checked_at, updated_at)
  select upper(trim(r->>'symbol')),
         case when lower(coalesce(r->>'kind', 'stock')) = 'crypto'
              then 'crypto' else 'stock' end,
         nullif(r->>'logoUrl', ''),
         nullif(r->>'imageMime', ''),
         nullif(r->>'imageB64', ''),
         coalesce(nullif(r->>'status', ''), 'missing'),
         now(),
         now()
  from jsonb_array_elements(p_rows) r
  where nullif(upper(trim(r->>'symbol')), '') is not null
    and upper(trim(r->>'symbol')) ~ '^[A-Z0-9][A-Z0-9.\-]{0,14}$'
  on conflict (symbol) do update set
    kind = excluded.kind,
    logo_url = excluded.logo_url,
    image_mime = excluded.image_mime,
    image_b64 = excluded.image_b64,
    status = excluded.status,
    checked_at = now(),
    updated_at = now();

  get diagnostics n = row_count;
  return n;
end;
$$;

-- Batch read for the UI. Returns data URLs when we have cached bytes.
create or replace function public.get_symbol_logos(p_symbols text[] default null)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with wanted as (
    select upper(trim(s)) as symbol
    from unnest(coalesce(p_symbols, array[]::text[])) s
    where upper(trim(s)) ~ '^[A-Z0-9][A-Z0-9.\-]{0,14}$'
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', l.symbol,
           'kind', l.kind,
           'status', l.status,
           'logoUrl', l.logo_url,
           'dataUrl', case
             when l.status = 'ok'
              and l.image_b64 is not null
              and l.image_mime is not null
             then 'data:' || l.image_mime || ';base64,' || l.image_b64
             else null
           end)
         order by l.symbol), '[]'::jsonb)
  from ledger.symbol_logo l
  where l.symbol in (select symbol from wanted);
$$;

-- Given a preferred target list (S&P 500 + top crypto from the worker),
-- return those that still need a Logo.dev fetch. Keeps free-plan usage
-- focused: we never auto-expand to the full ticker directory.
create or replace function public.logos_due(p_targets jsonb, p_limit integer default 40)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with targets as (
    select upper(trim(r->>'symbol')) as symbol,
           case when lower(coalesce(r->>'kind', 'stock')) = 'crypto'
                then 'crypto' else 'stock' end as kind,
           ord
    from jsonb_array_elements(coalesce(p_targets, '[]'::jsonb))
         with ordinality as t(r, ord)
    where nullif(upper(trim(r->>'symbol')), '') is not null
      and upper(trim(r->>'symbol')) ~ '^[A-Z0-9][A-Z0-9.\-]{0,14}$'
  ),
  uniq as (
    select distinct on (symbol) symbol, kind, ord
    from targets
    order by symbol, ord
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', u.symbol, 'kind', u.kind)
         order by u.ord), '[]'::jsonb)
  from (
    select u.symbol, u.kind, u.ord
    from uniq u
    left join ledger.symbol_logo l on l.symbol = u.symbol
    where l.symbol is null
       or l.checked_at < now() - interval '30 days'
       or (l.status = 'error' and l.checked_at < now() - interval '7 days')
    order by case when l.symbol is null then 0 else 1 end, u.ord
    limit greatest(1, least(coalesce(p_limit, 40), 200))
  ) u;
$$;

do $$
begin
  execute 'revoke all on function public.upsert_symbol_logos(jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.upsert_symbol_logos(jsonb) to service_role';

  execute 'revoke all on function public.get_symbol_logos(text[]) from public';
  execute 'grant execute on function public.get_symbol_logos(text[]) to anon, authenticated';

  execute 'revoke all on function public.logos_due(jsonb, integer) from public, anon, authenticated';
  execute 'grant execute on function public.logos_due(jsonb, integer) to service_role';
end $$;
