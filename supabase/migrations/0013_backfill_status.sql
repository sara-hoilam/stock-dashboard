-- Ticker Alpha — let the page read why a company could not be ingested
--
-- Apply after 0012. Safe to re-run.
--
-- The page asked for a company, polled for quarters, and on finding none said
-- it was "still being read from SEC EDGAR". For a company that will never have
-- quarterly US filings -- AstraZeneca reports under IFRS and files 20-F, not
-- 10-Q -- that message is untrue, and invites the reader to wait for something
-- that is not coming.
--
-- The worker already records the failure in backfill_request.error; it simply
-- had no way to say so. Status is derived from the timestamps rather than
-- stored, because the timestamps are what the queue actually runs on.

create or replace function public.get_backfill_status(p_ticker text)
returns jsonb
language sql stable security definer
set search_path = ledger, pg_temp
as $$
  select coalesce(
    (select jsonb_build_object(
       'status', case
                   when r.done_at is null and r.claimed_at is null then 'queued'
                   when r.done_at is null then 'running'
                   when r.error is not null then 'failed'
                   else 'done'
                 end,
       'error', r.error,
       'requestedAt', r.requested_at,
       'doneAt', r.done_at)
     from ledger.backfill_request r
     where r.ticker = upper(p_ticker)
     order by r.requested_at desc
     limit 1),
    jsonb_build_object('status', 'unknown'));
$$;

do $$
begin
  execute 'revoke all on function public.get_backfill_status(text) from public';
  execute 'grant execute on function public.get_backfill_status(text) to anon, authenticated';
end $$;
