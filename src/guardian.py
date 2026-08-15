#!/usr/bin/env python3
"""FinOps Guardian - Phase 2: burn-rate forecast from AWS Cost Explorer.
Auth: EC2 instance role (no keys on the box). Read-only.
"""
import warnings; warnings.filterwarnings("ignore")
import boto3, json, calendar
import datetime as dt
from datetime import datetime, timezone

BUDGET = 5.00  # monthly budget target (USD)

def fetch_daily(ce, start, end):
    """Return list of {date, cost}; empty if CE has no data yet."""
    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": start, "End": end},
            Granularity="DAILY",
            Metrics=["UnblendedCost"],
        )
        return [
            {"date": d["TimePeriod"]["Start"],
             "cost": round(float(d["Total"]["UnblendedCost"]["Amount"]), 4)}
            for d in resp["ResultsByTime"]
        ], True
    except ce.exceptions.DataUnavailableException:
        return [], False

def main():
    ce = boto3.client("ce", region_name="us-east-1")
    today = datetime.now(timezone.utc).date()
    first = today.replace(day=1)
    end_excl = (today + dt.timedelta(days=1)).isoformat()  # CE End is exclusive

    daily, data_ok = fetch_daily(ce, first.isoformat(), end_excl)

    mtd           = round(sum(x["cost"] for x in daily), 2)
    days_elapsed  = len(daily) if daily else today.day
    days_in_month = calendar.monthrange(today.year, today.month)[1]
    days_left     = days_in_month - today.day
    avg_daily     = mtd / days_elapsed if days_elapsed else 0
    projected     = round(mtd + avg_daily * days_left, 2)
    status        = "OVER" if projected > BUDGET else "OK"
    over_pct      = round((projected - BUDGET) / BUDGET * 100, 1) if BUDGET else 0

    line = "=" * 52
    print(line)
    print("     AWS FinOps Guardian  ::  Burn-Rate Forecast")
    print(line)
    print(f"  Month          : {today.strftime('%B %Y')}")
    print(f"  Days elapsed   : {days_elapsed} / {days_in_month}")
    print(f"  Month-to-date  : ${mtd:,.2f}")
    print(f"  Avg per day    : ${avg_daily:,.2f}")
    print(f"  Projected EOM  : ${projected:,.2f}")
    print(f"  Budget         : ${BUDGET:,.2f}")
    if status == "OK":
        print(f"  Status         : OK  (within budget)")
    else:
        print(f"  Status         : OVER by {over_pct}%  <-- ACTION NEEDED")
    if not data_ok:
        print("  Note           : Cost Explorer just enabled - data")
        print("                   still ingesting. Retry in ~24h for")
        print("                   live figures. (Engine + auth OK.)")
    print(line)

    record = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "month": today.strftime("%Y-%m"),
        "data_available": data_ok,
        "mtd_cost": mtd, "avg_daily": round(avg_daily, 2),
        "projected_eom": projected, "budget": BUDGET,
        "status": status, "over_by_pct": over_pct, "daily": daily,
    }
    with open("cost_history.json", "w") as f:
        json.dump(record, f, indent=2)
    print("  Wrote cost_history.json")

if __name__ == "__main__":
    main()