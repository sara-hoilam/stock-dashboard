-- Ledger — post-migration verification
--
-- Run in the SQL editor of the ledger project (NOT Minion AI) after applying
-- 0001_ledger_init.sql. Every row must say PASS.
--
-- What it proves: the data is unreachable from the browser, and the only
-- public surface is the four functions we intended.

with checks as (

  select 1 as ord, 'tables created in ledger schema' as check,
         count(*)::text as got, '5' as want
  from pg_tables where schemaname = 'ledger'

  union all
  select 2, 'RLS enabled on every ledger table',
         count(*) filter (where c.relrowsecurity)::text, count(*)::text
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'ledger' and c.relkind = 'r'

  union all
  select 3, 'the four public API functions exist',
         count(*)::text, '4'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('search_companies','get_company','get_segments','request_backfill')

  union all
  select 4, 'all four are SECURITY DEFINER',
         count(*) filter (where p.prosecdef)::text, '4'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('search_companies','get_company','get_segments','request_backfill')

  union all
  select 5, 'all four pin search_path',
         count(*) filter (
           where array_to_string(p.proconfig, ',') like '%search_path%')::text, '4'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('search_companies','get_company','get_segments','request_backfill')

  union all
  select 6, 'anon can execute all four',
         count(*)::text, '4'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname in ('search_companies','get_company','get_segments','request_backfill')
    and has_function_privilege('anon', p.oid, 'execute')

  union all
  select 7, 'anon has NO usage on the ledger schema',
         case when has_schema_privilege('anon', 'ledger', 'usage')
              then 'yes' else 'no' end, 'no'

  union all
  select 8, 'anon can read no ledger table directly',
         count(*)::text, '0'
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'ledger' and c.relkind = 'r'
    and has_table_privilege('anon', c.oid, 'select')

  union all
  select 9, 'anon can execute nothing else in public',
         count(*)::text, '0'
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and p.proname not in ('search_companies','get_company','get_segments','request_backfill')
    and has_function_privilege('anon', p.oid, 'execute')
)
select check, got, want,
       case when got = want then 'PASS' else 'FAIL' end as result
from checks
order by ord;

-- Smoke test: should return [] rather than an error, proving the RPC is
-- reachable and the empty database answers cleanly.
select public.search_companies('AAPL') as search_on_empty_db;
