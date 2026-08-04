"""
market.py -- market data from Financial Modeling Prep.

This is the second source, and it answers a different question from the SEC.
EDGAR knows what a company earned last quarter; it knows nothing about what
the stock did today. FMP supplies prices, market capitalisation, the day's
movers and sector performance -- and nothing here touches the financial
statements, which stay with the filings.

The API key is a paid secret, so every call happens in the worker. The browser
reads the results out of Supabase like everything else.

Standard library only.
"""

from __future__ import annotations

import datetime as dt
import json
import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request

BASE = "https://financialmodelingprep.com/stable"
KEY = os.environ.get("FMP_API_KEY", "")

# FMP bills per request and rate-limits per minute. Nothing here is urgent, so
# pace it rather than risk a 429 mid-refresh.
_MIN_INTERVAL = 0.25
_last = [0.0]


class MarketError(RuntimeError):
    pass


def configured() -> bool:
    return bool(KEY)


def _get(path: str, **params):
    if not KEY:
        raise MarketError("FMP_API_KEY is not set; market data is unavailable.")

    wait = _MIN_INTERVAL - (time.time() - _last[0])
    if wait > 0:
        time.sleep(wait)
    _last[0] = time.time()

    params["apikey"] = KEY
    url = f"{BASE}/{path}?{urllib.parse.urlencode(params)}"
    req = urllib.request.Request(url, headers={"Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            return json.loads(resp.read().decode("utf-8", "replace"))
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")[:200]
        if exc.code == 402:
            raise MarketError(f"{path}: not included in this FMP plan") from exc
        raise MarketError(f"{path}: HTTP {exc.code} {body}") from exc
    except Exception as exc:
        raise MarketError(f"{path}: {exc}") from exc


# ---------------------------------------------------------------------------
# The day's movers
# ---------------------------------------------------------------------------

# FMP's movers lists are dominated by sub-dollar stocks that doubled on no
# volume. A "top stock of the day" that is a $0.09 shell up 200% is noise, not
# information, so anything below this price is left out.
MIN_MOVER_PRICE = float(os.environ.get("MIN_MOVER_PRICE", "5"))
MIN_MOVER_CAP = float(os.environ.get("MIN_MOVER_CAP", "1e9"))

# The screener returns the whole large-cap universe in one call, which is what
# makes the market-cap filter affordable: the alternative is a quote request
# per candidate. Cached for the length of a refresh so gainers, losers and
# actives share the one call.
_caps_cache: dict[str, object] = {"at": 0.0, "rows": [], "symbols": set()}


def _screener(min_cap: float | None = None, ttl: int = 900) -> list[dict]:
    """The raw screener rows, cached. Carries market cap and company name."""
    if time.time() - float(_caps_cache["at"]) < ttl and _caps_cache["rows"]:
        return _caps_cache["rows"]             # type: ignore[return-value]
    rows = _get("company-screener",
                marketCapMoreThan=int(min_cap or MIN_MOVER_CAP),
                isActivelyTrading="true", limit=5000) or []
    if rows:
        _caps_cache.update(at=time.time(), rows=rows,
                           symbols={r["symbol"] for r in rows if r.get("symbol")})
    return rows


def large_caps(min_cap: float | None = None, ttl: int = 900) -> set[str]:
    """Symbols above `min_cap`, as a set for cheap membership tests."""
    _screener(min_cap, ttl)
    return _caps_cache["symbols"]              # type: ignore[return-value]


def _movers(path: str, kind: str, limit: int, allowed: set[str] | None) -> list[dict]:
    rows = _get(path) or []
    out = []
    for r in rows:
        sym, price = r.get("symbol"), r.get("price")
        if not sym or price is None or price < MIN_MOVER_PRICE:
            continue
        if allowed is not None and sym not in allowed:
            continue
        out.append({
            "kind": kind,
            "rank": len(out) + 1,
            "symbol": sym,
            "name": r.get("name"),
            "price": price,
            "change": r.get("change"),
            "change_pct": r.get("changesPercentage"),
            "exchange": r.get("exchange"),
        })
        if len(out) >= limit:
            break
    return out


def gainers(limit: int = 25, min_cap: float | None = None) -> list[dict]:
    return _movers("biggest-gainers", "gainer", limit, large_caps(min_cap))


def losers(limit: int = 25, min_cap: float | None = None) -> list[dict]:
    return _movers("biggest-losers", "loser", limit, large_caps(min_cap))


def actives(limit: int = 25, min_cap: float | None = None) -> list[dict]:
    return _movers("most-actives", "active", limit, large_caps(min_cap))


# ---------------------------------------------------------------------------
# Sectors
# ---------------------------------------------------------------------------

def sectors(day: dt.date | None = None, look_back: int = 6) -> tuple[list[dict], str | None]:
    """Average move per sector on the last trading day.

    Asked on a weekend or a holiday the snapshot is empty, so walk back until
    a session turns up. Returns the rows and the date they belong to, because
    "the last trading day" is something the page should be able to say out
    loud rather than imply.

    FMP reports one row per sector per exchange, so the exchanges are averaged
    into a single figure per sector.
    """
    start = day or dt.date.today()
    for back in range(look_back):
        d = start - dt.timedelta(days=back)
        rows = _get("sector-performance-snapshot", date=d.isoformat()) or []
        agg: dict[str, list[float]] = {}
        for r in rows:
            s, v = r.get("sector"), r.get("averageChange")
            if s and v is not None:
                agg.setdefault(s, []).append(float(v))
        if agg:
            out = sorted(
                ({"sector": s, "change_pct": sum(v) / len(v)} for s, v in agg.items()),
                key=lambda r: -r["change_pct"])
            return out, d.isoformat()
    return [], None


# ---------------------------------------------------------------------------
# Quotes
# ---------------------------------------------------------------------------

def quote(symbol: str) -> dict | None:
    rows = _get("quote", symbol=symbol) or []
    if not rows:
        return None
    r = rows[0]
    return {
        "symbol": r.get("symbol"),
        "name": r.get("name"),
        "price": r.get("price"),
        "change": r.get("change"),
        "change_pct": r.get("changePercentage"),
        "volume": r.get("volume"),
        "market_cap": r.get("marketCap"),
        "day_low": r.get("dayLow"),
        "day_high": r.get("dayHigh"),
        "exchange": r.get("exchange"),
    }


def quote_detail(symbol: str) -> dict | None:
    """Everything the company page's price panel shows, in one call.

    `quote` already carries the session's range, the 52-week range and the
    moving averages, so the panel costs a single request. The ratios are a
    second, optional one -- a company with no earnings has no P/E, and that is
    a fact about the company rather than a failure to fetch.
    """
    rows = _get("quote", symbol=symbol) or []
    if not rows:
        return None
    r = rows[0]
    out = {
        "symbol": r.get("symbol"),
        "name": r.get("name"),
        "price": r.get("price"),
        "change": r.get("change"),
        "change_pct": r.get("changePercentage"),
        "open": r.get("open"),
        "previous_close": r.get("previousClose"),
        "day_low": r.get("dayLow"),
        "day_high": r.get("dayHigh"),
        "year_low": r.get("yearLow"),
        "year_high": r.get("yearHigh"),
        "volume": r.get("volume"),
        "market_cap": r.get("marketCap"),
        "avg_50": r.get("priceAvg50"),
        "avg_200": r.get("priceAvg200"),
        "exchange": r.get("exchange"),
    }
    try:
        rr = (_get("ratios-ttm", symbol=symbol) or [{}])[0]
        out["pe"] = rr.get("priceToEarningsRatioTTM")
        out["pb"] = rr.get("priceToBookRatioTTM")
        out["dividend_yield"] = rr.get("dividendYieldTTM")
    except MarketError:
        pass
    if out["market_cap"] and out["price"]:
        out["shares"] = out["market_cap"] / out["price"]
    return out


def daily(symbol: str, days: int = 300) -> list[dict]:
    """Daily bars, oldest first, for the candlestick chart."""
    end = dt.date.today()
    start = end - dt.timedelta(days=max(30, days))
    rows = _get("historical-price-eod/full", symbol=symbol,
                **{"from": start.isoformat(), "to": end.isoformat()}) or []
    bars = [{"d": r["date"], "o": r.get("open"), "h": r.get("high"),
             "l": r.get("low"), "c": r.get("close"), "v": r.get("volume")}
            for r in rows
            if r.get("date") and r.get("close") is not None]
    bars.sort(key=lambda b: b["d"])
    return bars


def quotes(symbols: list[str]) -> list[dict]:
    """Batch quoting is not in every FMP plan, so fetch one at a time.

    Slower, but it is the worker doing it on a timer, not a visitor waiting.
    """
    out = []
    for s in symbols:
        try:
            q = quote(s)
            if q and q.get("price") is not None:
                out.append(q)
        except MarketError:
            continue
    return out


# ---------------------------------------------------------------------------
# Intraday series for the chart
# ---------------------------------------------------------------------------

def intraday(symbol: str, days: int = 2) -> list[dict]:
    """Five-minute bars over the last couple of sessions, oldest first."""
    end = dt.date.today()
    start = end - dt.timedelta(days=max(1, days) + 3)   # pad for weekends
    rows = _get("historical-chart/5min", symbol=symbol,
                **{"from": start.isoformat(), "to": end.isoformat()}) or []
    pts = [{"t": r["date"], "c": r.get("close")} for r in rows
           if r.get("date") and r.get("close") is not None]
    pts.sort(key=lambda p: p["t"])
    # Keep the most recent two sessions' worth without needing a calendar.
    sessions = sorted({p["t"][:10] for p in pts})[-days:]
    return [p for p in pts if p["t"][:10] in sessions]


# ---------------------------------------------------------------------------
# Heatmap constituents
# ---------------------------------------------------------------------------
# FMP's index-constituent endpoint is not in every plan, so the heatmap runs
# off a curated large-cap list instead. Sector membership barely moves, and a
# treemap of ~55 names reads better than one of 500 anyway -- the small tiles
# in a full-index map are unreadable.
HEATMAP_UNIVERSE = [
    # Technology
    "AAPL", "MSFT", "NVDA", "AVGO", "ORCL", "CRM", "AMD", "ADBE", "CSCO", "ACN",
    "TXN", "QCOM", "INTU", "IBM",
    # Communication services
    "GOOGL", "META", "NFLX", "DIS", "TMUS", "VZ", "T",
    # Consumer cyclical
    "AMZN", "TSLA", "HD", "MCD", "NKE", "SBUX", "LOW", "BKNG",
    # Consumer defensive
    "WMT", "PG", "COST", "KO", "PEP", "PM",
    # Healthcare
    "LLY", "UNH", "JNJ", "ABBV", "MRK", "TMO", "ABT", "PFE",
    # Financials
    "BRK-B", "JPM", "V", "MA", "BAC", "WFC", "GS",
    # Industrials, energy, utilities, materials, real estate
    "CAT", "GE", "RTX", "UNP", "XOM", "CVX", "COP", "NEE", "DUK",
    "LIN", "SHW", "AMT", "PLD",
]


def heatmap(symbols: list[str] | None = None) -> list[dict]:
    """Sector, market cap and day change per symbol, for the treemap.

    `profile` returns all three in one call, so this costs one request per
    name rather than three.
    """
    out = []
    for sym in (symbols or HEATMAP_UNIVERSE):
        try:
            rows = _get("profile", symbol=sym) or []
        except MarketError:
            continue
        if not rows:
            continue
        r = rows[0]
        if r.get("marketCap") and r.get("sector"):
            out.append({
                "symbol": r.get("symbol"),
                "name": r.get("companyName"),
                "sector": r.get("sector"),
                "industry": r.get("industry"),
                "market_cap": r.get("marketCap"),
                "price": r.get("price"),
                "change_pct": r.get("changePercentage"),
            })
    return out


# ---------------------------------------------------------------------------
# Sector movement over time
# ---------------------------------------------------------------------------

SECTOR_NAMES = [
    "Technology", "Communication Services", "Consumer Cyclical",
    "Consumer Defensive", "Healthcare", "Financial Services",
    "Industrials", "Energy", "Utilities", "Real Estate", "Basic Materials",
]


def sector_history(days: int = 45) -> list[dict]:
    """Daily average change per sector, for the rotation chart."""
    end = dt.date.today()
    start = end - dt.timedelta(days=days)
    out = []
    for sector in SECTOR_NAMES:
        try:
            rows = _get("historical-sector-performance", sector=sector,
                        **{"from": start.isoformat(), "to": end.isoformat()}) or []
        except MarketError:
            continue
        # One row per exchange per day; average them into a single series.
        by_day: dict[str, list[float]] = {}
        for r in rows:
            d, v = r.get("date"), r.get("averageChange")
            if d and v is not None:
                by_day.setdefault(d, []).append(float(v))
        series = [{"d": d, "v": sum(v) / len(v)} for d, v in sorted(by_day.items())]
        if series:
            out.append({"sector": sector, "series": series})
    return out


# ---------------------------------------------------------------------------
# Insider and congressional trades
# ---------------------------------------------------------------------------

def insider_trades(limit: int = 40) -> list[dict]:
    """The most recent Form 4 filings, one line per company.

    A single company often files a dozen Form 4s on the same day -- each
    officer separately, or one sale split across several lots. Left as-is the
    panel fills with one ticker repeated, so only the largest transaction per
    company is kept and a wider window is fetched to compensate.
    """
    rows = _get("insider-trading/latest", page=0, limit=max(limit * 5, 100)) or []
    out = []
    for r in rows:
        shares = r.get("securitiesTransacted") or 0
        price = r.get("price") or 0
        code = (r.get("transactionType") or r.get("acquisitionOrDisposition") or "")
        buy = str(code).upper().startswith(("P", "A"))
        out.append({
            "filed": r.get("filingDate", "")[:10],
            "symbol": r.get("symbol"),
            "side": "Buy" if buy else "Sell",
            "shares": shares,
            "amount": (shares * price) * (1 if buy else -1),
            "person": r.get("reportingName"),
        })

    best: dict[str, dict] = {}
    for r in out:
        if not r["symbol"]:
            continue
        prev = best.get(r["symbol"])
        if prev is None or abs(r["amount"]) > abs(prev["amount"]):
            best[r["symbol"]] = r
    return sorted(best.values(),
                  key=lambda r: (r["filed"], abs(r["amount"])), reverse=True)[:limit]


def congress_trades(limit: int = 40) -> list[dict]:
    """Recent disclosures from both chambers, newest first."""
    rows = []
    for path, chamber in (("senate-latest", "Senate"), ("house-latest", "House")):
        try:
            for r in _get(path, page=0, limit=limit) or []:
                rows.append({
                    "disclosed": (r.get("disclosureDate") or "")[:10],
                    "traded": (r.get("transactionDate") or "")[:10],
                    "symbol": r.get("symbol"),
                    "person": " ".join(x for x in (r.get("firstName"), r.get("lastName")) if x),
                    "chamber": chamber,
                    "side": r.get("type"),
                    "amount": r.get("amount"),
                })
        except MarketError:
            continue
    rows = [r for r in rows if r["symbol"]]
    rows.sort(key=lambda r: r["disclosed"], reverse=True)
    return rows[:limit]


# ---------------------------------------------------------------------------
# News
# ---------------------------------------------------------------------------

# Counting words in headlines produced chips like "here's" and "august" --
# technically frequent, useless to click. These are the subjects a market
# reader actually navigates by, each paired with the text the filter searches
# for. Label and query are separate so a chip can read "The Fed" while
# matching the word that appears in the copy.
_TOPICS: list[tuple[str, str]] = [
    ("S&P 500",        "S&P 500"),
    ("Nasdaq",         "Nasdaq"),
    ("Dow Jones",      "Dow Jones"),
    ("The Fed",        "Fed"),
    ("Inflation",      "inflation"),
    ("Interest Rates", "interest rate"),
    ("Earnings",       "earnings"),
    ("Guidance",       "guidance"),
    ("Dividends",      "dividend"),
    ("Buybacks",       "buyback"),
    ("Tariffs",        "tariff"),
    ("Jobs",           "jobs report"),
    ("Recession",      "recession"),
    ("Oil",            "oil price"),
    ("Gold",           "gold"),
    ("Bitcoin",        "bitcoin"),
    ("AI",             "artificial intelligence"),
    ("Semiconductors", "semiconductor"),
    ("IPO",            "IPO"),
    ("M&A",            "acquisition"),
    ("Layoffs",        "layoff"),
    ("Upgrades",       "upgrade"),
]


def top_by_cap(n: int = 8) -> list[tuple[str, str]]:
    """The largest listed companies, as (ticker, company name).

    Comes off the same screener call the mover filter already makes, so this
    costs nothing extra. Names are trimmed of their suffixes because a chip
    should read "NVIDIA", not "NVIDIA Corporation".

    Funds are excluded -- the screener ranks Vanguard's total-market fund
    among the largest listings, which is true and not a company -- and dual
    listings collapse to one entry, so Alphabet appears once rather than as
    both GOOG and GOOGL.
    """
    ranked = sorted(
        (r for r in _screener()
         if r.get("symbol") and r.get("marketCap")
         and not r.get("isEtf") and not r.get("isFund")),
        key=lambda r: -float(r["marketCap"]))
    out: list[tuple[str, str]] = []
    seen: set[str] = set()
    for r in ranked:
        name = _trim_company(r.get("companyName") or r["symbol"])
        if not name or name.lower() in seen:
            continue
        seen.add(name.lower())
        out.append((r["symbol"], name))
        if len(out) >= n:
            break
    return out


_SUFFIXES = re.compile(
    r",?\s+(inc|incorporated|corp|corporation|co|company|ltd|limited|plc|"
    r"holdings?|group|sa|nv|ag|lp|llc|class [a-c]|& co)\.?$", re.I)


def _trim_company(name: str) -> str:
    prev = None
    while prev != name:
        prev = name
        name = _SUFFIXES.sub("", name).strip()
    return name


def _topics(companies: list[tuple[str, str]]) -> list[dict]:
    """The catalogue of chips: what each one says, and what it searches for.

    Deliberately uncounted. Counting here would mean counting the batch just
    fetched, while the filter searches a seven-day window -- the two disagreed
    badly enough that "Nasdaq" read 2 and opened on 21 stories. The count is
    computed in get_news against the same rows the filter reads.

    `ord` is the position: for companies that is market-cap rank, which is the
    order they are shown in and the reason they are on the list at all.
    """
    out = [{"word": label, "query": query, "kind": "topic", "ord": i}
           for i, (label, query) in enumerate(_TOPICS)]
    out += [{"word": name, "query": ticker, "kind": "company", "ord": i}
            for i, (ticker, name) in enumerate(companies)]
    return out


def news(limit: int = 120) -> tuple[list[dict], list[dict]]:
    """Latest market news, plus the topics that describe it.

    Company news and general market news are merged: the first names a ticker
    and the second sets the backdrop, and a reader wants both in one stream.
    """
    rows: list[dict] = []
    for path, kind in (("news/stock-latest", "stock"),
                       ("news/general-latest", "general")):
        try:
            for r in _get(path, page=0, limit=limit) or []:
                title = (r.get("title") or "").strip()
                if not title:
                    continue
                rows.append({
                    "url": r.get("url"),
                    "title": title,
                    "summary": (r.get("text") or "").strip(),
                    "image": r.get("image"),
                    "publisher": r.get("publisher") or r.get("site"),
                    "symbol": (r.get("symbol") or "").upper() or None,
                    "published": r.get("publishedDate"),
                    "kind": kind,
                })
        except MarketError:
            continue

    seen, uniq = set(), []
    for r in rows:
        key = r["url"] or r["title"]
        if key in seen:
            continue
        seen.add(key)
        uniq.append(r)
    uniq.sort(key=lambda r: r["published"] or "", reverse=True)

    try:
        companies = top_by_cap(8)
    except MarketError:
        companies = []
    return uniq[:limit * 2], _topics(companies)


# ---------------------------------------------------------------------------
# Company report: benchmark, seasonality, industry valuation
# ---------------------------------------------------------------------------

# FMP sells no per-industry price index, so the benchmark is the sector SPDR.
# Eleven ETFs cover every US listing, and because they are shared by every
# company in the sector they cost one fetch each rather than one per company.
SECTOR_ETF = {
    "Technology": "XLK",
    "Financial Services": "XLF",
    "Healthcare": "XLV",
    "Consumer Cyclical": "XLY",
    "Consumer Defensive": "XLP",
    "Industrials": "XLI",
    "Energy": "XLE",
    "Utilities": "XLU",
    "Real Estate": "XLRE",
    "Basic Materials": "XLB",
    "Communication Services": "XLC",
}


def profile(symbol: str) -> dict | None:
    """Sector and industry, which decide the benchmark and the peer PE."""
    rows = _get("profile", symbol=symbol) or []
    if not rows:
        return None
    r = rows[0]
    return {
        "symbol": r.get("symbol"),
        "name": r.get("companyName"),
        "sector": r.get("sector"),
        "industry": r.get("industry"),
        "exchange": r.get("exchangeShortName") or r.get("exchange"),
    }


def closes(symbol: str, years: int = 11) -> list[dict]:
    """Daily closes over several years, oldest first.

    The `light` series carries date, close and volume only, which is all the
    seasonality and benchmark charts need and a fraction of the payload of the
    full OHLC series.
    """
    end = dt.date.today()
    start = end - dt.timedelta(days=int(365.25 * max(1, years)))
    rows = _get("historical-price-eod/light", symbol=symbol,
                **{"from": start.isoformat(), "to": end.isoformat()}) or []
    out = [{"d": r["date"], "c": r.get("price")}
           for r in rows if r.get("date") and r.get("price") is not None]
    out.sort(key=lambda b: b["d"])
    return out


def monthly_closes(symbol: str, years: int = 11) -> list[dict]:
    """The last close of each month, which is what monthly returns are built
    from. Ten years of months is 120 numbers; ten years of days is 2,600."""
    last: dict[str, dict] = {}
    for b in closes(symbol, years):
        last[b["d"][:7]] = b            # ascending, so the last write wins
    return [last[k] for k in sorted(last)]


def industry_pe(day: dt.date | None = None, look_back: int = 6) -> tuple[list[dict], str | None]:
    """Price/earnings by industry and by sector, for the most recent day FMP
    has. Only recent dates are served on this plan, so there is no history to
    draw -- these are reference values, not a series."""
    start = day or dt.date.today()
    for back in range(look_back):
        d = (start - dt.timedelta(days=back)).isoformat()
        rows: list[dict] = []
        for path, field in (("industry-pe-snapshot", "industry"),
                            ("sector-pe-snapshot", "sector")):
            try:
                got = _get(path, date=d) or []
            except MarketError:
                continue
            # One row per exchange; a company is not tied to an exchange's
            # valuation, so the exchanges are averaged.
            agg: dict[str, list[float]] = {}
            for r in got:
                name, pe = r.get(field), r.get("pe")
                if name and pe is not None:
                    agg.setdefault(name, []).append(float(pe))
            rows += [{"kind": field, "name": n, "pe": sum(v) / len(v)}
                     for n, v in agg.items()]
        if rows:
            return rows, d
    return [], None
