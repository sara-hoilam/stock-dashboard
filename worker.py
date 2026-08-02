"""
worker.py -- the only process allowed to talk to the SEC.

    python worker.py sync-directory     refresh the ticker list
    python worker.py seed [N]           ingest the largest N companies
    python worker.py ingest TICKER ...  ingest specific companies
    python worker.py backfill           drain the request queue once
    python worker.py sweep [YYYY-MM-DD] ingest that day's new 10-Q/10-K
    python worker.py stats              coverage summary
    python worker.py run                the long-running loop (this is what
                                        Render runs)

Why one process: the SEC's rate limit is per IP, so the whole service shares a
single budget. `edgar.py` already serialises and paces its own requests, and
keeping every SEC call inside this one program is what makes that limit hold.
Do not run two copies against the same deployment.
"""

from __future__ import annotations

import datetime as dt
import os
import re
import sys
import time
import traceback

import envload  # noqa: F401  -- must precede edgar/store

import edgar
import store

POLL = int(os.environ.get("BACKFILL_POLL_SECONDS", "20"))
RECHECK_HOURS = int(os.environ.get("COMPANY_RECHECK_HOURS", "6"))


def log(msg: str) -> None:
    print(f"{dt.datetime.now():%H:%M:%S} {msg}", flush=True)


# ---------------------------------------------------------------------------
# Ticker directory
# ---------------------------------------------------------------------------

def sync_directory() -> int:
    rows = edgar.ticker_directory()
    n = store.upsert_directory(rows)
    log(f"directory: {len(rows):,} tickers upserted ({n:,} rows written)")
    return len(rows)


# ---------------------------------------------------------------------------
# Ingesting one company
# ---------------------------------------------------------------------------

def ingest(ticker: str, quarters: int = 24) -> dict:
    """Build a company from SEC filings and write it to Supabase.

    Breakdowns are fetched for the most recent quarters only. Older ones are
    filled in on demand -- each costs several requests to the filing's own
    tables, and almost nobody scrolls back four years.
    """
    started = time.time()
    company = edgar.build_company(ticker, max_quarters=quarters)

    breakdowns: list[dict] = []
    for q in company["quarters"][:8]:
        try:
            for cut in edgar.attach_segments(company, q["end"]):
                breakdowns.append({
                    "period_end": q["end"], "name": cut["name"],
                    "source": cut.get("source"), "basis": cut.get("basis"),
                    "rows": cut["rows"],
                })
        except Exception as exc:
            # A breakdown that will not parse is not a reason to lose the
            # income statement. Record it and move on.
            log(f"  {ticker} {q['label']}: breakdown failed ({exc})")

    written = store.ingest_company(company, breakdowns)
    log(f"{ticker:<6} {written['quarters']:>2} quarters, "
        f"{written['breakdowns']:>2} breakdowns, {time.time()-started:.1f}s")
    return written


def ingest_safely(ticker: str) -> str | None:
    """Returns an error string, or None on success."""
    try:
        ingest(ticker)
        return None
    except edgar.FetchError as exc:
        return str(exc)
    except store.StoreError:
        raise                      # configuration problems should stop the run
    except Exception as exc:
        traceback.print_exc()
        return f"{type(exc).__name__}: {exc}"


# ---------------------------------------------------------------------------
# Seeding
# ---------------------------------------------------------------------------

def seed(limit: int = 500) -> None:
    """Ingest a starting universe so the site is useful on day one.

    Ordered by CIK as a rough proxy for "long-listed and therefore likely to
    be searched"; anything missed arrives through the backfill queue.
    """
    rows = edgar.ticker_directory()
    seen, universe = set(), []
    for r in sorted(rows, key=lambda r: r["cik"]):
        if r["ticker"] in seen:
            continue
        seen.add(r["ticker"])
        universe.append(r["ticker"])
        if len(universe) >= limit:
            break

    log(f"seeding {len(universe)} companies")
    ok = failed = 0
    for i, t in enumerate(universe, 1):
        err = ingest_safely(t)
        if err:
            failed += 1
            log(f"  [{i}/{len(universe)}] {t}: {err[:90]}")
        else:
            ok += 1
        if i % 25 == 0:
            log(f"  progress {i}/{len(universe)} — {ok} ok, {failed} failed")
    log(f"seed complete: {ok} ok, {failed} failed")


# ---------------------------------------------------------------------------
# Backfill queue
# ---------------------------------------------------------------------------

def drain_backfill(max_items: int = 25) -> int:
    done = 0
    while done < max_items:
        job = store.claim_backfill()
        if not job:
            break
        err = ingest_safely(job["ticker"])
        store.finish_backfill(job["id"], err)
        if err:
            log(f"backfill {job['ticker']}: {err[:90]}")
        done += 1
    return done


# ---------------------------------------------------------------------------
# Daily index sweep
# ---------------------------------------------------------------------------

_IDX_FORMS = ("10-Q", "10-K", "20-F", "40-F")


def sweep(day: dt.date | None = None) -> int:
    """Ingest companies that filed a periodic report on `day`.

    The daily index is the SEC's own complete record of what was disseminated,
    so this is the mechanism that keeps the database ahead of visitors rather
    than behind them.
    """
    day = day or dt.date.today()
    qtr = (day.month - 1) // 3 + 1
    url = (f"https://www.sec.gov/Archives/edgar/daily-index/"
           f"{day.year}/QTR{qtr}/form.{day:%Y%m%d}.idx")
    try:
        raw = edgar.fetch(url, ttl=6 * 3600)
    except edgar.FetchError as exc:
        log(f"sweep {day}: no index ({exc})")
        return 0

    lines = raw.splitlines()
    try:
        start = next(i for i, l in enumerate(lines) if l.startswith("---")) + 1
    except StopIteration:
        return 0

    ciks: dict[int, str] = {}
    for line in lines[start:]:
        form = line[:12].strip()
        if form not in _IDX_FORMS:
            continue
        m = re.search(r"edgar/data/(\d+)/([\d-]+)\.txt", line)
        if not m:
            continue
        ciks.setdefault(int(m.group(1)), m.group(2))

    if not ciks:
        log(f"sweep {day}: no periodic filings")
        return 0

    # Only companies we already track. New listings arrive on demand.
    directory = {r["cik"]: r["ticker"] for r in edgar.ticker_directory()}
    todo = [(cik, directory[cik], acc) for cik, acc in ciks.items() if cik in directory]
    log(f"sweep {day}: {len(ciks)} periodic filings, {len(todo)} with tickers")

    done = 0
    for cik, ticker, accession in todo:
        if store.filing_seen(accession):
            continue
        err = ingest_safely(ticker)
        if err:
            store.record_failure(accession, cik, "10-Q/K", day.isoformat(), None, err)
        done += 1
    log(f"sweep {day}: {done} companies refreshed")
    return done


# ---------------------------------------------------------------------------
# Scheduled refresh of companies we already hold
# ---------------------------------------------------------------------------

def refresh_stale(limit: int = 20) -> int:
    due = store.companies_due(RECHECK_HOURS, limit)
    for c in due:
        ingest_safely(c["ticker"])
    if due:
        log(f"refreshed {len(due)} stale companies")
    return len(due)


# ---------------------------------------------------------------------------
# The loop Render runs
# ---------------------------------------------------------------------------

def run() -> None:
    log("worker up — the only process talking to the SEC")
    last_directory = 0.0
    last_sweep_day: dt.date | None = None

    while True:
        try:
            now = time.time()

            if now - last_directory > 24 * 3600:
                sync_directory()
                last_directory = now

            # Visitors first: a queued company should appear within a minute.
            if drain_backfill():
                continue

            today = dt.date.today()
            if last_sweep_day != today and dt.datetime.now().hour >= 22:
                sweep(today)
                last_sweep_day = today

            refresh_stale(5)

        except store.StoreError as exc:
            log(f"store error, stopping: {exc}")
            raise
        except Exception as exc:
            log(f"loop error (continuing): {type(exc).__name__}: {exc}")
            traceback.print_exc()

        time.sleep(POLL)


# ---------------------------------------------------------------------------

def main(argv: list[str]) -> int:
    cmd = argv[0] if argv else "run"

    if cmd != "stats":
        log(f"SEC contact: {edgar.CONTACT}")
        if edgar.CONTACT == "dashboard-user@example.com":
            log("  warning: set SEC_CONTACT to a real address")

    if cmd == "sync-directory":
        sync_directory()
    elif cmd == "seed":
        seed(int(argv[1]) if len(argv) > 1 else 500)
    elif cmd == "ingest":
        if len(argv) < 2:
            print("usage: python worker.py ingest TICKER [TICKER ...]")
            return 2
        for t in argv[1:]:
            err = ingest_safely(t)
            if err:
                log(f"{t}: {err}")
    elif cmd == "backfill":
        log(f"drained {drain_backfill()} request(s)")
    elif cmd == "sweep":
        sweep(dt.date.fromisoformat(argv[1]) if len(argv) > 1 else None)
    elif cmd == "stats":
        for k, v in (store.stats() or {}).items():
            print(f"  {k:<24} {v}")
    elif cmd == "run":
        run()
    else:
        print(__doc__)
        return 2
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except store.StoreError as exc:
        print(f"\nconfiguration problem:\n  {exc}\n", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.exit(130)
