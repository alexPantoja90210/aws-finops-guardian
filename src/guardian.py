#!/usr/bin/env python3
"""FinOps Guardian - burn-rate forecast + waste detection.

Auth: EC2 instance role (no keys on the box). Read-only.

Two rules run through this module, both learned from defects recorded against
it on 29 September 2026 as IA-199 to IA-206.

**Measure the thing you claim to measure.** The forecast asks Cost Explorer
for GROSS consumption, because credits absorb spend on this account and the
net view reports approximately nothing while the balance burns. The budget
limit is read from the budget, not restated here.

**Refuse rather than guess, and say which happened.** A missing number is not
a zero. When the cost data cannot be read, or the budget limit cannot be
read, or the machine cannot establish which instance it is, this module
returns UNKNOWN and says so, instead of computing a reassuring answer out of
an absence.
"""
import warnings; warnings.filterwarnings("ignore")
import calendar
import json
import re
import urllib.error
import urllib.request
import datetime as dt
from datetime import datetime, timezone

import boto3

IDLE_CPU_PCT = 5.0
IDLE_LOOKBACK_HRS = 24

# A volume attached to an instance stopped for longer than this is billing for
# nothing. Seven days rather than one, so a machine stopped over a weekend or
# during a deploy is not reported as waste.
STOPPED_DAYS = 7

# The tag Terraform writes on everything it manages. A resource in the account
# without it was created by something that is not the plan. See IA-199.
MANAGED_BY_TAG = "ManagedBy"
MANAGED_BY_VALUE = "terraform"

# Must match aws_budgets_budget.zero_spend, which Terraform names
# "${var.project_name}-zero-spend". This couples the budget's NAME across two
# files, which is weaker than the defect in IA-203 (which duplicated its
# VALUE) but is still a coupling. If the name drifts, the lookup below finds
# nothing and the report says UNKNOWN and lists the names it did see, rather
# than falling back to a number.
BUDGET_NAME = "finops-guardian-zero-spend"

# Credits and refunds are excluded so the figure is gross consumption. Under
# the AWS Free Plan credits absorb usage, so the net view reports nothing
# while the balance burns. This mirrors cost_types.include_credit = false on
# the Terraform budget, and the two must agree or the Guardian and AWS will
# give opposite verdicts on the same month. See IA-202.
GROSS_ONLY = {"Not": {"Dimensions": {"Key": "RECORD_TYPE",
                                     "Values": ["Credit", "Refund"]}}}
COST_VIEW = "gross (RECORD_TYPE Credit and Refund excluded)"

IMDS = "http://169.254.169.254"

EC2_HOURLY = {"t2.micro":0.0116,"t3.micro":0.0104,"t2.small":0.023,
              "t3.small":0.0208,"t2.medium":0.0464,"t3.medium":0.0416}
EBS_GB_MO = {"gp3":0.08,"gp2":0.10,"io1":0.125,"io2":0.125,
             "st1":0.045,"sc1":0.015,"standard":0.05}
EIP_MO = 3.65


# --------------------------------------------------------------------------
# Identity. Who am I, and whose account is this.
# --------------------------------------------------------------------------

def instance_identity(timeout=1.0):
    """The instance id and account id, read from the machine over IMDSv2.

    Returns (instance_id, account_id), either of which may be None.

    An identity read from the machine is the machine. An identity in a
    constant is a claim about the machine, and IA-201 is what happens when
    that claim goes stale.

    Off the box this fails, and returning None is the correct answer: a
    process that cannot establish which instance it is must not guess, and
    every caller here treats None as "exclude nothing" or "no verdict".
    """
    try:
        req = urllib.request.Request(
            f"{IMDS}/latest/api/token", method="PUT",
            headers={"X-aws-ec2-metadata-token-ttl-seconds": "60"})
        token = urllib.request.urlopen(req, timeout=timeout).read().decode()
        req = urllib.request.Request(
            f"{IMDS}/latest/dynamic/instance-identity/document",
            headers={"X-aws-ec2-metadata-token": token})
        doc = json.loads(urllib.request.urlopen(req, timeout=timeout).read())
        return doc.get("instanceId"), doc.get("accountId")
    except (urllib.error.URLError, OSError, ValueError, TimeoutError):
        return None, None


def name_of(inst):
    for t in inst.get("Tags", []):
        if t["Key"] == "Name":
            return t["Value"]
    return ""


def _is_managed(entity):
    return any(t.get("Key") == MANAGED_BY_TAG and t.get("Value") == MANAGED_BY_VALUE
               for t in entity.get("Tags", []))


# --------------------------------------------------------------------------
# Forecast
# --------------------------------------------------------------------------

def budget_limit(budgets, account_id=None, name=BUDGET_NAME):
    """The monthly limit, read from the budget itself.

    Returns (limit, note). limit is None when it could not be read, and note
    says why in words a reader can act on. Never a default.
    """
    if budgets is None:
        return None, "no Budgets client was supplied"
    try:
        found = budgets.describe_budgets(AccountId=account_id)["Budgets"]
    except Exception as exc:
        return None, f"the budget could not be read: {type(exc).__name__}: {exc}"
    for b in found:
        if b.get("BudgetName") == name:
            return float(b["BudgetLimit"]["Amount"]), ""
    seen = ", ".join(sorted(b.get("BudgetName", "?") for b in found)) or "none"
    return None, (f"no budget named {name!r} exists in this account. "
                  f"Budgets present: {seen}")


def forecast(ce, budgets=None, account_id=None):
    today = datetime.now(timezone.utc).date()
    first = today.replace(day=1)
    end = (today + dt.timedelta(days=1)).isoformat()
    note = ""
    try:
        resp = ce.get_cost_and_usage(
            TimePeriod={"Start": first.isoformat(), "End": end},
            Granularity="DAILY", Metrics=["UnblendedCost"], Filter=GROSS_ONLY)
        daily = [round(float(d["Total"]["UnblendedCost"]["Amount"]), 4)
                 for d in resp["ResultsByTime"]]
        data_ok = True
    except ce.exceptions.DataUnavailableException as exc:
        daily, data_ok = [], False
        note = f"Cost Explorer returned no data: {exc}"

    mtd = round(sum(daily), 2)
    dim = calendar.monthrange(today.year, today.month)[1]
    elapsed = len(daily) if daily else today.day
    left = dim - today.day
    avg = mtd / elapsed if elapsed else 0
    proj = round(mtd + avg * left, 2)

    limit, limit_note = budget_limit(budgets, account_id)

    # A verdict is only possible when both the spend and the threshold are
    # known. Anything else is UNKNOWN, with the reason attached. IA-203 and
    # IA-206: an absence must not be rendered as a zero and an OK.
    if not data_ok:
        status = "UNKNOWN"
    elif limit is None:
        status = "UNKNOWN"
        note = (note + " " if note else "") + limit_note
    else:
        status = "OVER" if proj > limit else "OK"

    return {"mtd": mtd, "avg_daily": round(avg, 2), "projected_eom": proj,
            "budget": limit, "status": status, "cost_view": COST_VIEW,
            "days": f"{elapsed}/{dim}", "data_ok": data_ok,
            "note": note.strip()}


# --------------------------------------------------------------------------
# Waste
# --------------------------------------------------------------------------

def idle_instances(ec2, cw, self_instance_id=None):
    """Running instances below the CPU threshold.

    self_instance_id excludes this machine by identity. When it is None
    nothing is excluded, because a process that does not know which instance
    it is must not guess which one to hide. See IA-201.
    """
    out = []
    now = datetime.now(timezone.utc)
    start = now - dt.timedelta(hours=IDLE_LOOKBACK_HRS)
    r = ec2.describe_instances(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}])
    for res in r["Reservations"]:
        for inst in res["Instances"]:
            iid, itype = inst["InstanceId"], inst["InstanceType"]
            if self_instance_id is not None and iid == self_instance_id:
                continue
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
    """Volumes attached to nothing at all."""
    out = []
    r = ec2.describe_volumes(Filters=[{"Name": "status", "Values": ["available"]}])
    for v in r["Volumes"]:
        est = round(EBS_GB_MO.get(v["VolumeType"], 0.10) * v["Size"], 2)
        out.append({"type": "unattached_ebs", "resource": v["VolumeId"],
                    "detail": f"{v['Size']} GiB {v['VolumeType']}, unattached",
                    "est_monthly_usd": est, "action": "Delete or snapshot"})
    return out


_STOPPED_AT = re.compile(r"\((\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) GMT\)")


def _stopped_since(inst):
    """When the instance was stopped, or None when AWS does not say.

    None is reported as an unknown duration rather than silently dropping the
    instance. A detector that skips what it cannot parse is a detector that
    quietly misses things, which is IA-200.
    """
    m = _STOPPED_AT.search(inst.get("StateTransitionReason", "") or "")
    if not m:
        return None
    return datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S").replace(
        tzinfo=timezone.utc)


def idle_attached_volumes(ec2, now=None, min_days=STOPPED_DAYS):
    """Volumes attached to an instance that has been stopped for a long time.

    This is the gap IA-200 was about. A stopped instance is not idle EC2,
    because it is not running. Its volume is not an orphan, because it is
    attached. It bills every hour all the same, and before this detector
    existed both of the other two reported nothing about it.
    """
    now = now or datetime.now(timezone.utc)
    stopped = {}
    r = ec2.describe_instances(
        Filters=[{"Name": "instance-state-name", "Values": ["stopped"]}])
    for res in r["Reservations"]:
        for inst in res["Instances"]:
            since = _stopped_since(inst)
            if since is None:
                stopped[inst["InstanceId"]] = None
            elif (now - since).days >= min_days:
                stopped[inst["InstanceId"]] = since

    out = []
    for v in ec2.describe_volumes()["Volumes"]:
        for att in v.get("Attachments", []):
            iid = att.get("InstanceId")
            if iid not in stopped:
                continue
            since = stopped[iid]
            if since is None:
                how_long = "stopped, for how long AWS does not say"
            else:
                how_long = f"stopped {(now - since).days} days"
            est = round(EBS_GB_MO.get(v["VolumeType"], 0.10) * v["Size"], 2)
            out.append({
                "type": "idle_attached_ebs", "resource": v["VolumeId"],
                "detail": f"{v['Size']} GiB {v['VolumeType']} on {iid}, {how_long}",
                "est_monthly_usd": est,
                "action": "Snapshot, then terminate the instance or detach"})
            break
    return out


def unused_ips(ec2):
    out = []
    for a in ec2.describe_addresses()["Addresses"]:
        if not a.get("AssociationId"):
            out.append({"type": "unused_eip", "resource": a.get("PublicIp", "?"),
                        "detail": "Elastic IP not associated",
                        "est_monthly_usd": EIP_MO, "action": "Release"})
    return out


def undeclared_resources(ec2):
    """Resources in the account carrying no ManagedBy=terraform tag.

    `terraform plan` cannot answer this. A diff only speaks about what it
    compares, so a clean plan is silent about everything outside the state,
    and silence reads as absence. See IA-199.

    The tag is a convention, so this catches accidents and forgetting, which
    is what happened. It does not catch anyone determined to hide something,
    and it is not offered as if it did.
    """
    out = []
    r = ec2.describe_instances()
    for res in r["Reservations"]:
        for inst in res["Instances"]:
            if _is_managed(inst):
                continue
            out.append({
                "type": "undeclared_ec2", "resource": inst["InstanceId"],
                "detail": f"{inst['InstanceType']}, {inst['State']['Name']}, "
                          f"Name={name_of(inst) or '(none)'}, no {MANAGED_BY_TAG} tag",
                "est_monthly_usd": 0.0,
                "action": "terraform import, or destroy by plan"})
    for v in ec2.describe_volumes()["Volumes"]:
        if _is_managed(v):
            continue
        out.append({
            "type": "undeclared_ebs", "resource": v["VolumeId"],
            "detail": f"{v['Size']} GiB {v['VolumeType']}, no {MANAGED_BY_TAG} tag",
            "est_monthly_usd": 0.0,
            "action": "terraform import, or destroy by plan"})
    return out


# --------------------------------------------------------------------------
# What this program looks at, declared once.
#
# The report prints this list whenever it finds nothing, so that a zero says
# what was examined rather than just "clean account". It lives here and not in
# the dashboard, because a description kept in two files is the shape of
# IA-203. The dashboard reads it out of report.json.
# --------------------------------------------------------------------------

DETECTORS = [
    ("idle_instances",
     f"running instances averaging under {IDLE_CPU_PCT}% CPU"),
    ("orphan_volumes",
     "volumes attached to nothing"),
    ("idle_attached_volumes",
     f"volumes attached to instances stopped for over {STOPPED_DAYS} days"),
    ("unused_ips",
     "Elastic IPs with no association"),
    ("undeclared_resources",
     f"instances and volumes with no {MANAGED_BY_TAG}={MANAGED_BY_VALUE} tag"),
]


def examined():
    """What the detectors cover, in words, for the report to print."""
    return [what for _, what in DETECTORS]


def main():
    ec2 = boto3.client("ec2", region_name="us-east-1")
    cw  = boto3.client("cloudwatch", region_name="us-east-1")
    ce  = boto3.client("ce", region_name="us-east-1")
    bud = boto3.client("budgets", region_name="us-east-1")

    self_id, account_id = instance_identity()
    if account_id is None:
        # sts:GetCallerIdentity is inside the read set, so this is a second
        # legitimate source for the same fact rather than a guess.
        try:
            account_id = boto3.client("sts").get_caller_identity()["Account"]
        except Exception:
            account_id = None

    fc = forecast(ce, budgets=bud, account_id=account_id)
    waste = (idle_instances(ec2, cw, self_instance_id=self_id)
             + orphan_volumes(ec2)
             + idle_attached_volumes(ec2)
             + unused_ips(ec2))
    undeclared = undeclared_resources(ec2)
    total = round(sum(w["est_monthly_usd"] for w in waste), 2)
    health = max(0, 100 - len(waste) * 5 - len(undeclared) * 5
                 - (15 if fc["status"] != "OK" else 0))

    L = "=" * 68
    print(L)
    print("         AWS FinOps Guardian  ::  Cost + Waste Report")
    print(L)
    if fc["status"] == "UNKNOWN":
        print("  Forecast   UNKNOWN. No verdict is given, because one of the two")
        print("             numbers a verdict needs could not be read.")
        print(f"             {fc['note']}")
    else:
        print(f"  Forecast   MTD ${fc['mtd']:.2f}   EOM ${fc['projected_eom']:.2f}"
              f"   Budget ${fc['budget']:.2f}   [{fc['status']}]")
    print(f"  Cost view  {fc['cost_view']}")
    print(f"  Days       {fc['days']}")
    print(L)
    if waste:
        print(f"  WASTE FOUND: {len(waste)} item(s)  ->  ${total:.2f}/mo on the floor")
        print("-" * 68)
        for w in waste:
            print(f"  [{w['type']:<18}] {w['resource']}")
            print(f"       {w['detail']}")
            print(f"       ~${w['est_monthly_usd']:.2f}/mo   action: {w['action']}")
    else:
        # What was examined, so that a zero carries information. "Clean
        # account." on its own is indistinguishable from a detector that
        # cannot fire, which is exactly what IA-200 was.
        print("  WASTE FOUND: none. What was examined:")
        for what in examined():
            print(f"               - {what}")
    print(L)
    if undeclared:
        print(f"  UNDECLARED: {len(undeclared)} resource(s) with no "
              f"{MANAGED_BY_TAG}={MANAGED_BY_VALUE} tag")
        print("-" * 68)
        for u in undeclared:
            print(f"  [{u['type']:<18}] {u['resource']}")
            print(f"       {u['detail']}")
    else:
        print(f"  UNDECLARED: none. Every instance and volume carries "
              f"{MANAGED_BY_TAG}={MANAGED_BY_VALUE}.")
    print(L)
    print(f"  Health score: {health}/100")
    print(f"  Self: {self_id or 'unknown, so nothing was excluded from the above'}")
    print(L)

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "forecast": fc, "waste": waste, "undeclared": undeclared,
        "waste_monthly_usd": total, "health_score": health,
        "self_instance_id": self_id, "examined": examined(),
    }
    with open("report.json", "w") as f:
        json.dump(report, f, indent=2)
    print("  Wrote report.json")

if __name__ == "__main__":
    main()
