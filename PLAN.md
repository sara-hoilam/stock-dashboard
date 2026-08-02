# Plan — hosting Ledger as a live web dashboard

How the local tool becomes a service that many people can use, and stays current
with every filer without anyone pressing refresh.

Everything below stays on the same sources it uses today: SEC EDGAR, and
nothing else. No LLM is involved at runtime, so there is no token cost — the
running cost is a server and a database.

---

## 1. The problem hosting creates

The local tool queries the SEC on demand. Measured cold, one company costs
**8 requests and ~6 seconds**. That is fine for one person and wrong for a
website, for one reason:

> **SEC's rate limit is per IP, not per user.** On a server, all visitors share
> one 10 requests/second budget. Ten people opening ten different tickers is
> ~80 SEC requests in a few seconds, and the SEC starts refusing.

So the fix is not a bigger server. It is to **take the SEC out of the request
path**: parse each filing once, store the result, and serve everyone from the
store. A filing never changes after it is filed, so it never needs parsing
twice.

---

## 2. How it learns that a filing exists

Three mechanisms, each verified working:

| Tier | Endpoint | Freshness | Use |
|---|---|---|---|
| **Firehose** | `Archives/edgar/daily-index/{yyyy}/QTR{n}/form.{yyyymmdd}.idx` | once a day | complete, canonical record of every filing |
| **Near real time** | `cgi-bin/browse-edgar?action=getcurrent&type=10-Q&output=atom` | minutes | same-day freshness on results day |
| **On demand** | `data.sec.gov/submissions/CIK{cik}.json` | live | authoritative filing list for one company |

Measured on Friday 31 July 2026: the daily index is **1.1 MB**, lists **5,772
filings**, of which **181 are 10-Q or 10-K**. Across a quarter that is roughly
**11,400 periodic filings** — a completely tractable amount to ingest.

**Scheduled ingestion** reads the daily index each evening, filters to
10-Q/10-K/20-F/40-F, and enqueues anything whose accession is not already in the
database. During earnings season, the atom feed can be polled every ten minutes
so a filing appears the same afternoon.

**One caveat to design around:** a filing appearing in the index does not mean
the XBRL company-facts API has caught up with it. The worker must treat "facts
not there yet" as a retry, not a failure — enqueue with backoff and try again
rather than recording an empty quarter.

---

## 3. What happens when someone searches

This is the flow the question is really about.

```
user types "coin"
   └─► GET /api/search            ← database only, no SEC call, ~5 ms
user picks COIN
   └─► GET /api/company?ticker=COIN
         ├─ in DB and checked < 6h ago ──────────────► serve from DB (~10 ms)
         └─ otherwise
              └─ GET submissions/CIK0001679788.json   (1 request, ~200 ms)
                   ├─ newest accession already parsed ─► serve from DB, stamp checked_at
                   └─ new accession found ────────────► enqueue parse job
                                                        serve what we have,
                                                        mark "updating",
                                                        push the new quarter
                                                        when it lands
```

Two rules make this cheap and correct:

- **Search never touches the SEC.** The ticker directory
  (`sec.gov/files/company_tickers.json`, ~10,000 companies) is refreshed once a
  day into the database and served from a prefix index.
- **A company is only checked against the SEC once every 6 hours**, and only
  when someone actually asks for it. The check is a single request that returns
  the filing list; the expensive parsing only runs when that list contains
  something new.

For a company nobody has ever opened, the first visitor waits for a real parse.
That is the only slow path, it happens once per filing, and the scheduled
ingestion means it rarely happens at all for companies people care about.

---

## 4. Shape of the system

```
                    SEC EDGAR
                        │
   daily index ─┐       │       ┌─ submissions (freshness check)
   atom feed  ──┼───────┴───────┤
                │               └─ companyfacts + filing R-files (parse)
                ▼
        ┌───────────────┐   one process, one rate limiter,
        │ ingest worker │   never more than ~8 req/s in total
        └───────┬───────┘
                ▼
        ┌───────────────┐
        │   Postgres    │  companies · filings · quarters · breakdowns
        └───────┬───────┘
                ▼
        ┌───────────────┐
        │  API service  │  /api/search  /api/company  /api/segments
        └───────┬───────┘
                ▼
          dashboard.html      (unchanged — it already speaks this API)
```

**The single rate limiter is the important bit.** Every SEC request in the
system goes through the ingest worker, which is the only component allowed to
talk to `sec.gov`. The API service never does. That keeps the whole service
inside the SEC's fair-access policy no matter how many visitors arrive.

### Schema

```sql
company    (cik pk, ticker, name, sic, exchange, fye_month, checked_at)
filing     (accession pk, cik, form, filed_date, period_end,
            status, parsed_at, error)          -- status: pending|ok|failed
quarter    (cik, period_end pk, fy, fq, start_date, basis,
            source_accession, lines jsonb, provenance jsonb)
breakdown  (cik, period_end, name, source, basis, rows jsonb)
```

`lines` and `rows` stay as JSON because the shape is already settled by
`edgar.py` and nothing queries inside them. `filing.status` is what makes the
pipeline honest: a filing that fails to parse is recorded as failed and shows
as "no breakdown available", never as a guess.

Sizing: ~10,000 companies × 24 quarters × a few KB ≈ **under 1 GB**. Any small
managed Postgres covers it.

### What moves, what doesn't

| Component | Change |
|---|---|
| `edgar.py` | unchanged — it already does fetch, normalise, derive, parse |
| `server.py` | becomes two pieces: the API service and the ingest worker |
| `dashboard.html` | unchanged — same three endpoints |
| `validate.py` | moves into CI, run nightly over a sample of filers |

---

## 5. Delivery order

**Phase 1 — make it hostable.** Postgres, ingest worker with the shared rate
limiter, on-demand backfill, API reads from DB. Deploy the API and the static
page. At this point it is a real website: fast, multi-user, and current for any
company someone opens.

**Phase 2 — proactive freshness.** Daily-index cron so the database is ahead of
visitors rather than behind them. Add a "new filing" indicator and an *as of*
line showing the newest filing known and when the company was last checked.

**Phase 3 — close the earnings-release gap.** Parse 8-K Item 2.02 exhibits so
the ~2–6 week window between a results announcement and the 10-Q is covered.
These must be **stored and labelled separately** from 10-Q data — the exhibits
are not XBRL-tagged, so they are HTML parsing and genuinely less reliable.
Never blend them into the same series without saying so.

**Phase 4 — same-day.** Poll the atom feed every ten minutes during earnings
season.

---

## 6. Costs

| Item | Cost |
|---|---|
| LLM / tokens | **none** — no model runs at any point |
| SEC data | free, public domain |
| Small VM or container | roughly $5–20/month |
| Managed Postgres | free tier is enough to start |
| Bandwidth | small; company facts are fetched once per filing, not per visitor |

The only meaningful cost is the server. There is no per-query or per-user
charge anywhere in the design.

---

## 7. Deploying on Supabase + Render + Cloudflare + GitHub

Short verdict: **this stack is a good fit, and cheaper than expected — because
the data is far smaller than the raw filings are.**

### The number that decides the architecture

Measured on real companies: a full 24-quarter history is **~31 KB** of income
statement plus **~13 KB** of segment breakdowns.

| Coverage | Stored size |
|---|---|
| S&P 500 | **~23 MB** |
| 3,000 companies | ~136 MB |
| Every one of the ~10,000 filers | **~454 MB** |

The entire US public market fits inside Supabase's free tier. That is only true
because of one rule: **parse once, store the result, throw the raw filing
away.** The local `.cache/` is already 138 MB for forty companies; none of that
needs to persist once the numbers are extracted.

### What goes where

| Piece | Where | Why |
|---|---|---|
| `dashboard.html` | **Cloudflare Pages** | static, free, global CDN, deploys from GitHub |
| Postgres + read API | **Supabase** | PostgREST removes the API tier entirely |
| SEC ingest (`edgar.py`) | **Render** | the one job that needs a long-lived process and a stable IP |
| CI + deploys | **GitHub Actions** | runs `validate.py`; both Render and Pages deploy on push |

### Why the ingest must be on Render, not Workers or Edge Functions

This is the one place where the serverless parts of the stack are the wrong
tool, for three concrete reasons:

1. **The SEC rate limit is per IP.** Cloudflare Workers and Supabase Edge
   Functions run distributed with rotating egress addresses, so there is no
   single place to enforce 10 req/s. You would need Durable Objects to fake it.
   A single Render process is a rate limiter by construction.
2. **`edgar.py` is Python.** Edge Functions are Deno/TypeScript. Porting it
   means re-litigating every parsing bug this project already found — Micron's
   unbracketed headers, Coca-Cola's matrix disclosure, UNH's negative
   eliminations, Coinbase's flat hierarchy.
3. **Backfills are long.** Seeding the market runs for hours; serverless
   platforms cap execution time.

Everything *else* should be serverless. Only the SEC-facing worker needs a box.

### Dropping the API tier

`server.py`'s three endpoints can become three Postgres functions, exposed by
PostgREST with no service to run or pay for:

```sql
create function search_companies(q text) returns jsonb ...
create function get_company(p_ticker text) returns jsonb ...
create function get_segments(p_ticker text, p_end date) returns jsonb ...
```

The frontend change is small — point `fetch` at
`/rest/v1/rpc/get_company` with the anon key, keep the response shapes
identical. Anon role gets `execute` on the three functions and nothing else;
RLS denies direct table access.

### On-demand backfill without a live API

When someone opens a company the database has never seen:

```
frontend  → insert into backfill_request(ticker)      (RLS: anon insert only,
                                                       ticker must exist in
                                                       company_directory)
worker    → polls the queue every ~20s, fetches, parses, upserts
frontend  → Supabase Realtime subscription on `quarter` fires, UI fills in
```

Realtime is what makes this feel live without polling from the browser.

### Cost, honestly

Verify current tiers before committing — these move.

| Setup | Roughly | What you give up |
|---|---|---|
| GitHub Actions daily ingest + Supabase free + CF Pages | **$0** | shared/rotating runner IPs the SEC may throttle; backfill waits for the next scheduled run |
| Add one small Render cron job or worker | **~$7/mo** | nothing meaningful — this is the recommended floor |
| Add Supabase Pro | **~$32/mo** | only needed past ~450 MB, or for backups and no-pause guarantees |

Two notes on free tiers that matter here:

- **Render free instances sleep.** A sleeping ingester misses filings. The
  worker is the one thing worth paying for.
- **Supabase free projects pause after inactivity** — but a daily ingest write
  keeps the project active, so the cron doubles as a keepalive.

### Optimizations worth taking

1. **Seed selectively.** Ingest the S&P 500 first (~23 MB, a few hours at
   8 req/s) and let everything else arrive through the backfill queue. Most
   tickers will never be opened.
2. **Cache reads at Cloudflare.** A company's data changes only when it files.
   Put Cloudflare in front of the Supabase RPC endpoints with a long TTL and
   purge the affected ticker when the worker writes. Reads then cost
   essentially nothing and Supabase egress stays near zero.
3. **Run `validate.py` in CI.** A nightly GitHub Action over a sample of filers
   is the accuracy guardrail — it is what caught the identity and balance bugs
   during development, and it matters more at market scale than it did here.
4. **Never store raw filings.** No R2 bucket, no Render persistent disk. If a
   parse needs redoing, refetch from the SEC.

### Keep one invariant

If the API and the worker ever end up in the same Render service, **do not
scale it past one instance.** The rate limiter lives in process; two instances
means two limiters and double the request rate to the SEC. Splitting the worker
out is what makes the read path horizontally scalable — which is another reason
to put reads on Supabase rather than on Render.

---

## 8. Risks, honestly

- **Fair access.** The SEC blocks IPs that ignore the limits. The single-worker
  rate limiter and a declared `User-Agent` are not optional. Budget for a
  backoff-and-retry path when they throttle anyway.
- **Breakdown parsing is the fragile part.** Segment tables are rendered
  inconsistently between filers — flat member lists, unbracketed structural
  rows, matrix disclosures, gross-versus-net eliminations. Every one of those
  has already cost a bug in this project. Across the whole market a real
  fraction will not reconcile. The design must keep failing loudly into
  `filing.status` and showing nothing, rather than showing something that adds
  up by coincidence.
- **Company-facts lag.** Retry rather than record an empty quarter.
- **Not investment advice.** Worth stating on a public page.
