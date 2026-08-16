#!/usr/bin/env python3
"""FinOps Guardian - Phases 2+3: burn-rate forecast + waste detection.
Auth: EC2 instance role (no keys on the box). Read-only.
"""
import warnings; warnings.filterwarnings("ignore")
import boto3, json, calendar
import datetime as dt
from datetime import datetime, timezone

BUDGET = 5.00
IDLE_CPU_PCT = 5.0
IDLE_LOOKBACK_HRS = 24
SELF_NAME = "finops-guardian"

EC2_HOURLY = {"t2.micro":0.0116,"t3.micro":0.0104,"t2.small":0.023,
              "t3.small":0.0208,"t2.medium":0.0464,"t3.medium":0.0416}
EBS_GB_MO = {"gp3":0.08,"gp2":0.10,"io1":0.125,"io2":0.125,
             "st1":0.045,"sc1":0.015,"standard":0.05}
EIP_MO = 3.65

def name_of(inst):
    for t in inst.get("Tags", []):
        if t["Key"] == "Name":
            return t["Value"]
    return ""

def forecast(ce):
    today = datetime.now(timezone.utc).date()
    first = today.replace(day=1)
    end = (today + dt.timedelta(days=1)).isoformat()
    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": first.isoformat(), "End": end},
            Granularity="DAILY", Metrics=["UnblendedCost"])
        daily = [round(float(d["Total"]["UnblendedCost"]["Amount"]), 4)
                 for d in resp["ResultsByTime"]]
        data_ok = True
    except ce.exceptions.DataUnavailableException:
        daily, data_ok = [], False
    mtd = round(sum(daily), 2)
    dim = calendar.monthrange(today.year, today.month)[1]
    elapsed = len(daily) if daily else today.day
    left = dim - today.day
    avg = mtd / elapsed if elapsed else 0
    proj = round(mtd + avg * left, 2)
    return {"mtd": mtd, "avg_daily": round(avg, 2), "projected_eom": proj,
            "budget": BUDGET, "status": "OVER" if proj > BUDGET else "OK",
            "days": f"{elapsed}/{dim}", "data_ok": data_ok}

def idle_instances(ec2, cw):
    out = []
    now = datetime.now(timezone.utc)
    start = now - dt.timedelta(hours=IDLE_LOOKBACK_HRS)
    r = ec2.describe_instances(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}])
    for res in r["Reservations"]:
        for inst in res["Instances"]:
            if name_of(inst) == SELF_NAME:
                continue
            iid, itype = inst["InstanceId"], inst["InstanceType"]
            m = cw.get_metric_statistics(
                Namespace="AWS/EC2", MetricName="CPUUtilization",
                Dimensions=[{"Name": "InstanceId", "Value": iid}],
                StartTime=start, EndTime=now, Period=3600, Statistics=["Average"])
            pts = m["Datapoints"]
            if not pts:
                continue
            avg = sum(p["Average"] for p in pts) / len(pts)
            if avg < IDLE_CPU_PCT:
                est = round(EC2_HOURLY.get(itype, 0.012) * 730, 2)
                out.append({"type": "idle_ec2", "resource": iid,
                            "detail": f"{itype}, avg CPU {avg:.1f}%",
                            "est_monthly_usd": est, "action": "Stop or downsize"})
    return out

def orphan_volumes(ec2):
    out = []
    r = ec2.describe_volumes(Filters=[{"Name": "status", "Values": ["available"]}])
    for v in r["Volumes"]:
        est = round(EBS_GB_MO.get(v["VolumeType"], 0.10) * v["Size"], 2)
        out.append({"type": "unattached_ebs", "resource": v["VolumeId"],
                    "detail": f"{v['Size']} GiB {v['VolumeType']}, unattached",
                    "est_monthly_usd": est, "action": "Delete or snapshot"})
    return out

def unused_ips(ec2):
    out = []
    for a in ec2.describe_addresses()["Addresses"]:
        if not a.get("AssociationId"):
            out.append({"type": "unused_eip", "resource": a.get("PublicIp", "?"),
                        "detail": "Elastic IP not associated",
                        "est_monthly_usd": EIP_MO, "action": "Release"})
    return out

def main():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    cw  = boto3.client("cloudwatch", region_name="us-east-1")
    ce  = boto3.client("ce", region_name="us-east-1")

    fc = forecast(ce)
    waste = idle_instances(ec2, cw) + orphan_volumes(ec2) + unused_ips(ec2)
    total = round(sum(w["est_monthly_usd"] for w in waste), 2)
    health = max(0, 100 - len(waste) * 5 - (15 if fc["status"] == "OVER" else 0))

    L = "=" * 60
    print(L)
    print("         AWS FinOps Guardian  ::  Cost + Waste Report")
    print(L)
    print(f"  Forecast   MTD ${fc['mtd']:.2f}   EOM ${fc['projected_eom']:.2f}"
          f"   Budget ${fc['budget']:.2f}   [{fc['status']}]")
    print(f"  Days       {fc['days']}")
    print(L)
    if waste:
        print(f"  WASTE FOUND: {len(waste)} item(s)  ->  ${total:.2f}/mo on the floor")
        print("-" * 60)
        for w in waste:
            print(f"  [{w['type']:<14}] {w['resource']}")
            print(f"       {w['detail']}")
            print(f"       ~${w['est_monthly_usd']:.2f}/mo   action: {w['action']}")
    else:
        print("  WASTE FOUND: none  ->  $0.00/mo.  Clean account.")
    print(L)
    print(f"  Health score: {health}/100")
    print(L)

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "forecast": fc, "waste": waste,
        "waste_monthly_usd": total, "health_score": health,
    }
    with open("report.json", "w") as f:
        json.dump(report, f, indent=2)
    print("  Wrote report.json")

if __name__ == "__main__":
    main()