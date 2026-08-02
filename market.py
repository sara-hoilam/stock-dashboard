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


def _movers(path: str, kind: str, limit: int) -> list[dict]:
    rows = _get(path) or []
    out = []
    for r in rows:
        price = r.get("price")
        if not r.get("symbol") or price is None or price < MIN_MOVER_PRICE:
            continue
        out.append({
            "kind": kind,
            "rank": len(out) + 1,
            "symbol": r.get("symbol"),
            "name": r.get("name"),
            "price": price,
            "change": r.get("change"),
            "change_pct": r.get("changesPercentage"),
            "exchange": r.get("exchange"),
        })
        if len(out) >= limit:
            break
    return out


def gainers(limit: int = 25) -> list[dict]:
    return _movers("biggest-gainers", "gainer", limit)


def losers(limit: int = 25) -> list[dict]:
    return _movers("biggest-losers", "loser", limit)


def actives(limit: int = 25) -> list[dict]:
    return _movers("most-actives", "active", limit)


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
