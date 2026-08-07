-- Ticker Alpha — one dividend credit per ex-date, enforced by the database
--
-- Apply after 0054. Safe to re-run.
--
-- syncDividends() credits an ex-date by writing a `dividend` transaction whose
-- note is `ex:YYYY-MM-DD`, and avoids doubling up by checking the notes it can
-- already see. That check is only as good as the client's picture of the rows,
-- and the client's picture was stale: the page runs the sync twice on load and
-- writes with reload:false, so the second run rebuilt its list from
-- transactions that did not yet include the first run's writes. Two page loads
-- therefore credited the same ex-date four times -- AZN's $1.06 on 8 shares
-- showed as $33.92 instead of $8.48.
--
-- The client is fixed too, but a money figure should not depend on a client
-- getting its bookkeeping right. This makes the duplicate impossible to store.

-- ---------------------------------------------------------------------------
-- Clean up what the old code wrote, keeping the earliest of each group
-- ---------------------------------------------------------------------------
delete from public.portfolio_transaction t
 where t.kind = 'dividend'
   and t.note is not null
   and t.id > (
     select min(u.id) from public.portfolio_transaction u
      where u.portfolio_id = t.portfolio_id
        and u.symbol = t.symbol
        and u.kind = 'dividend'
        and u.note = t.note);

-- ---------------------------------------------------------------------------
-- And stop it happening again
-- ---------------------------------------------------------------------------
-- Partial, because only dividend rows carry an ex-date note. Buys and sells of
-- the same symbol on the same day are perfectly ordinary and must stay legal.
create unique index if not exists portfolio_dividend_once_idx
  on public.portfolio_transaction (portfolio_id, symbol, note)
  where kind = 'dividend' and note is not null;

-- The writer is left alone deliberately. add_portfolio_transaction will now
-- raise on a duplicate, and syncDividends already wraps each credit in its own
-- try/catch and logs a warning -- so the guard refuses the bad row without
-- taking the page down. The client is fixed separately so it stops asking.
