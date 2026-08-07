-- Ticker Alpha — sector on index holdings + coalesce industry for the pie
--
-- Apply after 0049. Safe to re-run.
--
-- Slickcharts supplies weights but not industry. When the worker enrichment
-- missed a name (or an older refresh wrote nulls), the industry pie collapsed
-- to a single "Other / unlisted" slice — and a 100% SVG arc draws nothing.
-- Coalesce industry/sector from ledger.price_daily (company extras) so the
-- chart still has real buckets, and return sector for a clearer breakdown.

alter table ledger.index_holding
  add column if not exists sector text;

create or replace function public.replace_index_holdings(
  p_index text, p_rows jsonb)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare
  n integer := 0;
  idx text := upper(trim(coalesce(p_index, '')));
begin
  if idx = '' or p_rows is null or jsonb_typeof(p_rows) <> 'array' then
    return 0;
  end if;
  delete from ledger.index_holding where index_symbol = idx;
  insert into ledger.index_holding
    (index_symbol, symbol, name, industry, sector, weight_pct, rank, updated_at)
  select idx,
         upper(trim(r->>'symbol')),
         nullif(trim(r->>'name'), ''),
         nullif(trim(r->>'industry'), ''),
         nullif(trim(r->>'sector'), ''),
         nullif(r->>'weightPct', '')::double precision,
         coalesce(nullif(r->>'rank', '')::integer, 0),
         now()
  from jsonb_array_elements(p_rows) r
  where nullif(trim(r->>'symbol'), '') is not null;
  get diagnostics n = row_count;
  return n;
end;
$$;

create or replace function public.get_index_holdings(p_symbol text)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with wanted as (
    select h.symbol,
           h.name,
           coalesce(nullif(trim(h.industry), ''), nullif(trim(p.industry), '')) as industry,
           coalesce(nullif(trim(h.sector), ''), nullif(trim(p.sector), '')) as sector,
           h.weight_pct,
           h.rank
      from ledger.index_holding h
      left join ledger.price_daily p on p.symbol = h.symbol
     where h.index_symbol = upper(trim(coalesce(p_symbol, '')))
  ),
  ytd_year as (
    select to_char(date_trunc('year', current_date), 'YYYY-MM-DD') as start_d
  ),
  priced as (
    select w.symbol,
           w.name,
           w.industry,
           w.sector,
           w.weight_pct,
           w.rank,
           q.change_pct,
           d.bars
      from wanted w
      left join ledger.quote q on q.symbol = w.symbol
      left join ledger.price_daily d on d.symbol = w.symbol
  ),
  with_ytd as (
    select p.symbol,
           p.name,
           p.industry,
           p.sector,
           p.weight_pct,
           p.rank,
           p.change_pct,
           case
             when p.bars is null or jsonb_typeof(p.bars) <> 'array' then null
             else (
               select case
                 when min_c.c is null or min_c.c = 0 or last_c.c is null then null
                 else round((((last_c.c / min_c.c) - 1.0) * 100.0)::numeric, 4)
               end
               from lateral (
                 select nullif(e->>'c', '')::double precision as c
                   from jsonb_array_elements(p.bars) e, ytd_year y
                  where (e->>'d') >= y.start_d
                    and nullif(e->>'c', '') is not null
                  order by e->>'d'
                  limit 1
               ) min_c
               left join lateral (
                 select nullif(e->>'c', '')::double precision as c
                   from jsonb_array_elements(p.bars) e, ytd_year y
                  where (e->>'d') >= y.start_d
                    and nullif(e->>'c', '') is not null
                  order by e->>'d' desc
                  limit 1
               ) last_c on true
             )
           end as ytd_pct
      from priced p
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', r.symbol,
           'name', r.name,
           'industry', r.industry,
           'sector', r.sector,
           'weightPct', r.weight_pct,
           'rank', r.rank,
           'changePct', r.change_pct,
           'ytdPct', r.ytd_pct)
           order by r.rank nulls last, r.weight_pct desc nulls last, r.symbol),
         '[]'::jsonb)
  from with_ytd r;
$$;

do $$
begin
  execute 'revoke all on function public.replace_index_holdings(text, jsonb) from public, anon, authenticated';
  execute 'grant execute on function public.replace_index_holdings(text, jsonb) to service_role';
  execute 'revoke all on function public.get_index_holdings(text) from public';
  execute 'grant execute on function public.get_index_holdings(text) to anon, authenticated';
end $$;
