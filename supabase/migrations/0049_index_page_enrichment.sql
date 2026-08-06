-- Ticker Alpha — index page enrichment (returns on holdings + PE series RPC)
--
-- Apply after 0048_market_indexes.sql. Safe to re-run.
--
-- 1) get_index_holdings also returns today's change% (from ledger.quote) and
--    YTD % (from ledger.price_daily bars when present).
-- 2) get_index_pe_history returns cached forward/trailing PE series for the
--    comparison chart (written onto price_daily.pe_history by the worker).

create or replace function public.get_index_holdings(p_symbol text)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  with wanted as (
    select h.symbol, h.name, h.industry, h.weight_pct, h.rank
      from ledger.index_holding h
     where h.index_symbol = upper(trim(coalesce(p_symbol, '')))
  ),
  ytd_year as (
    select to_char(date_trunc('year', current_date), 'YYYY-MM-DD') as start_d
  ),
  priced as (
    select w.symbol,
           w.name,
           w.industry,
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
           p.weight_pct,
           p.rank,
           p.change_pct,
           case
             when p.bars is null or jsonb_typeof(p.bars) <> 'array' then null
             else (
               select case
                 when min_c.c is null or min_c.c = 0 or last_c.c is null then null
                 else round(((last_c.c / min_c.c) - 1.0) * 100.0, 4)
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
           'weightPct', r.weight_pct,
           'rank', r.rank,
           'changePct', r.change_pct,
           'ytdPct', r.ytd_pct)
           order by r.rank nulls last, r.weight_pct desc nulls last, r.symbol),
         '[]'::jsonb)
  from with_ytd r;
$$;

-- Multi-index PE series for the index page comparison chart.
-- Expects pe_history on price_daily for SPX / IXIC / DJI (and optional RUT),
-- shaped as [{d, pe}, …] — same as company extras.
create or replace function public.get_index_pe_history()
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
           'symbol', d.symbol,
           'name', coalesce(q.name, d.symbol),
           'points', coalesce(d.pe_history, '[]'::jsonb))
           order by array_position(array['SPX','IXIC','DJI','RUT'], d.symbol)),
         '[]'::jsonb)
  from ledger.price_daily d
  left join ledger.quote q on q.symbol = d.symbol
  where d.symbol in ('SPX', 'IXIC', 'DJI', 'RUT')
    and d.pe_history is not null
    and jsonb_typeof(d.pe_history) = 'array'
    and jsonb_array_length(d.pe_history) > 0;
$$;

do $$
begin
  execute 'revoke all on function public.get_index_holdings(text) from public';
  execute 'grant execute on function public.get_index_holdings(text) to anon, authenticated';
  execute 'revoke all on function public.get_index_pe_history() from public';
  execute 'grant execute on function public.get_index_pe_history() to anon, authenticated';
end $$;
