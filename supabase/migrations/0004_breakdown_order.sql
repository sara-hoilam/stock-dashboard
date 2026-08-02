-- Ledger — order the revenue breakdowns the way the local tool does
--
-- Apply after 0003. Safe to re-run.
--
-- The rows come back from Postgres unordered, which put "By geography" ahead
-- of "By segment" and made geography the default view. Business segments are
-- the more informative cut, and the local tool ranks them first, so the
-- hosted read should agree.

create or replace function public.get_segments(p_ticker text, p_end date)
returns jsonb
language sql
stable
security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(
    jsonb_agg(jsonb_build_object(
      'name', s.name, 'source', s.source, 'basis', s.basis, 'rows', s.rows)
      order by s.rank, s.name),
    '[]'::jsonb)
  from (
    select b.name, b.source, b.basis, b.rows,
           case
             when b.name ilike '%segment%'   then 0
             when b.name ilike '%product%'
               or b.name ilike '%service%'   then 1
             when b.name ilike '%geograph%'  then 3
             else 2
           end as rank
    from ledger.breakdown b
    where b.cik = (select t.cik from ledger.ticker t where t.ticker = upper(p_ticker))
      and b.period_end = p_end
  ) s;
$$;

revoke all on function public.get_segments(text, date) from public;
grant execute on function public.get_segments(text, date) to anon, authenticated;
