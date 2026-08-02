# Alpha Ticker — quarterly financials dashboard

Search any SEC-registered company, pick a quarter, and read its income
statement as charts. Every figure comes from the company's own filings with the
U.S. Securities and Exchange Commission. Nothing is estimated and no
third-party data provider is involved.

![charts](https://img.shields.io/badge/source-SEC%20EDGAR-1e4fbf)

## Run it

```bash
python server.py
```

Then open <http://localhost:8787>. Python 3.9+ is all you need — the server
uses only the standard library, and there is nothing to install.

Set a contact address first so the SEC can identify the requests (they ask for
this, and may throttle traffic that doesn't provide one):

```bash
SEC_CONTACT="you@example.com" python server.py
```

On Windows PowerShell:

```bash
$env:SEC_CONTACT="you@example.com"; python server.py
```

## Why a server and not just an HTML file

`data.sec.gov` sends no CORS headers, so a page opened from your filesystem
cannot fetch from it — the browser blocks the request before it is sent. The
server is a thin local proxy: it serves the dashboard, forwards requests to the
SEC with the required `User-Agent`, keeps under their 10 requests/second limit,
and caches everything to disk in `.cache/`.

## What it shows

Pick a company and a quarter, and you get:

- **Six headline figures** — revenue, gross profit, operating income, net
  income, diluted EPS and operating expenses, each against the same quarter a
  year earlier.
- **A flow diagram of the quarter** — every dollar of revenue followed left to
  right as it splits into costs and what survives as profit, starting from the
  business segments that produced it. Where a filing nests its members —
  Alphabet reports "YouTube ads" inside "Google Services" — the revenue side is
  drawn at both levels. Filings that list their segments flat get one level,
  because inventing a grouping would be inventing data.

  Every width is a filed figure and every node balances: what flows in equals
  what flows out, including the awkward cases — a tax credit rather than a
  charge, the minority's share of a partly-owned subsidiary, and intersegment
  eliminations where segment revenue is reported gross.
- **A revenue breakdown** — by segment, by product, or by geography, with a
  toggle when the company discloses more than one cut.
- **Twelve quarters of history** — revenue, the three margins, and the cost and
  expense structure as a share of revenue.
- **The income statement** as a table, with year-over-year and
  quarter-over-quarter change.
- **A chart builder** — described below.

Hovering any quarterly mark — a bar, a point, a stacked segment — shows the
amount together with its **QoQ** and **YoY** change and whether the quarter was
filed or derived.

## The chart builder

At the bottom of the page is a panel for plotting anything in the model.

- The y-axis list only ever offers **fields this company actually reports** —
  15 for JPMorgan, 22 for Apple. A chart cannot be built from data that is not
  in the filings.
- Click any field to add or remove it from the y axis, up to four at once. The
  x axis is the fiscal quarter — the only axis this data has.
- Values can be shown as filed, as a share of revenue, or as change against the
  prior quarter or the year-ago quarter. Bars can be grouped or stacked, and
  there are line and area forms.

Cash flow lines are among the fields, so selecting free cash flow and capital
expenditure as stacked bars gives a cash flow chart. Free cash flow is the one
figure here no company files — it is operating cash flow less capital
expenditure, and is marked as computed.

## Where the numbers come from

| What | Source |
|---|---|
| Ticker → CIK | `sec.gov/files/company_tickers.json` |
| Income statement | `data.sec.gov/api/xbrl/companyfacts/` |
| Filing index | `data.sec.gov/submissions/` |
| Revenue breakdown | the filed 10-Q/10-K's own financial report tables |

Company facts carry no dimensional detail, so segment revenue is read from the
filing itself — the same tables the SEC's own filing viewer renders. Filings
label the structural rows of those tables inconsistently: some bracket them
(`Segment Reporting [Line Items]`), some print them as ordinary text
(`Disaggregation of revenue`). A heading is told apart from a segment by
recurrence — a segment is named once, a heading repeats above every block.

Free cash flow is the one figure here that no company files: it is operating
cash flow less capital expenditure, and is marked as computed.

### Quarterly figures

Companies file three-month columns in their 10-Qs, and those are used exactly
as reported. **No company reports a fourth quarter on its own**: the 10-K shows
the full year. Q4 is therefore calculated as the annual figure minus the first
nine months, and the dashboard labels those quarters `derived from the 10-K`.
The same subtraction recovers Q4 segment revenue.

Fiscal calendars are handled per company, so Apple's quarter ending in December
is correctly labelled Q1 of the following fiscal year.

### Lines that companies don't tag

Not every line is tagged in XBRL. Gross profit, operating expenses and pre-tax
income are computed from the lines around them when missing, and the table
marks those `derived`. Where a company tags both an SG&A subtotal and its
components, only one is kept, so nothing is counted twice.

### Margins that look impossible

Net margin can approach or exceed 100% without anything being wrong. Net income
sits below *other income (expense), net* — gains on investments, and other
items outside the business's operations — so a large one-off gain lands in net
income without passing through revenue. Alphabet's June 2026 quarter reports
$119.8B of revenue and $112.2B of net income, a 94% net margin, because other
income that quarter was $98.0B against $40.8B of operating income. Operating
margin was 34%.

Where non-operating items exceed a quarter of pre-tax income, the net income
tile says so, and the flow diagram draws the non-operating amount as its own
inflow so it is visible rather than implied.

### Quarters that look like they are in the future

Fiscal years rarely match the calendar. Microsoft's year ends in June, so its
Q4 FY2026 is the April–June 2026 quarter — reported in a 10-K filed at the end
of July 2026, not a forecast. Every period states the form it came from and the
date that form was filed, so a quarter can always be traced to a document that
already exists.

### Loss-making quarters

A loss cannot be drawn as revenue dividing into profit — the costs are bigger
than the revenue, and the widths would not add up. Those quarters are drawn as
sources and uses instead: revenue, plus the loss itself and any tax benefit,
are what covered the quarter's costs, and the subtitle says so. Every width is
still a filed figure.

### Why some companies show less revenue detail than others

The breakdown is only as granular as the filing's own table, and companies
render those tables differently. Alphabet nests its members, so the chart shows
Search, YouTube, Network and subscriptions inside Google Services. Coinbase
lists transaction and subscription revenue and their components as a flat list
with no parent shown, and one component of the group is reported outside the
member list entirely — so the parts cannot be proven to add up to the whole,
and only the level that does reconcile ("Net revenue" and "Other revenue") is
shown.

That is deliberate. The alternative is to guess the hierarchy from the numbers,
and with a loose enough tolerance some combination of unrelated lines almost
always lands near the total by coincidence. A breakdown that adds up but is
wrong is worse than a coarse one that is right.

### Companies without a gross profit

Banks and insurers have no cost of revenue, so gross profit and operating
income genuinely do not exist for them — they are not missing data. Rather than
leave those tiles empty, the headline row substitutes what the company does
report: pre-tax income, non-interest expense and credit provisions. The flow
diagram splits revenue into non-interest expense, provisions and pre-tax
income, which is exactly how a bank's income statement works — for JPMorgan
those three reconcile to revenue to the dollar. Anything still untagged is
shown as its own "other costs & expenses" line rather than quietly dropped.

A credit provision is only charged as its own cost when it sits **outside** the
expense lines already counted. An insurer's policyholder benefits are inside
operating expenses, so counting them again would double the cost bar; a
lender's provision is a separate charge. The filing's own arithmetic decides
which — subtracting the provision has to move the running total toward pre-tax
income, not away from it.

### When a breakdown isn't shown

A revenue breakdown is only displayed if its parts add up to consolidated
revenue within 2%. Some companies disclose revenue in a shape this cannot
resolve — a matrix of segment × type, or a note the renderer lays out
unusually. In those cases the panel says so instead of showing an
approximation. Of the twelve large-caps used as tests, ten produce a
breakdown; JPMorgan and Costco do not.

## Checking the numbers

```bash
python validate.py
```

This rebuilds a set of companies and asserts the identities that must hold in a
real income statement — gross profit equals revenue minus cost of revenue,
operating income equals gross profit minus operating expenses, pre-tax equals
net plus tax — and confirms each revenue breakdown reconciles to total revenue.
Pass your own tickers as arguments:

```bash
python validate.py NFLX SBUX ORCL
```

Spot-checks against the filings: Alphabet's Q4 2025, which is derived rather
than filed, comes out at $113.8B revenue, $68.1B gross profit, $35.9B operating
income and $34.5B net income — matching the 10-K.

## Files

| File | Purpose |
|---|---|
| `server.py` | Local web server and SEC proxy |
| `edgar.py` | Fetching, XBRL normalisation, quarter derivation, segment parsing |
| `dashboard.html` | The interface — self-contained, no build step |
| `validate.py` | Accuracy checks |
| `.cache/` | Cached SEC responses (safe to delete) |

## Notes

- Cached company facts expire after 6 hours. After a new filing lands, delete
  `.cache/` to pick it up immediately.
- The first load of a company takes a few seconds — its filing tables are being
  read. Afterwards it is instant.
- Charts use a categorical palette checked for colour-vision deficiency
  separation and contrast; every slice and segment is also directly labelled,
  so colour is never the only thing distinguishing two series.

## Limits

- U.S. filers only. Foreign issuers filing 20-F/40-F are partially supported;
  those on IFRS taxonomies will show little.
- After a reorganisation, a ticker can point at a newly formed holding company
  that has no filing history yet — Exxon's XOM is currently one. The search box
  also accepts a **CIK number**, which reaches the operating company (Exxon's
  is `34088`).
- This is a reading tool for filed statements, not investment advice.
