"""
worker.py -- the only process allowed to talk to the SEC.

    python worker.py sync-directory     refresh the ticker list
    python worker.py seed [N]           ingest the largest N companies
    python worker.py ingest TICKER ...  ingest specific companies
    python worker.py backfill           drain the request queue once
    python worker.py sweep [YYYY-MM-DD] ingest that day's new 10-Q/10-K
    python worker.py market             refresh prices, movers and sectors
    python worker.py sections           refresh heatmap, rotation and trades
    python worker.py news               refresh market news
    python worker.py prices [TICKER...] fill price requests, or named symbols
    python worker.py analyst [TICKER...] fill coverage requests, or named symbols
    python worker.py intraday TICKER    refresh one chart series
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
import market
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
        else:
            # A company being read for the first time is one whose report is
            # about to be opened, so fetch its prices in the same pass rather
            # than making the visitor wait for a second round trip.
            fetch_prices(job["ticker"])
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
# Market data (FMP)
# ---------------------------------------------------------------------------

# The watchlist behind Market Summary. Broad-market ETFs first so the page
# always has an index to call the day's leader.
WATCHLIST = os.environ.get("WATCHLIST", "").split(",") if os.environ.get("WATCHLIST") else [
    "SPY", "QQQ", "IWM", "DIA",
    "AAPL", "MSFT", "NVDA", "AMZN", "GOOGL", "META", "TSLA", "AMD",
    "AVGO", "JPM", "UBER", "COIN", "MU", "NFLX",
]

# How many followed companies get a chart series on every market pass. One
# FMP request each, so this is the cost of the feature: at the default
# fifteen-minute cadence, forty names is 160 requests an hour. Raise it when
# the plan allows; anything past the cap still gets a series the moment
# someone opens it, through the request queue.
FOLLOWED_CHARTS = int(os.environ.get("FOLLOWED_CHART_LIMIT", "40"))


def refresh_market() -> bool:
    """Pull the day's market picture into Supabase.

    Runs on a timer, not on a visitor's request, because the FMP key is a paid
    secret that must never reach a browser.
    """
    if not market.configured():
        return False
    started = time.time()

    sectors, as_of = market.sectors()
    if sectors:
        store.replace_sectors(sectors, as_of)

    store_movers: dict[str, list[dict]] = {}
    for kind, fetch in (("gainer", market.gainers),
                        ("loser", market.losers),
                        ("active", market.actives)):
        try:
            rows = fetch(25)
            store_movers[kind] = rows
            store.replace_movers(kind, rows, as_of)
        except market.MarketError as exc:
            log(f"  movers {kind}: {exc}")

    # Chart series for the watchlist and for the top few movers, so every
    # view of the summary list has something to draw when it is opened --
    # and for what people actually follow, which is the only part of this
    # list that is not known in advance.
    followed: list[str] = []
    try:
        followed = store.watchlisted_symbols(FOLLOWED_CHARTS)
    except store.StoreError as exc:
        # 0020 not applied yet. Followed companies still get a series from the
        # request queue when someone opens one; they just are not pre-fetched.
        log(f"  followed symbols unavailable (apply 0020_intraday_requests.sql): {exc}")

    pending: list[str] = []
    try:
        pending = store.pending_prices(FOLLOWED_CHARTS)
    except store.StoreError as exc:
        log(f"  pending prices unavailable: {exc}")

    # Quotes feed the watchlist price column and the tape. The hardcoded
    # WATCHLIST alone left followed names (AZN, HOOD, …) with a chart but
    # "—" for the price, so anything people follow or have asked about is
    # quoted here too.
    quote_syms = list(dict.fromkeys(WATCHLIST + followed + pending))
    quotes = market.quotes(quote_syms)
    if quotes:
        store.upsert_quotes(quotes)

    chart_syms = list(dict.fromkeys(
        WATCHLIST
        + [r["symbol"] for r in (store_movers.get("gainer") or [])[:6]]
        + [r["symbol"] for r in (store_movers.get("loser") or [])[:6]]
        + followed))
    for sym in chart_syms:
        try:
            pts = market.intraday(sym, days=2)
            if pts:
                store.upsert_intraday(sym, pts, pts[-1]["t"][:10])
        except market.MarketError:
            continue

    # Fear & Greed is not an FMP field — see market.fear_greed.
    try:
        fg = market.fear_greed()
        store.upsert_sentiment("fear_greed", fg["score"], fg.get("rating"),
                               fg.get("previous"), fg.get("source"))
        log(f"  fear&greed: {fg['score']:.0f} ({fg.get('rating')}) "
            f"via {fg.get('source')}"
            + (f" — {fg['note']}" if fg.get("note") else ""))
    except (market.MarketError, store.StoreError) as exc:
        log(f"  fear&greed: {exc}")

    log(f"market: {len(sectors)} sectors, {len(quotes)} quotes, "
        f"{len(chart_syms)} charts, as of {as_of}, {time.time()-started:.1f}s")
    return True


def refresh_news() -> bool:
    """Latest market news, on the same cadence as prices.

    Two requests for the whole page, so it can run often without costing much.
    """
    if not market.configured():
        return False
    rows, keywords = market.news(120)
    if not rows:
        return False
    n = store.upsert_news(rows, keywords)
    log(f"news: {len(rows)} articles ({n} written), {len(keywords)} keywords")
    return True


def fetch_prices(symbol: str) -> bool:
    """Daily bars and a quote for one company. Two FMP requests."""
    if not market.configured():
        return False
    sym = symbol.upper()
    try:
        bars = market.daily(sym, 300)
        q = market.quote_detail(sym)
    except market.MarketError as exc:
        log(f"  prices {sym}: {exc}")
        # Mark it finished anyway, or the queue spins on a bad symbol.
        store.upsert_prices(sym, [], None, None)
        return False
    store.upsert_prices(sym, bars, q, bars[-1]["d"] if bars else None)

    # Keep the summary quote in sync too. fetch_prices writes quote_detail for
    # the company page; without this, a watchlisted symbol that was never on
    # the hardcoded WATCHLIST still shows "—" on Markets Today.
    if q and q.get("price") is not None:
        try:
            store.upsert_quotes([{
                "symbol": q.get("symbol") or sym,
                "name": q.get("name"),
                "price": q.get("price"),
                "change": q.get("change"),
                "change_pct": q.get("change_pct"),
                "volume": q.get("volume"),
                "market_cap": q.get("market_cap"),
                "exchange": q.get("exchange"),
            }])
        except store.StoreError as exc:
            log(f"  quote {sym}: {exc}")

    # The report also plots this company against its sector and over ten years
    # of months. Both come off the same visit, so they are fetched here rather
    # than through a second queue.
    extras = ""
    try:
        prof = market.profile(sym) or {}
        monthly = market.monthly_closes(sym, 11)
        pe_hist: list[dict] = []
        try:
            pe_hist = market.pe_history(sym)
        except market.MarketError as exc:
            log(f"  pe history {sym}: {exc}")
        try:
            store.upsert_company_extras(sym, monthly, prof.get("sector"),
                                        prof.get("industry"), pe_hist or None)
        except store.StoreError:
            # 0021 not applied yet — write the rest without the PE series.
            store.upsert_company_extras(sym, monthly, prof.get("sector"),
                                        prof.get("industry"))
        extras = f", {len(monthly)} months, {prof.get('sector') or 'no sector'}"
        if pe_hist:
            extras += f", {len(pe_hist)} pe"
        etf = market.SECTOR_ETF.get(prof.get("sector") or "")
        if etf:
            fetch_benchmark(etf)
    except market.MarketError as exc:
        log(f"  extras {sym}: {exc}")
    except store.StoreError as exc:
        log(f"  extras {sym}: {exc}")

    # Analyst coverage rides along with the same visit.
    if fetch_analyst(sym):
        extras += ", analysts"

    log(f"prices {sym}: {len(bars)} bars{', quote' if q else ', no quote'}{extras}")
    return True


def fetch_analyst(symbol: str) -> bool:
    """Targets, the rating tally and recent house actions for one company.

    Written even when FMP returns nothing, because "no house covers this
    company" is an answer the report can show, and an absent row is
    indistinguishable from one that has not been fetched yet. Fields that came
    back empty keep whatever they held, so a single failing endpoint cannot
    blank a section that was complete a minute ago.
    """
    if not market.configured():
        return False
    sym = symbol.upper()
    try:
        view = market.analyst_view(sym)
    except market.MarketError as exc:
        log(f"  analyst {sym}: {exc}")
        return False
    store.upsert_analyst(sym, view)
    c = view.get("consensus") or {}
    log(f"analyst {sym}: {c.get('rating') or 'no consensus'}, "
        f"{len(view.get('grades') or [])} houses, "
        f"{len(view.get('news') or [])} stories")
    return True


# One series per sector rather than per company, refreshed at most daily.
_benchmark_seen: dict[str, float] = {}


def fetch_benchmark(etf: str, ttl: int = 20 * 3600) -> bool:
    """The sector SPDR a company is plotted against."""
    if time.time() - _benchmark_seen.get(etf, 0) < ttl:
        return False
    rows = market.closes(etf, 11)
    if not rows:
        return False
    store.upsert_benchmark(etf, rows)
    _benchmark_seen[etf] = time.time()
    log(f"benchmark {etf}: {len(rows)} closes")
    return True


def refresh_industry_pe() -> bool:
    """Price/earnings by industry and sector, for the whole market at once."""
    if not market.configured():
        return False
    rows, as_of = market.industry_pe()
    if not rows:
        return False
    n = store.replace_industry_pe(rows, as_of)
    log(f"industry PE: {n} rows as of {as_of}")
    return True


def drain_prices(max_items: int = 5) -> int:
    """Fetch prices for the companies whose report pages have been opened.

    Markets Today tracks a fixed sixty-odd names and can be pre-fetched. The
    company report can be opened for any listed company, so prices are pulled
    on demand -- the same shape as the filings backfill, and for the same
    reason. Two requests per company: the daily bars and the quote.
    """
    if not market.configured():
        return 0
    done = 0
    for sym in store.pending_prices(max_items):
        if fetch_prices(sym):
            done += 1
    return done


def drain_analyst(max_items: int = 5) -> int:
    """Fetch coverage for the companies whose report pages have asked for it.

    Coverage used to be a passenger on the price fetch, which only runs when
    the page finds prices missing or half a day old -- so a company with fresh
    prices never got any, and its report sat on a spinner forever. It has its
    own queue now, drained the same way prices are.
    """
    if not market.configured():
        return 0
    try:
        pending = store.pending_analyst(max_items)
    except store.StoreError as exc:
        # 0017 not applied yet. Coverage still arrives with the price fetch,
        # so this degrades rather than taking the loop down with it.
        log(f"  analyst queue unavailable (apply 0017_analyst_requests.sql): {exc}")
        return 0
    return sum(1 for sym in pending if fetch_analyst(sym))


def refresh_sections() -> bool:
    """Heatmap, sector rotation, insider and congressional trades.

    Slower and less time-critical than prices, so it runs on its own cadence:
    the treemap costs one request per constituent.
    """
    if not market.configured():
        return False
    started = time.time()
    _, as_of = market.sectors()

    try:
        rows = market.heatmap()
        if rows:
            store.replace_heatmap(rows, as_of)
    except market.MarketError as exc:
        log(f"  heatmap: {exc}")
        rows = []

    try:
        # 120 days so the chart's longest time filter has data behind it.
        hist = market.sector_history(120)
        if hist:
            store.replace_sector_history(hist)
    except market.MarketError as exc:
        log(f"  sector history: {exc}")
        hist = []

    try:
        # Insiders: last week of material Form 4s. Congress: two weeks of
        # disclosures so the panel has enough >$0.5M rows to scroll.
        ins = market.insider_trades(days=7)
        con = market.congress_trades(days=14)
        store.replace_trades(ins, con)
    except market.MarketError as exc:
        log(f"  trades: {exc}")
        ins = con = []

    log(f"sections: {len(rows)} heatmap, {len(hist)} sector series, "
        f"{len(ins)} insider (7d), {len(con)} congress (14d), "
        f"{time.time()-started:.1f}s")
    return True


def refresh_earnings() -> bool:
    """FMP earnings calendar for the window the Earnings page reads."""
    if not market.configured():
        return False
    start = dt.date.today() - dt.timedelta(days=7)
    end = dt.date.today() + dt.timedelta(days=60)
    try:
        rows = market.earnings_calendar(start, end)
    except market.MarketError as exc:
        log(f"  earnings: {exc}")
        return False
    if not rows:
        log(f"earnings: FMP returned no rows for "
            f"{start.isoformat()} → {end.isoformat()}")
        return False
    try:
        n = store.replace_earnings(rows)
    except store.StoreError as exc:
        # Missing migration or RPC must not take down the whole worker loop.
        log(f"  earnings write failed: {exc}")
        return False
    log(f"earnings: {len(rows)} events ({n} written), "
        f"{start.isoformat()} → {end.isoformat()}")
    return True


def refresh_intraday(symbol: str) -> bool:
    """Fetch one symbol's chart series on demand."""
    if not market.configured():
        return False
    pts = market.intraday(symbol, days=2)
    if not pts:
        # Close the request anyway. A symbol FMP has no series for -- a
        # delisting, a ticker that never traded -- would otherwise sit at the
        # head of the queue and be drawn again on every pass.
        try:
            store.skip_intraday(symbol)
        except store.StoreError:
            pass
        return False
    store.upsert_intraday(symbol, pts, pts[-1]["t"][:10])
    q = market.quote(symbol)
    if q:
        store.upsert_quotes([q])
    return True


def drain_intraday(max_items: int = 5) -> int:
    """Fetch chart series for companies someone has just opened or followed.

    The market refresh pre-fetches a fixed set. Anything outside it -- a
    company added to a personal watchlist -- is pulled here, so it has a chart
    within a minute of being followed rather than at the next refresh.
    """
    if not market.configured():
        return 0
    try:
        pending = store.pending_intraday(max_items)
    except store.StoreError as exc:
        # 0020 not applied yet. The page falls back to daily closes, so this
        # degrades rather than taking the loop down with it.
        log(f"  intraday queue unavailable (apply 0020_intraday_requests.sql): {exc}")
        return 0
    return sum(1 for sym in pending if refresh_intraday(sym))


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
    log("worker up — the only process talking to the SEC and to FMP")
    last_directory = 0.0
    last_market = 0.0
    last_sections = 0.0
    last_sweep_day: dt.date | None = None
    market_every = int(os.environ.get("MARKET_REFRESH_SECONDS", "900"))
    sections_every = int(os.environ.get("SECTIONS_REFRESH_SECONDS", "3600"))

    while True:
        try:
            now = time.time()

            if now - last_directory > 24 * 3600:
                sync_directory()
                last_directory = now

            if now - last_market > market_every:
                try:
                    refresh_market()
                except market.MarketError as exc:
                    log(f"market refresh failed (continuing): {exc}")
                try:
                    refresh_news()
                except market.MarketError as exc:
                    log(f"news refresh failed (continuing): {exc}")
                # Keep the Earnings page warm with the market cycle (one FMP
                # call) so a deploy does not wait an hour for the first fill.
                try:
                    refresh_earnings()
                except market.MarketError as exc:
                    log(f"earnings refresh failed (continuing): {exc}")
                last_market = now

            if now - last_sections > sections_every:
                try:
                    refresh_industry_pe()
                except market.MarketError as exc:
                    log(f"industry PE failed (continuing): {exc}")
                try:
                    refresh_sections()
                except market.MarketError as exc:
                    log(f"sections refresh failed (continuing): {exc}")
                last_sections = now

            # Visitors first: a queued company should appear within a minute.
            if drain_backfill():
                continue
            if drain_prices():
                continue
            if drain_intraday():
                continue
            if drain_analyst():
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
    elif cmd == "prices":
        if len(argv) > 1:
            # An explicit symbol skips the queue, for checking one by hand.
            for sym in argv[1:]:
                fetch_prices(sym)
        else:
            log(f"filled {drain_prices(25)} price request(s)")

    elif cmd == "analyst":
        if len(argv) > 1:
            for sym in argv[1:]:
                fetch_analyst(sym)
        else:
            log(f"filled {drain_analyst(25)} analyst request(s)")

    elif cmd == "industry-pe":
        log("industry PE refreshed" if refresh_industry_pe()
            else "industry PE unavailable")

    elif cmd == "market":
        log("market refreshed" if refresh_market()
            else "FMP_API_KEY not set; nothing to do")
    elif cmd == "news":
        log("news refreshed" if refresh_news()
            else "FMP_API_KEY not set; nothing to do")
    elif cmd == "sections":
        log("sections refreshed" if refresh_sections()
            else "FMP_API_KEY not set; nothing to do")
    elif cmd == "earnings":
        log("earnings refreshed" if refresh_earnings()
            else "earnings unavailable (check FMP_API_KEY / plan / migration)")
    elif cmd == "intraday":
        if len(argv) < 2:
            print("usage: python worker.py intraday TICKER")
            return 2
        for t in argv[1:]:
            log(f"{t}: {'ok' if refresh_intraday(t.upper()) else 'no data'}")
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
