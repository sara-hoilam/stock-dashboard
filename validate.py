"""
validate.py -- accuracy checks on the extracted financials.

Run:  python validate.py [TICKER ...]

Every check is an identity that must hold in a real income statement, so a
failure means the extraction is wrong, not that the company had a bad quarter.
"""

import sys

import edgar

TICKERS = ["GOOGL", "AAPL", "MSFT", "NVDA", "WMT", "KO", "JPM", "COST", "TSLA", "UNH"]
TOL = 0.015  # 1.5% -- absorbs rounding in the filings themselves


def money(v):
    if v is None:
        return "     n/a"
    return f"{v / 1e9:8.2f}B"


def check(name, got, want, scale):
    if got is None or want is None:
        return None
    if scale and abs(got - want) / max(abs(scale), 1) > TOL:
        return f"{name}: {money(got)} vs {money(want)}"
    return None


def main(tickers):
    total_fail = 0
    no_breakdown = 0
    for t in tickers:
        print(f"\n{'=' * 78}\n{t}")
        try:
            c = edgar.build_company(t, max_quarters=9)
        except Exception as exc:
            print(f"  BUILD FAILED: {exc}")
            total_fail += 1
            continue

        print(f"  {c['name']}  CIK {c['cik']}  FY ends month {c['fiscalYearEndMonth']}"
              f"  ({len(c['quarters'])} quarters)")
        print(f"  {'period':<9}{'basis':<9}{'revenue':>10}{'gross':>10}"
              f"{'opex':>10}{'op inc':>10}{'net inc':>10}   checks")

        for q in c["quarters"][:8]:
            L = q["lines"]
            rev = L.get("revenue")
            issues = []
            issues.append(check("GP≠Rev−COGS", L.get("grossProfit"),
                                (rev - L["cogs"]) if L.get("cogs") is not None else None, rev))
            issues.append(check("OpInc≠GP−Opex", L.get("operatingIncome"),
                                (L["grossProfit"] - L["opex"])
                                if L.get("grossProfit") is not None and L.get("opex") is not None
                                else None, rev))
            issues.append(check("Pretax≠NI+Tax", L.get("pretaxIncome"),
                                (L["netIncome"] + L["tax"])
                                if L.get("netIncome") is not None and L.get("tax") is not None
                                else None, rev))
            issues = [i for i in issues if i]

            # Banks and insurers have no cost of revenue, so gross profit and
            # operating income genuinely do not exist for them. Only flag a
            # line as missing if the company reports that kind of line at all.
            reports_gross = any(
                q2["lines"].get("grossProfit") is not None for q2 in c["quarters"])
            reports_opinc = any(
                q2["lines"].get("operatingIncome") is not None for q2 in c["quarters"])
            expected = ["revenue", "netIncome"]
            if reports_gross:
                expected.append("grossProfit")
            if reports_opinc:
                expected.append("operatingIncome")
            missing = [k for k in expected if L.get(k) is None]
            flag = "OK" if not issues and not missing else "; ".join(
                issues + ([f"missing {','.join(missing)}"] if missing else []))
            if flag != "OK":
                total_fail += 1
            print(f"  {q['label']:<9}{q['basis']:<9}{money(rev)}{money(L.get('grossProfit'))}"
                  f"{money(L.get('opex'))}{money(L.get('operatingIncome'))}"
                  f"{money(L.get('netIncome'))}   {flag}")

        # Revenue breakdowns for the most recent quarter.
        if c["quarters"]:
            end = c["quarters"][0]["end"]
            cuts = edgar.attach_segments(c, end)
            rev = c["quarters"][0]["lines"]["revenue"]
            if not cuts:
                # Not every filer discloses revenue in a shape that can be
                # proved to add up -- JPMorgan and Costco are standing
                # examples. Showing nothing is the correct outcome there, so
                # this is reported but is not a failure. A breakdown that IS
                # shown and does not reconcile still is.
                print("  breakdowns: none recovered (expected for some filers)")
                no_breakdown += 1
            for cut in cuts:
                s = sum(r["value"] for r in cut["rows"])
                ok = abs(s - rev) / rev <= 0.02
                if not ok:
                    total_fail += 1
                print(f"  [{cut['name'][:44]}] ({cut['basis']}) "
                      f"sum {money(s)} vs revenue {money(rev)} "
                      f"{'OK' if ok else 'MISMATCH'}")
                for r in cut["rows"]:
                    print(f"      {r['label'][:46]:<48}{money(r['value'])}"
                          f"  {r['value'] / rev * 100:5.1f}%")

    print(f"\n{'=' * 78}")
    print(f"{total_fail} problem(s)" + (
        f"  ({no_breakdown} with no reconcilable breakdown, which is expected)"
        if no_breakdown else ""))
    return total_fail


if __name__ == "__main__":
    sys.exit(1 if main(sys.argv[1:] or TICKERS) else 0)
