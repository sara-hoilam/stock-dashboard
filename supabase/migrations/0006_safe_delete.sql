-- Alpha Ticker — satisfy Supabase's safe-delete guard
--
-- Apply after 0005. Safe to re-run.
--
-- Supabase rejects an unqualified DELETE ("DELETE requires a WHERE clause"),
-- which is a good default: it turns a forgotten predicate from a table wipe
-- into an error. `replace_sectors` genuinely does replace the whole table, so
-- it states that explicitly rather than relying on omission.

create or replace function public.replace_sectors(p_rows jsonb, p_as_of date)
returns integer
language plpgsql volatile security definer
set search_path = ledger, pg_temp
as $$
declare n integer;
begin
  -- The snapshot is a complete picture of one trading day, so the previous
  -- day's rows are replaced wholesale rather than merged.
  delete from ledger.sector_perf where sector is not null;

  insert into ledger.sector_perf (sector, change_pct, as_of, updated_at)
  select r->>'sector', (r->>'change_pct')::double precision, p_as_of, now()
  from jsonb_array_elements(p_rows) r
  where r->>'sector' is not null;
  get diagnostics n = row_count;
  return n;
end;
$$;

revoke all on function public.replace_sectors(jsonb, date) from public, anon, authenticated;
grant execute on function public.replace_sectors(jsonb, date) to service_role;
