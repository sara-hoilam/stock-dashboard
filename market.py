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

def _insider_title(type_of_owner: str | None) -> str:
    """Collapse FMP's typeOfOwner string into a short role label.

    Filings say things like ``officer: Sr. VP, Chief Acct Officer`` or plain
    ``director``. The Markets Today panel only has room for a generic title
    (CEO, CFO, Director, …) above the person's name.
    """
    raw = " ".join(str(type_of_owner or "").split())
    if not raw:
        return "Insider"
    # Lowercase and split camelCase (tenPercentOwner → ten percent owner) so
    # the same patterns work on both FMP styles.
    spaced = re.sub(r"([a-z])([A-Z])", r"\1 \2", raw)
    s = spaced.lower()
    body = s.split(":", 1)[-1].strip() if ":" in s else s
    hay = f"{s} {body}"

    # VP family before President: "vice president" contains "president".
    rules: list[tuple[str, str]] = [
        ("CEO", r"chief\s+executive|\bceo\b"),
        ("CFO", r"chief\s+financial|chief\s+acct|chief\s+account|\bcontroller\b|\bcfo\b"),
        ("CTO", r"chief\s+technolog|chief\s+information|\bcto\b|\bcio\b"),
        ("COO", r"chief\s+operating|\bcoo\b"),
        ("CMO", r"chief\s+marketing|\bcmo\b"),
        ("CLO", r"chief\s+legal|general\s+counsel|\bclo\b"),
        ("CHRO", r"chief\s+human|chief\s+people|\bchro\b"),
        ("SVP", r"senior\s+vice\s+president|sr\.?\s*vice\s+president|sr\.?\s*vp\b|\bsvp\b"),
        ("EVP", r"executive\s+vice\s+president|exec(?:utive)?\s+vp\b|\bevp\b"),
        ("VP", r"vice\s+president|\bv\.?p\.?\b"),
        ("President", r"\bpresident\b"),
        ("Director", r"\bdirector\b"),
        ("10% Owner", r"ten\s*percent|10\s*percent|10\s*%|beneficial\s+owner"),
        ("Officer", r"\bofficer\b"),
    ]
    for label, pattern in rules:
        if re.search(pattern, hay):
            return label
    return "Insider"


def _insider_person_name(name: str | None) -> str | None:
    """Light cleanup so ALL-CAPS Form 4 names read as ordinary names."""
    if not name:
        return None
    text = " ".join(str(name).split())
    if text.isupper() and any(c.isalpha() for c in text):
        return text.title()
    return text


def _as_day(value) -> dt.date | None:
    try:
        return dt.date.fromisoformat(str(value or "")[:10])
    except ValueError:
        return None


# Markets Today only surfaces material trades.
MIN_INSIDER_AMOUNT = 1_000_000       # $1M absolute Form 4 value
MIN_INSIDER_SHARES_PCT = 0.01        # or ≥1% of shares outstanding
MIN_CONGRESS_AMOUNT = 500_000        # $0.5M high end of disclosure range


def _congress_amount_high(raw) -> float:
    """Largest dollar figure mentioned in a disclosure amount band."""
    nums = re.findall(r"[\d,]+", str(raw or ""))
    vals: list[float] = []
    for n in nums:
        try:
            vals.append(float(n.replace(",", "")))
        except ValueError:
            continue
    return max(vals) if vals else 0.0


def _shares_outstanding_map(symbols: list[str], cap: int = 100) -> dict[str, float]:
    """Approx shares outstanding from FMP quote marketCap / price.

    Capped so a noisy Form 4 dump cannot turn into hundreds of quote calls.
    """
    out: dict[str, float] = {}
    for sym in symbols[:max(0, cap)]:
        if not sym or sym in out:
            continue
        try:
            q = quote(sym)
        except MarketError:
            continue
        if not q:
            continue
        px = q.get("price")
        cap_v = q.get("market_cap")
        if px and cap_v and float(px) > 0:
            out[sym] = float(cap_v) / float(px)
    return out


def insider_trades(days: int = 7, store_cap: int = 400) -> list[dict]:
    """Form 4 filings from the last `days`, one line per company.

    A single company often files a dozen Form 4s on the same day -- each
    officer separately, or one sale split across several lots. Left as-is the
    panel fills with one ticker repeated, so only the largest transaction per
    company (within the window) is kept. Pages are walked until filings fall
    outside the window so the Markets Today list can scroll through a week.

    A row is kept when abs(dollar amount) > $1M, or when shares transacted are
    at least 1% of estimated shares outstanding (market cap / price).
    """
    cutoff = dt.date.today() - dt.timedelta(days=max(1, days))
    raw_rows: list[dict] = []
    page_size = 100
    for page in range(12):
        rows = _get("insider-trading/latest", page=page, limit=page_size) or []
        if not rows:
            break
        page_days = [_as_day(r.get("filingDate")) for r in rows]
        page_days = [d for d in page_days if d]
        if page_days and max(page_days) < cutoff:
            break
        for r in rows:
            filed = _as_day(r.get("filingDate"))
            if filed is not None and filed < cutoff:
                continue
            shares = float(r.get("securitiesTransacted") or 0)
            price = float(r.get("price") or 0)
            code = (r.get("transactionType") or r.get("acquisitionOrDisposition") or "")
            buy = str(code).upper().startswith(("P", "A"))
            amount = (shares * price) * (1 if buy else -1)
            sym = r.get("symbol")
            if not sym:
                continue
            raw_rows.append({
                "filed": (r.get("filingDate") or "")[:10],
                "symbol": sym,
                "side": "Buy" if buy else "Sell",
                "shares": shares,
                "amount": amount,
                "person": _insider_person_name(r.get("reportingName")),
                "title": _insider_title(r.get("typeOfOwner")),
                "shares_out": None,
            })
        if len(rows) < page_size:
            break

    # Quote only names that need the 1%-of-float test (amount alone is not enough).
    need_out: dict[str, float] = {}
    for r in raw_rows:
        if abs(r["amount"] or 0) > MIN_INSIDER_AMOUNT:
            continue
        sh = float(r["shares"] or 0)
        if sh <= 0:
            continue
        sym = r["symbol"]
        need_out[sym] = max(need_out.get(sym, 0.0), sh)
    ranked_need = sorted(need_out, key=lambda s: -need_out[s])
    shares_out = _shares_outstanding_map(ranked_need)

    out: list[dict] = []
    for r in raw_rows:
        so = shares_out.get(r["symbol"])
        if so:
            r["shares_out"] = so
        big_dollars = abs(r["amount"] or 0) > MIN_INSIDER_AMOUNT
        big_float = bool(
            so and so > 0 and (float(r["shares"] or 0) / so) >= MIN_INSIDER_SHARES_PCT)
        if big_dollars or big_float:
            out.append(r)

    best: dict[str, dict] = {}
    for r in out:
        prev = best.get(r["symbol"])
        if prev is None or abs(r["amount"] or 0) > abs(prev["amount"] or 0):
            best[r["symbol"]] = r
    ranked = sorted(best.values(),
                    key=lambda r: (r["filed"] or "", abs(r["amount"] or 0)),
                    reverse=True)
    return ranked[:max(1, store_cap)]


def _congress_side(raw: str | None) -> str | None:
    """Map FMP disclosure types onto the same Buy/Sell labels as Form 4s."""
    if not raw:
        return None
    s = str(raw).strip().lower()
    if s.startswith(("buy", "purchase", "receive")) or "purchase" in s or "receive" in s:
        return "Buy"
    if (s.startswith(("sell", "sale")) or "sale" in s or "sell" in s
            or "exchange" in s):
        return "Sell"
    return str(raw).strip()


def congress_trades(days: int = 14, store_cap: int = 400) -> list[dict]:
    """Disclosures from both chambers filed in the last `days`, newest first.

    Only rows whose reported amount range tops out above $0.5M are kept.
    """
    cutoff = dt.date.today() - dt.timedelta(days=max(1, days))
    rows: list[dict] = []
    page_size = 100
    for path, chamber in (("senate-latest", "Senate"), ("house-latest", "House")):
        try:
            for page in range(12):
                batch = _get(path, page=page, limit=page_size) or []
                if not batch:
                    break
                page_days = [_as_day(r.get("disclosureDate")) for r in batch]
                page_days = [d for d in page_days if d]
                if page_days and max(page_days) < cutoff:
                    break
                for r in batch:
                    disclosed = _as_day(r.get("disclosureDate"))
                    if disclosed is not None and disclosed < cutoff:
                        continue
                    amount = r.get("amount")
                    if _congress_amount_high(amount) <= MIN_CONGRESS_AMOUNT:
                        continue
                    rows.append({
                        "disclosed": (r.get("disclosureDate") or "")[:10],
                        "traded": (r.get("transactionDate") or "")[:10],
                        "symbol": r.get("symbol"),
                        "person": " ".join(
                            x for x in (r.get("firstName"), r.get("lastName")) if x),
                        "chamber": chamber,
                        "side": _congress_side(r.get("type")),
                        "amount": amount,
                    })
                if len(batch) < page_size:
                    break
        except MarketError:
            continue
    rows = [r for r in rows if r["symbol"]]
    rows.sort(key=lambda r: r["disclosed"] or "", reverse=True)
    return rows[:max(1, store_cap)]


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


# Policy / geopolitics subjects the Discover rail on Markets Today also
# surfaces. Appended to the chip catalogue so the News page can filter them.
_POLICY_TOPICS: list[tuple[str, str]] = [
    ("War",            "war"),
    ("Sanctions",      "sanction"),
    ("Geopolitics",    "geopolit"),
]


def _topics(companies: list[tuple[str, str]]) -> list[dict]:
    """The catalogue of chips: what each one says, and what it searches for.

    Deliberately uncounted here. Counting the batch just fetched disagreed
    with the seven-day filter badly enough that "Nasdaq" read 2 and opened
    on 21 stories. upsert_news counts each chip against the stored corpus
    with the same match rules as the filter; get_news only reads those
    numbers so the page cannot time out recounting them.

    `ord` is the position: for companies that is market-cap rank, which is the
    order they are shown in and the reason they are on the list at all.
    """
    topics = list(_TOPICS) + _POLICY_TOPICS
    out = [{"word": label, "query": query, "kind": "topic", "ord": i}
           for i, (label, query) in enumerate(topics)]
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
        # Discover on Markets Today covers the twenty largest names; keep the
        # chip catalogue aligned so those tickers are tagged in the corpus.
        companies = top_by_cap(20)
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


def pe_history(symbol: str, limit: int = 40) -> list[dict]:
    """Historical price/earnings from FMP key-metrics, oldest first.

    The company page's P/E chart uses this rather than reconstructing TTM from
    sparse filing EPS (which misleads on FPIs that only tag some quarters).
    The price panel's current P/E still comes from ratios-ttm via quote_detail.
    """
    rows = _get("key-metrics", symbol=symbol, period="quarter", limit=limit) or []
    out = []
    for r in rows:
        pe = r.get("peRatio")
        if pe is None:
            pe = r.get("priceToEarningsRatio")
        d = r.get("date")
        if d and pe is not None:
            try:
                pe_f = float(pe)
            except (TypeError, ValueError):
                continue
            if pe_f > 0:
                out.append({"d": d, "pe": pe_f})
    out.sort(key=lambda p: p["d"])
    return out


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


# ---------------------------------------------------------------------------
# Fear & Greed — not an FMP endpoint
# ---------------------------------------------------------------------------

# CNN publishes a 0–100 equity Fear & Greed index. FMP has no equivalent.
# The worker reads CNN's public dataviz JSON (the same feed their page uses)
# and caches the score in Supabase so the browser never talks to CNN.
_CNN_FNG = "https://production.dataviz.cnn.io/index/fearandgreed/graphdata"
_CNN_HEADERS = {
    "User-Agent": ("Mozilla/5.0 (compatible; TickerAlphaBot/1.0; "
                   "+https://github.com/sara-hoilam/stock-dashboard)"),
    "Accept": "application/json",
    "Referer": "https://www.cnn.com/markets/fear-and-greed",
    "Origin": "https://www.cnn.com",
}


def _series(symbol: str, days: int = 200) -> list[float]:
    end = dt.date.today()
    rows = _get("historical-price-eod/light", symbol=symbol,
                **{"from": (end - dt.timedelta(days=days)).isoformat(),
                   "to": end.isoformat()}) or []
    rows = [r for r in rows if r.get("price") is not None]
    rows.sort(key=lambda r: r["date"])
    return [float(r["price"]) for r in rows]


def _scale(v: float, lo: float, hi: float) -> float:
    """Put a raw reading on 0-100, clamped."""
    if hi == lo:
        return 50.0
    return max(0.0, min(100.0, (v - lo) / (hi - lo) * 100.0))


def fear_greed_composite() -> dict:
    """A composite in the spirit of CNN's index, from the parts FMP serves.

    Five of CNN's seven components are reproducible here; their put/call ratio
    and 52-week high/low breadth are not, so this is our own reading rather
    than theirs, and it is labelled that way. Each component is scored 0-100,
    where 100 is greed, and the score is their mean.
    """
    parts: dict[str, float] = {}

    spy = _series("SPY", 220)
    if len(spy) > 130:
        ma125 = sum(spy[-125:]) / 125
        # +/-8% either side of the mean spans the range in practice.
        parts["momentum"] = _scale((spy[-1] / ma125 - 1) * 100, -8, 8)

    vix = _series("^VIX", 120)
    if len(vix) > 55:
        ma50 = sum(vix[-50:]) / 50
        # Inverted: a VIX above its own average is fear.
        parts["volatility"] = _scale((ma50 / vix[-1] - 1) * 100, -35, 35)

    tlt = _series("TLT", 60)
    if len(spy) > 21 and len(tlt) > 21:
        stocks = spy[-1] / spy[-21] - 1
        bonds = tlt[-1] / tlt[-21] - 1
        parts["safeHaven"] = _scale((stocks - bonds) * 100, -8, 8)

    hyg, lqd = _series("HYG", 60), _series("LQD", 60)
    if len(hyg) > 21 and len(lqd) > 21:
        junk = hyg[-1] / hyg[-21] - 1
        safe = lqd[-1] / lqd[-21] - 1
        parts["junkBonds"] = _scale((junk - safe) * 100, -3, 3)

    if not parts:
        return {}
    score = round(sum(parts.values()) / len(parts))
    label = ("Extreme fear" if score < 25 else "Fear" if score < 45 else
             "Neutral" if score < 55 else "Greed" if score < 75 else "Extreme greed")
    return {"score": float(score), "rating": label, "previous": None,
            "source": "composite",
            "components": {k: round(v) for k, v in parts.items()}}


def fear_greed() -> dict:
    """Current Fear & Greed score.

    CNN first, because theirs is the index people mean by the name. It is an
    undocumented endpoint on someone else's site, though, so a failure there
    falls back to our own composite rather than leaving the card blank -- and
    the row records which one it was, so the page never passes one off as the
    other.
    """
    try:
        return _fear_greed_cnn()
    except MarketError as exc:
        own = fear_greed_composite()
        if not own:
            raise
        own["note"] = f"CNN unavailable ({exc})"
        return own


def _fear_greed_cnn() -> dict:
    """Current CNN Fear & Greed score. Raises MarketError on failure."""
    req = urllib.request.Request(_CNN_FNG, headers=_CNN_HEADERS)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            data = json.loads(resp.read().decode("utf-8", "replace"))
    except Exception as exc:
        raise MarketError(f"fear_greed: {exc}") from exc

    fg = data.get("fear_and_greed") or {}
    score = fg.get("score")
    if score is None:
        raise MarketError("fear_greed: response missing score")
    return {
        "score": float(score),
        "rating": fg.get("rating"),
        "previous": fg.get("previous_close"),
        "source": "cnn",
    }


# ---------------------------------------------------------------------------
# Analyst coverage
# ---------------------------------------------------------------------------
# All of this is FMP's own: the consensus targets, the buy/hold/sell tally,
# the individual house ratings, and the wire stories behind each target change.
# Nothing here comes from a scraped or undocumented source.

def analyst_view(symbol: str, houses: int = 14, stories: int = 6) -> dict:
    """Targets, the rating tally, recent house actions and their sources."""
    out: dict = {"symbol": symbol.upper()}

    try:
        rows = _get("price-target-consensus", symbol=symbol) or []
        if rows:
            r = rows[0]
            out["target"] = {"high": r.get("targetHigh"), "low": r.get("targetLow"),
                             "consensus": r.get("targetConsensus"),
                             "median": r.get("targetMedian")}
    except MarketError:
        pass

    try:
        rows = _get("price-target-summary", symbol=symbol) or []
        if rows:
            r = rows[0]
            out["targetCounts"] = {
                "month": r.get("lastMonthCount"), "monthAvg": r.get("lastMonthAvgPriceTarget"),
                "quarter": r.get("lastQuarterCount"), "quarterAvg": r.get("lastQuarterAvgPriceTarget"),
                "year": r.get("lastYearCount"), "yearAvg": r.get("lastYearAvgPriceTarget"),
            }
    except MarketError:
        pass

    try:
        rows = _get("grades-consensus", symbol=symbol) or []
        if rows:
            r = rows[0]
            out["consensus"] = {
                "strongBuy": r.get("strongBuy") or 0, "buy": r.get("buy") or 0,
                "hold": r.get("hold") or 0, "sell": r.get("sell") or 0,
                "strongSell": r.get("strongSell") or 0,
                "rating": r.get("consensus"),
            }
    except MarketError:
        pass

    # One row per house per action, newest first. Keep the most recent action
    # from each house rather than the same bank five times.
    try:
        seen: set[str] = set()
        grades = []
        for g in sorted(_get("grades", symbol=symbol, limit=200) or [],
                        key=lambda g: g.get("date") or "", reverse=True):
            house = g.get("gradingCompany")
            if not house or house in seen:
                continue
            seen.add(house)
            grades.append({"date": g.get("date"), "house": house,
                           "from": g.get("previousGrade"), "to": g.get("newGrade"),
                           "action": g.get("action")})
            if len(grades) >= houses:
                break
        if grades:
            out["grades"] = grades
    except MarketError:
        pass

    # The wire story behind each target change, so a figure on the page can be
    # traced back to the note it came from.
    try:
        news = []
        for n in _get("price-target-news", symbol=symbol, limit=stories * 3) or []:
            if not n.get("newsURL"):
                continue
            news.append({
                "published": n.get("publishedDate"), "title": n.get("newsTitle"),
                "url": n.get("newsURL"), "publisher": n.get("newsPublisher"),
                "house": n.get("analystCompany"), "analyst": n.get("analystName"),
                "target": n.get("priceTarget"), "priceWhenPosted": n.get("priceWhenPosted"),
            })
            if len(news) >= stories:
                break
        if news:
            out["news"] = news
    except MarketError:
        pass

    return out
