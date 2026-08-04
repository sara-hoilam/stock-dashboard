"""
edgar.py -- SEC EDGAR data layer for the quarterly financials dashboard.

Everything here reads from official SEC sources only:

  * https://www.sec.gov/files/company_tickers.json      ticker -> CIK map
  * https://data.sec.gov/api/xbrl/companyfacts/         XBRL company facts
  * https://data.sec.gov/submissions/                   filing index
  * https://www.sec.gov/Archives/edgar/data/...         the filings themselves

No third-party data vendors, no estimates. Standard library only.
"""

from __future__ import annotations

import datetime as dt
import gzip
import io
import json
import os
import re
import threading
import time
import urllib.error
import urllib.request
from html.parser import HTMLParser

# SEC requires a declared User-Agent with a contact address, and asks for
# no more than 10 requests/second. Set SEC_CONTACT to your own email.
CONTACT = os.environ.get("SEC_CONTACT", "dashboard-user@example.com")
USER_AGENT = f"QuarterlyFinancialsDashboard/1.0 ({CONTACT})"

CACHE_DIR = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".cache")
os.makedirs(CACHE_DIR, exist_ok=True)

# Company facts change only when a new filing lands; filing documents never
# change. Keep facts for 6h, immutable archive documents for 30 days.
TTL_FACTS = 6 * 3600
TTL_ARCHIVE = 30 * 24 * 3600

_rate_lock = threading.Lock()
_last_request = [0.0]
_MIN_INTERVAL = 0.12  # ~8 req/s, under the SEC's 10/s ceiling


class FetchError(RuntimeError):
    pass


def _cache_path(url: str) -> str:
    safe = re.sub(r"[^A-Za-z0-9]+", "_", url)[-140:]
    return os.path.join(CACHE_DIR, safe + ".cache")


def fetch(url: str, ttl: int = TTL_ARCHIVE, binary: bool = False):
    """GET a URL through a disk cache, respecting the SEC's rate limit."""
    path = _cache_path(url)
    if os.path.exists(path) and (time.time() - os.path.getmtime(path)) < ttl:
        with open(path, "rb") as fh:
            data = fh.read()
        return data if binary else data.decode("utf-8", "replace")

    with _rate_lock:
        wait = _MIN_INTERVAL - (time.time() - _last_request[0])
        if wait > 0:
            time.sleep(wait)
        _last_request[0] = time.time()

    req = urllib.request.Request(
        url,
        headers={
            "User-Agent": USER_AGENT,
            "Accept-Encoding": "gzip, deflate",
            "Accept": "application/json, text/html, */*",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw = gzip.GzipFile(fileobj=io.BytesIO(raw)).read()
    except urllib.error.HTTPError as exc:
        raise FetchError(f"SEC returned {exc.code} for {url}") from exc
    except Exception as exc:  # network down, DNS, timeout
        raise FetchError(f"Could not reach {url}: {exc}") from exc

    with open(path, "wb") as fh:
        fh.write(raw)
    return raw if binary else raw.decode("utf-8", "replace")


# ---------------------------------------------------------------------------
# Ticker directory
# ---------------------------------------------------------------------------

_tickers_cache = {"at": 0.0, "rows": []}


def ticker_directory() -> list[dict]:
    """All SEC-registered tickers, as [{ticker, cik, name}]."""
    if _tickers_cache["rows"] and time.time() - _tickers_cache["at"] < 86400:
        return _tickers_cache["rows"]
    raw = json.loads(fetch("https://www.sec.gov/files/company_tickers.json", ttl=86400))
    rows = [
        {"ticker": v["ticker"].upper(), "cik": int(v["cik_str"]), "name": v["title"]}
        for v in raw.values()
    ]
    rows.sort(key=lambda r: r["ticker"])
    _tickers_cache.update(at=time.time(), rows=rows)
    return rows


def _entity_by_cik(cik: int) -> dict | None:
    """Look a company up by CIK, whether or not it carries a ticker.

    Reorganisations leave the operating company's filing history under a CIK
    the ticker file no longer points to, so a CIK has to be reachable too.
    """
    try:
        sub = json.loads(fetch(
            f"https://data.sec.gov/submissions/CIK{cik:010d}.json", ttl=TTL_FACTS))
    except FetchError:
        return None
    tickers = sub.get("tickers") or []
    return {
        "ticker": (tickers[0] if tickers else f"CIK{cik}"),
        "cik": cik,
        "name": sub.get("name") or f"CIK {cik}",
    }


def search_tickers(query: str, limit: int = 12) -> list[dict]:
    q = (query or "").strip().upper()
    if not q:
        return []

    # A bare number is a CIK.
    digits = re.sub(r"^CIK[\s:]*", "", q).strip()
    if digits.isdigit():
        hit = _entity_by_cik(int(digits))
        if hit:
            return [hit]

    rows = ticker_directory()
    exact, prefix, name_hit = [], [], []
    for r in rows:
        if r["ticker"] == q:
            exact.append(r)
        elif r["ticker"].startswith(q):
            prefix.append(r)
        elif q in r["name"].upper():
            name_hit.append(r)
    out, seen = [], set()
    for r in exact + prefix + name_hit:
        if r["ticker"] in seen:
            continue
        seen.add(r["ticker"])
        out.append(r)
        if len(out) >= limit:
            break
    return out


def resolve_ticker(ticker: str) -> dict:
    t = ticker.strip().upper()
    for r in ticker_directory():
        if r["ticker"] == t:
            return r
    digits = re.sub(r"^CIK[\s:]*", "", t).strip()
    if digits.isdigit():
        hit = _entity_by_cik(int(digits))
        if hit:
            return hit
    raise FetchError(f"'{ticker}' is not in the SEC ticker directory. "
                     f"You can also enter a CIK number directly.")


# ---------------------------------------------------------------------------
# Period arithmetic
# ---------------------------------------------------------------------------

def _d(s: str) -> dt.date:
    return dt.date.fromisoformat(s)


def _days(a: str, b: str) -> int:
    return (_d(b) - _d(a)).days


def classify_duration(days: int) -> str | None:
    """Bucket a fact's duration into the reporting period it represents."""
    if 78 <= days <= 100:
        return "Q"
    if 168 <= days <= 196:
        return "H"
    if 260 <= days <= 288:
        return "9M"
    if 350 <= days <= 380:
        return "FY"
    return None


def _snap_month(e: dt.date) -> tuple[int, int]:
    """The month a period end belongs to, ignoring a few days of drift.

    Retailers and others on a 52/53-week calendar end their year on a fixed
    weekday near a month end, so the date wanders either side of it: lululemon
    closed fiscal 2026 on 1 February and fiscal 2024 on 28 January. Reading the
    calendar month literally puts the February one in the next fiscal year and
    labels the fourth quarter as the first. Snapping to whichever month
    boundary is nearer keeps both in the year the company reported them in.
    """
    if e.day <= 7:                    # early in the month: likely the prior one
        prev = e.replace(day=1) - dt.timedelta(days=1)
        if e.day - 1 <= (prev.day - e.day) % 31:
            return prev.year, prev.month
    return e.year, e.month


def fiscal_label(end: str, fye_month: int) -> tuple[int, int]:
    """Map a period end date to (fiscal_year, fiscal_quarter).

    Works for non-calendar fiscal years: Apple's quarter ending December 2025
    is Q1 of fiscal 2026, because Apple's year ends in September.
    """
    e = _d(end)
    year, month = _snap_month(e)
    e = dt.date(year, month, 1)
    offset = (e.month - fye_month) % 12
    fq = 4 if offset == 0 else max(1, min(4, round(offset / 3)))
    if e.month == fye_month:
        fy = e.year
    elif e.month < fye_month:
        fy = e.year
    else:
        fy = e.year + 1
    return fy, fq


# ---------------------------------------------------------------------------
# XBRL facts -> quarterly series
# ---------------------------------------------------------------------------

# Each line item lists candidate US-GAAP tags in priority order. Companies
# tag the same economics differently, so the first tag that yields data wins.
CONCEPTS: dict[str, list[str]] = {
    "revenue": [
        # `Revenues` is the income-statement top line when a company tags it;
        # the contract-revenue tags can exclude items that sit above the line
        # (Walmart's membership income, Alphabet's hedging gains).
        "Revenues",
        "RevenueFromContractWithCustomerExcludingAssessedTax",
        "RevenueFromContractWithCustomerIncludingAssessedTax",
        # Banks and insurers report a top line that nets interest expense
        # rather than a goods-and-services revenue figure.
        "RevenuesNetOfInterestExpense",
        "InterestAndDividendIncomeOperating",
        "SalesRevenueNet",
        "SalesRevenueGoodsNet",
    ],
    "cogs": [
        "CostOfRevenue",
        "CostOfGoodsAndServicesSold",
        "CostOfGoodsSold",
        "CostOfServices",
    ],
    "grossProfit": ["GrossProfit"],
    "rd": ["ResearchAndDevelopmentExpense"],
    "sm": [
        "SellingAndMarketingExpense",
        "MarketingAndAdvertisingExpense",
    ],
    "ga": ["GeneralAndAdministrativeExpense"],
    "sga": ["SellingGeneralAndAdministrativeExpense"],
    "opexTotal": ["OperatingExpenses", "CostsAndExpenses"],
    # Banks and insurers run their whole cost base through non-interest
    # expense, and carry credit provisions as a separate charge.
    "noninterestExpense": ["NoninterestExpense"],
    "provisions": [
        "ProvisionForLoanLeaseAndOtherLosses",
        "ProvisionForCreditLosses",
        "ProvisionForLoanAndLeaseLosses",
    ],
    "operatingIncome": ["OperatingIncomeLoss"],
    "otherIncome": [
        "NonoperatingIncomeExpense",
        "OtherNonoperatingIncomeExpense",
    ],
    "pretaxIncome": [
        "IncomeLossFromContinuingOperationsBeforeIncomeTaxesExtraordinaryItemsNoncontrollingInterest",
        "IncomeLossFromContinuingOperationsBeforeIncomeTaxesMinorityInterestAndIncomeLossFromEquityMethodInvestments",
    ],
    "tax": ["IncomeTaxExpenseBenefit"],
    "netIncome": [
        "NetIncomeLoss",
        "ProfitLoss",
        "NetIncomeLossAvailableToCommonStockholdersBasic",
    ],
    "epsDiluted": ["EarningsPerShareDiluted", "EarningsPerShareBasicAndDiluted"],
    "sharesDiluted": ["WeightedAverageNumberOfDilutedSharesOutstanding"],

    # Cash flow. In a 10-Q these are reported year-to-date rather than for the
    # quarter, so they rely on the same differencing as the income statement.
    "operatingCashFlow": [
        "NetCashProvidedByUsedInOperatingActivities",
        "NetCashProvidedByUsedInOperatingActivitiesContinuingOperations",
    ],
    "investingCashFlow": [
        "NetCashProvidedByUsedInInvestingActivities",
        "NetCashProvidedByUsedInInvestingActivitiesContinuingOperations",
    ],
    "financingCashFlow": [
        "NetCashProvidedByUsedInFinancingActivities",
        "NetCashProvidedByUsedInFinancingActivitiesContinuingOperations",
    ],
    "capex": [
        "PaymentsToAcquirePropertyPlantAndEquipment",
        "PaymentsToAcquireProductiveAssets",
        "PaymentsForCapitalImprovements",
    ],
    "depreciation": [
        "DepreciationDepletionAndAmortization",
        "DepreciationAmortizationAndAccretionNet",
        "DepreciationAndAmortization",
    ],
    "stockComp": ["ShareBasedCompensation"],
}


# ---------------------------------------------------------------------------
# The same line items in the IFRS taxonomy
# ---------------------------------------------------------------------------
# Foreign private issuers -- AstraZeneca, Shell, SAP, Unilever -- file 20-F and
# 6-K tagged in ifrs-full rather than 10-K/10-Q in us-gaap. The statements say
# the same things under different names, so the whole model downstream works
# unchanged once the tags are mapped.
#
# What differs is the calendar. A 6-K carries a half-year and, for some filers,
# a single quarter; there is no nine-month figure, so Q3 and Q4 cannot be
# separated the way `quarterize` separates them for a 10-K filer. These
# companies are therefore reported in half-years, which is the finest
# granularity their filings actually support.
CONCEPTS_IFRS: dict[str, list[str]] = {
    "revenue": [
        "Revenue",
        "RevenueFromContractsWithCustomers",
        "RevenueFromSaleOfGoods",
    ],
    "cogs": ["CostOfSales"],
    "grossProfit": ["GrossProfit"],
    "rd": ["ResearchAndDevelopmentExpense"],
    "sm": ["DistributionCosts", "SellingGeneralAndAdministrativeExpense"],
    "ga": ["AdministrativeExpense"],
    "sga": [],
    "opexTotal": ["OperatingExpense"],
    "noninterestExpense": [],
    "provisions": [],
    "operatingIncome": ["ProfitLossFromOperatingActivities"],
    "otherIncome": [
        "OtherIncome",
        "FinanceIncome",
    ],
    "pretaxIncome": ["ProfitLossBeforeTax"],
    "tax": ["IncomeTaxExpenseContinuingOperations", "TaxExpenseIncome"],
    "netIncome": ["ProfitLoss", "ProfitLossAttributableToOwnersOfParent"],
    "nci": ["ProfitLossAttributableToNoncontrollingInterests"],
    "epsDiluted": ["DilutedEarningsLossPerShare"],
    "sharesDiluted": [
        "WeightedAverageNumberOfDilutedSharesOutstanding",
        "AdjustedWeightedAverageShares",
    ],
    "operatingCashFlow": ["CashFlowsFromUsedInOperatingActivities"],
    "investingCashFlow": ["CashFlowsFromUsedInInvestingActivities"],
    "financingCashFlow": ["CashFlowsFromUsedInFinancingActivities"],
    "capex": ["PurchaseOfPropertyPlantAndEquipmentClassifiedAsInvestingActivities"],
}


def taxonomy_for(facts: dict) -> tuple[str, dict[str, list[str]]]:
    """Which taxonomy this filer uses, and the concept map that reads it."""
    if "us-gaap" in facts:
        return "us-gaap", CONCEPTS
    if "ifrs-full" in facts:
        return "ifrs-full", CONCEPTS_IFRS
    raise FetchError(
        "This company's XBRL carries neither us-gaap nor ifrs-full concepts, "
        f"only: {', '.join(sorted(facts)) or 'nothing'}.")


def _usable_facts(facts: dict, tag: str, taxonomy: str = "us-gaap") -> list[dict]:
    """Duration facts for one tag, deduped so the latest filing wins.

    companyfacts carries no dimensional breakdown, so every fact here is a
    consolidated (whole-company) value -- which is what an income statement
    line needs. Restatements are handled by keeping the most recently filed
    value for any given (start, end) window.
    """
    node = (facts.get(taxonomy) or {}).get(tag)
    if not node:
        return []
    units = node.get("units", {})
    key = "USD" if "USD" in units else next(
        (k for k in units if k.startswith("USD")), None
    )
    if key is None:
        key = next((k for k in units if k in ("USD/shares", "shares")), None)
    if key is None:
        return []

    best: dict[tuple[str, str], dict] = {}
    for f in units[key]:
        if not f.get("start") or not f.get("end"):
            continue
        # 6-K is where a foreign private issuer files its interim results;
        # without it only the annual 20-F survives and there is nothing to
        # compare period to period.
        if f.get("form", "").split("/")[0] not in (
                "10-K", "10-Q", "20-F", "40-F", "6-K"):
            continue
        k = (f["start"], f["end"])
        prev = best.get(k)
        if prev is None or f.get("filed", "") > prev.get("filed", ""):
            best[k] = f
    return sorted(best.values(), key=lambda f: (f["end"], f["start"]))


def quarterize(items: list[dict]) -> dict[str, dict]:
    """Turn a tag's facts into a value per fiscal quarter, keyed by end date.

    Two sources, in priority order:
      1. A fact whose own window is ~one quarter long -- used as reported.
      2. Otherwise the difference between consecutive year-to-date facts
         sharing a fiscal-year start. This is what recovers Q4, which
         companies never report on its own: Q4 = FY - nine months.
    """
    out: dict[str, dict] = {}

    for f in items:
        if classify_duration(_days(f["start"], f["end"])) == "Q":
            out[f["end"]] = {
                "value": f["val"],
                "basis": "reported",
                "accn": f.get("accn"),
                "form": f.get("form"),
                "filed": f.get("filed"),
                "start": f["start"],
            }

    by_start: dict[str, list[dict]] = {}
    for f in items:
        if classify_duration(_days(f["start"], f["end"])):
            by_start.setdefault(f["start"], []).append(f)

    for chain in by_start.values():
        chain.sort(key=lambda f: f["end"])
        for i, f in enumerate(chain):
            if i == 0:
                continue
            prev = chain[i - 1]
            gap = _days(prev["end"], f["end"])
            if not (78 <= gap <= 100):
                continue
            if f["end"] in out:
                continue
            out[f["end"]] = {
                "value": f["val"] - prev["val"],
                "basis": "derived",
                "accn": f.get("accn"),
                "form": f.get("form"),
                "filed": f.get("filed"),
                # The derived quarter begins the day after the prior
                # cumulative period ended.
                "start": (_d(prev["end"]) + dt.timedelta(days=1)).isoformat(),
            }
    return out


def detect_fye_month(facts: dict, taxonomy: str = "us-gaap",
                     concepts: dict | None = None) -> int:
    """Fiscal year-end month, from the annual-duration revenue facts."""
    concepts = concepts or CONCEPTS
    counts: dict[int, int] = {}
    for group in ("revenue", "netIncome"):
        for tag in concepts[group]:
            for f in _usable_facts(facts, tag, taxonomy):
                if classify_duration(_days(f["start"], f["end"])) == "FY":
                    m = _d(f["end"]).month
                    counts[m] = counts.get(m, 0) + 1
    return max(counts, key=counts.get) if counts else 12


# ---------------------------------------------------------------------------
# Segment / product revenue, parsed out of the filing's own R-files
# ---------------------------------------------------------------------------

class _TableGrid(HTMLParser):
    """Flatten an EDGAR R-file financial report into a grid of cells.

    R-files are the tables the SEC's own viewer renders for a filing, so the
    numbers are exactly what the company filed -- including the dimensional
    breakdowns (by segment, by product) that companyfacts leaves out.
    """

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.rows: list[list[dict]] = []
        self._row: list[dict] | None = None
        self._cell: dict | None = None

    def handle_starttag(self, tag, attrs):
        a = dict(attrs)
        if tag == "tr":
            self._row = []
        elif tag in ("td", "th") and self._row is not None:
            self._cell = {
                "text": "",
                "class": a.get("class", ""),
                "colspan": int(a.get("colspan") or 1),
            }

    def handle_endtag(self, tag):
        if tag in ("td", "th") and self._cell is not None and self._row is not None:
            self._cell["text"] = re.sub(r"\s+", " ", self._cell["text"]).strip()
            self._row.append(self._cell)
            self._cell = None
        elif tag == "tr" and self._row is not None:
            if self._row:
                self.rows.append(self._row)
            self._row = None

    def handle_data(self, data):
        if self._cell is not None:
            self._cell["text"] += data


_NUM = re.compile(r"^\(?\$?\s*-?[\d,]+(?:\.\d+)?\)?$")


def _parse_number(text: str, scale: float) -> float | None:
    t = text.strip().replace("$", "").replace(" ", " ").strip()
    if not t or t in ("—", "–", "-"):
        return None
    neg = t.startswith("(") and t.endswith(")")
    t = t.strip("()").replace(",", "").strip()
    if not re.fullmatch(r"-?\d+(?:\.\d+)?", t):
        return None
    v = float(t) * scale
    return -v if neg else v


_MONTHS = {m: i for i, m in enumerate(
    ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
     "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], start=1)}


def _parse_date_header(text: str) -> str | None:
    m = re.search(r"([A-Z][a-z]{2})\.?\s+(\d{1,2}),\s*(\d{4})", text)
    if not m or m.group(1) not in _MONTHS:
        return None
    return f"{int(m.group(3)):04d}-{_MONTHS[m.group(1)]:02d}-{int(m.group(2)):02d}"


# Which metric row inside a segment table is revenue. Company wording varies a
# lot ("Net operating revenues", "Total Revenue", "Revenue from Products and
# Services"), so match broadly and disqualify the look-alikes explicitly.
_REVENUE_ROW = re.compile(r"(revenue|net sales|^sales\b|turnover)", re.I)
_NOT_REVENUE_ROW = re.compile(
    r"(deferred|unearned|cost of|operating income|operating loss|"
    r"expense|margin|depreciation|amorti|asset|capital expenditure|"
    r"employee|income tax|interest|hedg|percent|remaining performance|"
    r"obligation|growth|per share|backlog)", re.I)


def parse_report_table(html: str) -> list[dict]:
    """Extract (member, months, end_date, value) observations from one R-file.

    The SEC renderer prints a dimension's full member path in a single label
    row -- "YouTube ads | Google Services" -- and lists the metric rows for
    that member beneath it. So `member` is the segment identity and the row
    label only tells us which metric we are looking at.
    """
    p = _TableGrid()
    p.feed(html)
    rows = p.rows
    if len(rows) < 3:
        return []

    scale = 1.0
    head_text = " ".join(c["text"] for c in rows[0])
    if re.search(r"in Millions", head_text, re.I):
        scale = 1e6
    elif re.search(r"in Thousands", head_text, re.I):
        scale = 1e3
    elif re.search(r"in Billions", head_text, re.I):
        scale = 1e9

    # Header: an optional "N Months Ended" band row, then a row of end dates.
    # Both are aligned to the value columns positionally -- the date row has
    # no stub cell for the label column, so column indices cannot be trusted.
    months: list[int] = []
    dates: list[str] = []
    body_start = 0
    for ri, row in enumerate(rows[:6]):
        band, dat = [], []
        for cell in row:
            span = max(1, cell["colspan"])
            m = re.search(r"(\d+)\s*Months?\s+Ended", cell["text"], re.I)
            if m:
                band.extend([int(m.group(1))] * span)
            d = _parse_date_header(cell["text"])
            if d:
                dat.extend([d] * span)
        if band:
            months = band
            body_start = ri + 1
        if dat:
            dates = dat
            body_start = ri + 1

    if not dates:
        return []
    if len(months) < len(dates):
        months = (months or [3]) + [months[-1] if months else 3] * (len(dates) - len(months))

    body = rows[body_start:]

    # A label row with no numbers is either the name of a member, or one of
    # the structural headings the renderer repeats above each member's block
    # ("Disaggregation of revenue"). Some filings bracket those and some do
    # not -- but a member is named once, whereas a heading recurs, so
    # anything appearing twice is structure rather than a segment.
    seen_counts: dict[str, int] = {}
    for row in body:
        label = row[0]["text"].strip() if row else ""
        if label and not any(_parse_number(c["text"], scale) is not None for c in row[1:]):
            seen_counts[label] = seen_counts.get(label, 0) + 1
    repeated = {k for k, n in seen_counts.items() if n > 1}

    out: list[dict] = []
    member = ""
    for row in body:
        label = row[0]["text"].strip() if row else ""
        if not label:
            continue

        values = [v for v in (_parse_number(c["text"], scale) for c in row[1:])
                  if v is not None]

        if not values:
            if label in repeated:
                continue
            if re.search(r"\[(Line Items|Member|Abstract|Domain|Axis|Table)\]", label):
                continue
            member = label
            continue

        if _NOT_REVENUE_ROW.search(label) or not _REVENUE_ROW.search(label):
            continue

        for i, v in enumerate(values[:len(dates)]):
            out.append({
                "member": member,
                "metric": label,
                "months": months[i],
                "end": dates[i],
                "value": v,
            })
    return out


# Axis labels the SEC renderer inserts into a member path. They name the
# dimension, not a piece of the business, so they are dropped -- otherwise the
# same segment appears twice, once bare and once under its axis.
_AXIS_LABEL = re.compile(
    r"^(operating|reportable|business|all other)?\s*segments?$|"
    r"^segment (reporting|information)|^consolidated entit|"
    r"^products? and services?$|^product and service|"
    r"^geographical?$|^geographic (area|region|location)s?$|"
    r"^subsegments?$|^\[?domain\]?$", re.I)


def _normalize_member(member: str) -> str:
    parts = [p.strip() for p in member.split("|") if p.strip()]
    kept = [p for p in parts if not _AXIS_LABEL.match(p)]
    return " | ".join(kept if kept else parts)


def _member_parts(member: str) -> tuple[str, str]:
    """Split "YouTube ads | Google Services" into (leaf name, parent path)."""
    parts = [p.strip() for p in member.split("|")]
    return parts[0], " | ".join(parts[1:])


def reconcile_segments(obs: list[dict], total: float) -> list[dict]:
    """Reduce a segment table to a non-overlapping breakdown of revenue.

    A segment note lists several metrics per member, so each metric is tried
    on its own and the one that reconciles to consolidated revenue wins --
    Walmart's segments add up under "Total revenues" but not under "Net
    sales", and only the filing itself can settle which is which.
    """
    if not obs or not total:
        return []

    by_metric: dict[str, list[dict]] = {}
    for o in obs:
        by_metric.setdefault(o["metric"].strip().lower(), []).append(o)

    best: list[dict] = []
    best_gap = None
    for group in by_metric.values():
        rows = _reconcile_one_metric(group, total)
        if not rows:
            continue
        gap = abs(sum(r["value"] for r in rows) - total)
        # Prefer the tightest reconciliation; break ties toward more detail.
        if best_gap is None or (gap, -len(rows)) < (best_gap, -len(best)):
            best, best_gap = rows, gap
    return best


def _reconcile_one_metric(obs: list[dict], total: float) -> list[dict]:
    """Build the member tree for one metric and strip its subtotals.

    Segment tables mix leaves with subtotals -- Alphabet reports "Google
    advertising" next to the three lines that make it up. Expanding any node
    whose children add up to it drops the subtotals without hard-coding a
    single company's structure.
    """
    by_member: dict[str, float] = {}
    for o in obs:
        m = _normalize_member(o["member"])
        if not m or m in by_member:
            continue
        by_member[m] = o["value"]

    if len(by_member) < 2:
        return []

    # Segment tables often repeat the consolidated figure as its own row,
    # which would double the total. Drop such a row only when the remaining
    # members already account for the whole company -- a dominant segment can
    # legitimately be within a percent of total revenue on its own.
    for cand, val in list(by_member.items()):
        if abs(val - total) > abs(total) * 0.02:
            continue
        others = sum(v for m, v in by_member.items() if m != cand)
        if others and abs(others - total) <= abs(total) * 0.02:
            del by_member[cand]
    if len(by_member) < 2:
        return []

    children: dict[str, list[str]] = {}
    for m in by_member:
        _, parent = _member_parts(m)
        children.setdefault(parent, []).append(m)

    def expand(member: str) -> list[str]:
        """A member, or its children if they account for it."""
        kids = children.get(member, [])
        if len(kids) < 2:
            return [member]
        # Drop any child that is itself the sum of two or more of its siblings.
        real = [k for k in kids
                if not _subset_sums_to(
                    [by_member[o] for o in kids if o != k], by_member[k])]
        if len(real) < 2:
            real = kids
        s = sum(by_member[k] for k in real)
        if not by_member.get(member) or abs(s - by_member[member]) > abs(by_member[member]) * 0.02:
            return [member]
        out: list[str] = []
        for k in real:
            out.extend(expand(k))
        return out

    # A root is a member whose parent is not itself a member -- companies
    # often nest segments under an axis label ("Operating segments") that
    # carries no value of its own.
    roots = [m for m in by_member if _member_parts(m)[1] not in by_member]
    if not roots:
        return []
    # Roots can carry subtotals too (a "Total segments" member).
    roots = [r for r in roots
             if not _subset_sums_to(
                 [by_member[o] for o in roots if o != r], by_member[r])] or roots

    # A note may cut the same revenue several ways at once -- Coca-Cola splits
    # it by operation type and by geography in one table -- which puts two
    # complete sets of roots side by side. Keep only one complete cut.
    if abs(sum(by_member[r] for r in roots) - total) > total * 0.06:
        picked = _best_subset([by_member[r] for r in roots], total)
        if picked:
            roots = [roots[i] for i in picked]

    leaves: list[str] = []
    for r in roots:
        leaves.extend(expand(r))

    # Expanding a matrix disclosure can produce repeated leaf names
    # ("United States" under two different parents); the coarser cut is
    # clearer than an ambiguous one.
    if len({_member_parts(k)[0] for k in leaves}) < len(leaves):
        leaves = roots

    covered = sum(by_member[k] for k in leaves)
    if not covered or abs(covered - total) / total > 0.06:
        # The tree did not reconcile -- fall back to the top level alone.
        leaves = roots
        covered = sum(by_member[k] for k in leaves)
        if not covered or abs(covered - total) / total > 0.06:
            return []

    # Keep the member the leaf sits under. Where a filing nests its members
    # -- "YouTube ads | Google Services" -- that parent is the company's own
    # grouping, and lets the revenue side be drawn at two levels instead of
    # flattened to one.
    rows = []
    for k in leaves:
        leaf, path = _member_parts(k)
        rows.append({
            "label": leaf,
            "parent": path.split(" | ")[0] if path else None,
            "value": by_member[k],
        })
    rows.sort(key=lambda r: -r["value"])
    residual = total - covered
    if residual > total * 0.005:
        # Revenue the segment note does not assign (hedging, corporate, etc.)
        rows.append({"label": "Other / unallocated", "parent": None,
                     "value": residual})
    return rows


def _best_subset(values: list[float], target: float,
                 tol: float = 0.002) -> list[int] | None:
    """Indices of the largest subset of `values` that adds up to `target`.

    Used to isolate one complete cut of revenue when a table lays out two.
    The tolerance is deliberately tight: with a loose one, some combination
    of unrelated lines almost always lands near the total by coincidence, and
    a wrong breakdown that happens to add up is worse than none at all. A
    genuine cut of revenue reconciles to the cent.
    """
    n = len(values)
    if n > 16:
        return None
    limit = abs(target) * tol
    best: list[int] | None = None
    for mask in range(1, 1 << n):
        picked = [i for i in range(n) if mask >> i & 1]
        if len(picked) < 2:
            continue
        if best is not None and len(picked) <= len(best):
            continue
        if abs(sum(values[i] for i in picked) - target) <= limit:
            best = picked
    return best


def _subset_sums_to(values: list[float], target: float, tol: float = 0.005) -> bool:
    """True if two or more of `values` add up to `target`."""
    if target <= 0 or len(values) < 2:
        return False
    limit = abs(target) * tol
    reach: dict[float, int] = {0.0: 0}
    for v in values:
        for s, n in list(reach.items()):
            t = s + v
            if t - target > limit:
                continue
            if n + 1 > reach.get(t, -1):
                reach[t] = n + 1
    for s, n in reach.items():
        if n >= 2 and abs(s - target) <= limit:
            return True
    return False


_SEGMENT_HINTS = re.compile(
    r"(revenue|net sales|segment|disaggregat|product|service)", re.I)
_SEGMENT_EXCLUDE = re.compile(
    r"(\(tables?\)|polic|additional information|narrative|parenthetical|"
    r"long-lived|remaining performance|unearned|changes in|rollforward|"
    r"expected timing|reconcil)", re.I)

# Reports are tried in this order; the first breakdown that reconciles to
# consolidated revenue wins the "primary" slot on the dashboard.
_SEGMENT_RANK = [
    (re.compile(r"(by reportable segment|by segment|segment revenue|"
                r"revenue by|segment information)", re.I), 0),
    (re.compile(r"(disaggregat|significant product|product and service|"
                r"by product|major product)", re.I), 1),
    (re.compile(r"(geograph|by country|major geographic)", re.I), 3),
]


def _rank_report(short: str) -> int:
    for pat, score in _SEGMENT_RANK:
        if pat.search(short):
            return score
    return 2


def segment_reports(cik: int, accession: str) -> list[tuple[str, str]]:
    """Candidate revenue-breakdown reports in one filing, best guess first."""
    acc = accession.replace("-", "")
    base = f"https://www.sec.gov/Archives/edgar/data/{cik}/{acc}"
    try:
        summary = fetch(f"{base}/FilingSummary.xml")
    except FetchError:
        return []

    reports = []
    for m in re.finditer(r"<Report[^>]*>(.*?)</Report>", summary, re.S):
        body = m.group(1)
        name = re.search(r"<ShortName>(.*?)</ShortName>", body)
        file = re.search(r"<HtmlFileName>(.*?)</HtmlFileName>", body)
        if not name or not file:
            continue
        short = name.group(1).strip()
        # "(Detail)" and "(Details)" both appear; the note bodies and the
        # policy/table variants never carry the numbers we want.
        if not re.search(r"\(Detail", short, re.I):
            continue
        if not _SEGMENT_HINTS.search(short) or _SEGMENT_EXCLUDE.search(short):
            continue
        reports.append((short, file.group(1)))

    reports.sort(key=lambda r: _rank_report(r[0]))
    return reports[:8]


def segment_observations(cik: int, accession: str) -> list[dict]:
    """All revenue-breakdown observations disclosed in one filing."""
    acc = accession.replace("-", "")
    base = f"https://www.sec.gov/Archives/edgar/data/{cik}/{acc}"
    out: list[dict] = []
    for short, fname in segment_reports(cik, accession):
        try:
            html = fetch(f"{base}/{fname}")
        except FetchError:
            continue
        for o in parse_report_table(html):
            o["source"] = short
            out.append(o)
    return out


def _clean_source_name(short: str) -> str:
    """A short, human heading for one revenue cut.

    SEC report titles are long and inconsistent ("Revenue - Disaggregated Net
    Sales and Portion of Net Sales That Was Included in Deferred Revenue"), so
    classify the cut instead. The untouched title stays available as the
    citation.
    """
    s = short.lower()
    if re.search(r"geograph|by country|major geographic", s):
        return "By geography"
    if re.search(r"product|net sales|significant product|disaggregat", s):
        return "By product & service"
    if re.search(r"segment", s):
        return "By segment"
    clean = re.sub(r"\s*\(Detail\w*\)\s*$", "", short, flags=re.I)
    clean = re.sub(r"^[^-]+-\s*", "", clean).strip() or short
    if clean.isupper():  # filings often shout their note headings
        clean = clean.title()
    return clean[:38]


def _breakdown_from(obs: list[dict], end: str, prev_end: str | None,
                    total: float) -> dict | None:
    """One report's observations, reduced to a quarterly revenue breakdown.

    A 10-Q's note carries a three-month column, so it can be read directly.
    A 10-K only shows the full year, so the fourth quarter is recovered the
    same way the income statement is: year minus nine months.
    """
    direct = [o for o in obs if o["end"] == end and o["months"] == 3]
    if direct:
        rows = reconcile_segments(direct, total)
        if rows:
            return {"rows": rows, "basis": "reported"}

    if not prev_end:
        return None

    cur, pri = {}, {}
    for o in obs:
        if o["end"] == end:
            cur.setdefault((o["member"], o["months"]), o)
        if o["end"] == prev_end:
            pri.setdefault((o["member"], o["months"]), o)
    for months in (12, 9, 6):
        a = {k[0]: v for k, v in cur.items() if k[1] == months}
        b = {k[0]: v for k, v in pri.items() if k[1] == months - 3}
        shared = set(a) & set(b)
        if len(shared) >= 2:
            diffs = [{
                "member": k,
                "metric": a[k]["metric"],
                "value": a[k]["value"] - b[k]["value"],
                "months": 3,
                "end": end,
            } for k in shared]
            rows = reconcile_segments(diffs, total)
            if rows:
                return {"rows": rows, "basis": "derived"}
    return None


def segments_for_quarter(cik: int, filings: list[dict], end: str,
                         prev_end: str | None, total: float) -> list[dict]:
    """Every revenue breakdown the filings disclose for this quarter.

    A company usually discloses more than one cut of the same revenue -- by
    business segment and by geography, sometimes by product too. Each is
    returned separately so the dashboard can offer them as alternate views;
    a cut is only included if its parts add up to consolidated revenue.
    """
    obs: list[dict] = []
    for f in filings:
        obs.extend(segment_observations(cik, f["accession"]))
    if not obs:
        return []

    by_source: dict[str, list[dict]] = {}
    for o in obs:
        by_source.setdefault(o["source"], []).append(o)

    out: list[dict] = []
    for source in sorted(by_source, key=_rank_report):
        got = _breakdown_from(by_source[source], end, prev_end, total)
        if not got:
            continue
        cut = {
            "name": _clean_source_name(source),
            "source": source,
            "basis": got["basis"],
            "rows": got["rows"],
        }
        labels = {r["label"] for r in cut["rows"]}
        # The same cut often appears in two notes at different granularity;
        # keep whichever names more of the business.
        dup = next((c for c in out
                    if c["name"] == cut["name"]
                    or {r["label"] for r in c["rows"]} == labels), None)
        if dup is None:
            out.append(cut)
        elif len(cut["rows"]) > len(dup["rows"]):
            out[out.index(dup)] = cut
    return out


# ---------------------------------------------------------------------------
# Assembling the company model
# ---------------------------------------------------------------------------

def _filing_index(cik: int) -> list[dict]:
    raw = json.loads(fetch(
        f"https://data.sec.gov/submissions/CIK{cik:010d}.json", ttl=TTL_FACTS))
    recent = raw.get("filings", {}).get("recent", {})
    out = []
    for i, form in enumerate(recent.get("form", [])):
        if form.split("/")[0] not in ("10-K", "10-Q", "20-F", "40-F"):
            continue
        out.append({
            "form": form,
            "accession": recent["accessionNumber"][i],
            "filed": recent["filingDate"][i],
            "periodEnd": recent.get("reportDate", [""] * (i + 1))[i],
        })
    out.sort(key=lambda f: f["filed"], reverse=True)
    return out, raw


def _pick(series: dict[str, dict[str, dict]], names: list[str], end: str):
    for n in names:
        hit = series.get(n, {}).get(end)
        if hit and hit["value"] is not None:
            return hit
    return None


def build_company(ticker: str, max_quarters: int = 24) -> dict:
    """The full model the dashboard renders: quarters, lines, segments."""
    meta = resolve_ticker(ticker)
    cik = meta["cik"]

    facts_raw = json.loads(fetch(
        f"https://data.sec.gov/api/xbrl/companyfacts/CIK{cik:010d}.json",
        ttl=TTL_FACTS))
    facts = facts_raw.get("facts", {})

    # us-gaap for a domestic filer, ifrs-full for a foreign private issuer.
    # The concept names differ; nothing after this point does.
    taxonomy, concepts = taxonomy_for(facts)
    fye_month = detect_fye_month(facts, taxonomy, concepts)

    filings, submissions = _filing_index(cik)

    # Every candidate tag, quarterized once.
    series: dict[str, dict[str, dict]] = {}
    for tags in concepts.values():
        for tag in tags:
            if tag not in series:
                series[tag] = quarterize(_usable_facts(facts, tag, taxonomy))

    rev_tags = concepts["revenue"]
    ends = sorted({e for t in rev_tags for e in series.get(t, {})}, reverse=True)
    ends = ends[:max_quarters]

    quarters = []
    for idx, end in enumerate(ends):
        line: dict[str, float | None] = {}
        prov: dict[str, str] = {}
        for name, tags in concepts.items():
            hit = _pick(series, tags, end)
            line[name] = hit["value"] if hit else None
            if hit:
                prov[name] = hit["basis"]

        rev = line.get("revenue")
        if rev is None:
            continue

        # Fill the lines companies commonly leave untagged.
        if line.get("grossProfit") is None and line.get("cogs") is not None:
            line["grossProfit"] = rev - line["cogs"]
            prov["grossProfit"] = "computed"
        if line.get("cogs") is None and line.get("grossProfit") is not None:
            line["cogs"] = rev - line["grossProfit"]
            prov["cogs"] = "computed"

        # Companies often tag the SG&A subtotal *and* pieces of it, which
        # would count the same dollars twice. Keep the split only when the
        # pieces actually add up to the subtotal; otherwise keep the subtotal.
        if line.get("sga") is not None:
            sm, ga, sga = line.get("sm"), line.get("ga"), line["sga"]
            parts = [v for v in (sm, ga) if v is not None]
            if parts and abs(sum(parts) - sga) <= sga * 0.02:
                line["sga"] = None
            else:
                line["sm"] = line["ga"] = None

        opex_parts = {k: line.get(k) for k in ("rd", "sm", "ga", "sga")}
        opex_sum = sum(v for v in opex_parts.values() if v is not None) or None

        # Operating expenses, most reliable source first. `OperatingExpenses`
        # is the tag when a company reports the subtotal; otherwise the
        # gross-profit-to-operating-income gap is exact by construction.
        # `CostsAndExpenses` is a last resort because it bundles cost of
        # revenue, which has to be stripped back out.
        opex = None
        if series.get("OperatingExpenses", {}).get(end):
            opex = series["OperatingExpenses"][end]["value"]
            prov["opex"] = "reported"
        elif line.get("grossProfit") is not None and line.get("operatingIncome") is not None:
            opex = line["grossProfit"] - line["operatingIncome"]
            prov["opex"] = "computed"
        elif line.get("noninterestExpense") is not None:
            opex = line["noninterestExpense"]
            prov["opex"] = "reported"
        elif series.get("CostsAndExpenses", {}).get(end):
            # Total costs less cost of sales, where cost of sales is known.
            # Where it is not, the total stands as the cost base and the
            # residual below carries the unnamed part. Requiring cogs here
            # instead meant a quarter that never tagged it fell through to the
            # sum of the named categories alone, which understates the cost
            # base by everything it does not name: McDonald's tags cost of
            # sales in its 10-Qs and never in the 10-K, so every derived Q4
            # counted only its overheads.
            opex = series["CostsAndExpenses"][end]["value"] - (line.get("cogs") or 0)
            prov["opex"] = "computed"
        elif opex_sum is not None:
            opex = opex_sum
            prov["opex"] = "computed"
        line["opex"] = opex

        # Whatever the named categories don't account for, shown as its own
        # line rather than silently dropped from the expense breakdown.
        if opex is not None:
            # A period that names no category at all still spent the money;
            # the residual is then the whole of it rather than nothing.
            residual = opex - (opex_sum or 0)
            line["opexOther"] = residual if abs(residual) > abs(opex) * 0.01 else None
        else:
            line["opexOther"] = None

        if line.get("operatingIncome") is None and line.get("grossProfit") is not None and opex:
            line["operatingIncome"] = line["grossProfit"] - opex
            prov["operatingIncome"] = "computed"

        if line.get("pretaxIncome") is None and line.get("netIncome") is not None \
                and line.get("tax") is not None:
            line["pretaxIncome"] = line["netIncome"] + line["tax"]
            prov["pretaxIncome"] = "computed"

        # A provision is only its own cost bucket if it sits outside the
        # expense lines already counted. An insurer's benefit expense is
        # inside operating expenses, so charging it again would double count;
        # a lender's credit provision is a separate charge. The filing's own
        # arithmetic settles which: subtracting it should move the running
        # total toward pre-tax income, not away from it.
        if line.get("provisions") is not None:
            base = rev - (line.get("cogs") or 0) - (opex or 0)
            target = line.get("pretaxIncome")
            p = line["provisions"]
            if target is None or abs(base - p - target) >= abs(base - target):
                line["provisions"] = None
                prov.pop("provisions", None)

        if line.get("otherIncome") is None and line.get("pretaxIncome") is not None \
                and line.get("operatingIncome") is not None:
            line["otherIncome"] = line["pretaxIncome"] - line["operatingIncome"]
            prov["otherIncome"] = "computed"

        # Free cash flow is not a GAAP line and is never tagged; it is
        # operating cash flow less what was spent on property and equipment.
        ocf, capex = line.get("operatingCashFlow"), line.get("capex")
        if ocf is not None and capex is not None:
            line["freeCashFlow"] = ocf - abs(capex)
            prov["freeCashFlow"] = "computed"
        else:
            line["freeCashFlow"] = None
        if capex is not None:
            line["capex"] = abs(capex)

        fy, fq = fiscal_label(end, fye_month)
        rev_hit = _pick(series, rev_tags, end)
        quarters.append({
            "end": end,
            "start": rev_hit.get("start") if rev_hit else None,
            "fy": fy,
            "fq": fq,
            "label": f"Q{fq} {fy}",
            "basis": rev_hit["basis"] if rev_hit else "reported",
            "form": rev_hit.get("form") if rev_hit else None,
            "accession": rev_hit.get("accn") if rev_hit else None,
            "filed": rev_hit.get("filed") if rev_hit else None,
            "lines": line,
            "provenance": prov,
            "segments": None,
        })

    # A period tagged with revenue and nothing else cannot be drawn: the
    # Sankey has a source and no destinations, and every margin is undefined.
    # Foreign filers produce these where one figure was tagged in an interim
    # release and the rest of the statement was not.
    quarters = [q for q in quarters
                if q["lines"].get("revenue") is not None
                and (q["lines"].get("netIncome") is not None
                     or q["lines"].get("operatingIncome") is not None)]

    quarters.sort(key=lambda q: q["end"], reverse=True)

    if not quarters:
        # Usually a newly formed holding company that has taken over the
        # ticker but not yet the filing history.
        raise FetchError(
            f"{meta['name']} (CIK {cik}) has no quarterly income-statement "
            f"data in SEC XBRL filings. If the company recently reorganised, "
            f"the operating company's history sits under a different CIK — "
            f"search by that CIK number.")

    return {
        "ticker": meta["ticker"],
        "name": submissions.get("name") or meta["name"],
        "cik": cik,
        "sic": submissions.get("sicDescription"),
        "exchange": (submissions.get("exchanges") or [None])[0],
        "fiscalYearEndMonth": fye_month,
        "fiscalYearEnd": submissions.get("fiscalYearEnd"),
        "quarters": quarters,
        "filings": filings[:40],
        "source": {
            "facts": f"https://data.sec.gov/api/xbrl/companyfacts/CIK{cik:010d}.json",
            "filings": f"https://www.sec.gov/cgi-bin/browse-edgar?action=getcompany&CIK={cik:010d}&type=10-&dateb=&owner=include&count=40",
        },
    }


def attach_segments(company: dict, end: str) -> list[dict]:
    """Load the revenue breakdowns for one quarter, on demand."""
    quarters = company["quarters"]
    idx = next((i for i, q in enumerate(quarters) if q["end"] == end), None)
    if idx is None:
        return []
    q = quarters[idx]
    prev_end = quarters[idx + 1]["end"] if idx + 1 < len(quarters) else None
    total = q["lines"].get("revenue")
    if not total:
        return []

    # The filing that reports this quarter, plus the one before it -- the
    # second is what makes the year-minus-nine-months subtraction possible.
    wanted = [f for f in company["filings"] if f["periodEnd"] == end]
    if prev_end:
        wanted += [f for f in company["filings"] if f["periodEnd"] == prev_end]
    if not wanted:
        return []

    return segments_for_quarter(company["cik"], wanted[:2], end, prev_end, total)
