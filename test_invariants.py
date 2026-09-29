"""
Invariants for the FinOps Guardian.

The suite is written BEFORE the fixes, deliberately. Every invariant here is
a statement of what the Guardian must do. Running it today shows which of
those statements the code does not yet satisfy, which is the evidence that
the bugs recorded in IA-199 to IA-204 are real rather than argued.

No credentials, no network, no account, no spend. Every AWS client is a fake
that implements filter semantics and refuses filters it does not model.

Run:  python test_invariants.py
"""

from __future__ import annotations

import datetime as dt
import sys
import types
from datetime import datetime, timezone
from pathlib import Path

HERE = Path(__file__).parent
sys.path.insert(0, str(HERE / "src"))
sys.path.insert(0, str(HERE))

# guardian.py imports boto3 at module level. No invariant here calls it, so a
# stand-in is enough to import the module. The stand-in raises if anything
# ever does call it, and the fact that it is in use is printed, because a
# substitution nobody is told about is the defect this project is about.
BOTO3_STUBBED = False
try:  # pragma: no cover
    import boto3  # noqa: F401
except ImportError:
    BOTO3_STUBBED = True
    _stub = types.ModuleType("boto3")

    def _refuse(*_a, **_k):
        raise AssertionError(
            "a test called boto3.client. No invariant in this suite may talk "
            "to AWS, so this is a defect in the test, not in the Guardian.")

    _stub.client = _refuse
    sys.modules["boto3"] = _stub

import fakes  # noqa: E402
import guardian  # noqa: E402
from fakes import (  # noqa: E402
    GUARDIAN_ID, MANAGED, SEPT_GROSS_TOTAL, TODAY, UNTRACKED_ID,
    FakeCloudWatch, FakeEC2, UnsupportedFilter, account_as_of_2026_09_29,
    address, instance, september_budgets, september_cost_explorer, volume,
)

RUN: list[str] = []
FAILED: list[str] = []


def check(name, fn):
    RUN.append(name)
    try:
        ok = fn()
    except BaseException as exc:  # an unnamed failure must be reported, not fatal
        FAILED.append(name)
        print(f"FAIL {name}")
        print(f"       raised {type(exc).__name__}: {exc}")
        return
    if not ok:
        FAILED.append(name)
        print(f"FAIL {name}")


def control(name, fn):
    """A check that passes only when something is NOT true.

    Its job is to prove the rule beside it is capable of failing.
    """
    check(f"control: {name}", fn)


class frozen:
    """Freeze the Guardian's clock, so a forecast is a fact and not a function
    of the day the suite happens to run."""

    def __init__(self, at):
        self.at = at

    def __enter__(self):
        self._orig = guardian.datetime
        guardian.datetime = fakes.frozen_datetime(self.at)

    def __exit__(self, *_):
        guardian.datetime = self._orig
        return False


def near(a, b, tol=0.01):
    return abs(float(a) - float(b)) <= tol


# ==========================================================================
# The fakes themselves. If these are wrong, nothing below means anything.
# ==========================================================================

def _ec2_filter_works():
    ec2 = account_as_of_2026_09_29()
    running = ec2.describe_instances(
        Filters=[{"Name": "instance-state-name", "Values": ["running"]}])
    everything = ec2.describe_instances()
    n_running = sum(len(r["Instances"]) for r in running["Reservations"])
    n_all = sum(len(r["Instances"]) for r in everything["Reservations"])
    return n_running == 0 and n_all == 4


def _volume_filter_works():
    ec2 = account_as_of_2026_09_29()
    available = ec2.describe_volumes(
        Filters=[{"Name": "status", "Values": ["available"]}])["Volumes"]
    everything = ec2.describe_volumes()["Volumes"]
    return len(available) == 0 and len(everything) == 4


def _unknown_filter_refused():
    ec2 = account_as_of_2026_09_29()
    try:
        ec2.describe_instances(Filters=[{"Name": "not-a-filter", "Values": ["x"]}])
    except UnsupportedFilter:
        return True
    return False


def _ce_distinguishes_gross_from_net():
    ce = september_cost_explorer()
    def total(flt):
        r = ce.get_cost_and_usage(
            TimePeriod={"Start": "2026-09-01", "End": "2026-09-30"},
            Granularity="DAILY", Metrics=["UnblendedCost"], Filter=flt)
        return sum(float(b["Total"]["UnblendedCost"]["Amount"])
                   for b in r["ResultsByTime"])
    net = total(None)
    gross = total({"Not": {"Dimensions": {"Key": "RECORD_TYPE",
                                          "Values": ["Credit", "Refund"]}}})
    return near(gross, SEPT_GROSS_TOTAL) and near(net, 0.0) and not near(gross, net)


def _cw_answers_per_instance():
    cw = FakeCloudWatch({"i-quiet": [1.0], "i-busy": [90.0]})
    def avg(iid):
        pts = cw.get_metric_statistics(
            Namespace="AWS/EC2", MetricName="CPUUtilization",
            Dimensions=[{"Name": "InstanceId", "Value": iid}],
            StartTime=TODAY, EndTime=TODAY, Period=3600,
            Statistics=["Average"])["Datapoints"]
        return pts[0]["Average"] if pts else None
    return avg("i-quiet") == 1.0 and avg("i-busy") == 90.0 and avg("i-absent") is None


control("the fake EC2 honours instance-state-name, so a state filter can fail a test",
        _ec2_filter_works)
control("the fake EC2 honours volume status, so a status filter can fail a test",
        _volume_filter_works)
control("the fake EC2 refuses a filter it does not model instead of returning everything",
        _unknown_filter_refused)
control("the fake Cost Explorer tells gross from net, so the credit invariant can fail",
        _ce_distinguishes_gross_from_net)
control("the fake CloudWatch answers per instance, so a CPU invariant can fail",
        _cw_answers_per_instance)


# ==========================================================================
# What the Guardian already gets right. These must stay green through the fix.
# ==========================================================================

def _eip_unassociated_reported():
    ec2 = FakeEC2(addresses=[address("52.0.0.1")])
    out = guardian.unused_ips(ec2)
    return len(out) == 1 and out[0]["resource"] == "52.0.0.1"


def _eip_associated_ignored():
    ec2 = FakeEC2(addresses=[address("52.0.0.2", associated=True)])
    return guardian.unused_ips(ec2) == []


def _available_volume_reported():
    ec2 = FakeEC2(volumes=[volume("vol-free", state="available")])
    out = guardian.orphan_volumes(ec2)
    return len(out) == 1 and out[0]["type"] == "unattached_ebs"


def _gp3_priced_correctly():
    ec2 = FakeEC2(volumes=[volume("vol-free", size=8, vtype="gp3", state="available")])
    return near(guardian.orphan_volumes(ec2)[0]["est_monthly_usd"], 0.64)


def _idle_running_instance_reported():
    ec2 = FakeEC2(instances=[instance("i-idle", name="something")])
    cw = FakeCloudWatch({"i-idle": [0.4, 0.6]})
    out = guardian.idle_instances(ec2, cw)
    return len(out) == 1 and out[0]["resource"] == "i-idle"


def _busy_running_instance_ignored():
    ec2 = FakeEC2(instances=[instance("i-busy", name="something")])
    cw = FakeCloudWatch({"i-busy": [70.0, 80.0]})
    return guardian.idle_instances(ec2, cw) == []


def _no_datapoints_ignored():
    ec2 = FakeEC2(instances=[instance("i-silent", name="something")])
    return guardian.idle_instances(ec2, FakeCloudWatch({})) == []


def _unknown_instance_type_still_priced():
    ec2 = FakeEC2(instances=[instance("i-odd", itype="m7g.9xlarge", name="x")])
    cw = FakeCloudWatch({"i-odd": [0.1]})
    out = guardian.idle_instances(ec2, cw)
    return len(out) == 1 and out[0]["est_monthly_usd"] > 0


check("an Elastic IP with no association is reported", _eip_unassociated_reported)
check("an Elastic IP that is associated is not reported", _eip_associated_ignored)
check("a volume in state available is reported", _available_volume_reported)
check("8 GiB of gp3 is priced at 0.64 a month", _gp3_priced_correctly)
check("a running instance below the CPU threshold is reported", _idle_running_instance_reported)
check("a running instance above the CPU threshold is not reported", _busy_running_instance_ignored)
check("an instance CloudWatch has no datapoints for is not reported", _no_datapoints_ignored)
check("an instance type absent from the price table still gets an estimate",
      _unknown_instance_type_still_priced)


# ==========================================================================
# IA-200. The account as it actually stands, and what must be said about it.
# ==========================================================================

def all_waste(ec2, cw):
    return (guardian.idle_instances(ec2, cw)
            + guardian.orphan_volumes(ec2)
            + guardian.unused_ips(ec2)
            + guardian.idle_attached_volumes(ec2))


def _fixture_four_stopped():
    ec2 = account_as_of_2026_09_29()
    insts = [i for r in ec2.describe_instances()["Reservations"] for i in r["Instances"]]
    return len(insts) == 4 and all(i["State"]["Name"] == "stopped" for i in insts)


def _fixture_four_attached():
    ec2 = account_as_of_2026_09_29()
    vols = ec2.describe_volumes()["Volumes"]
    return len(vols) == 4 and all(v["State"] == "in-use" for v in vols)


def _stopped_attached_volume_is_waste():
    ec2 = account_as_of_2026_09_29()
    out = guardian.idle_attached_volumes(ec2, now=TODAY)
    return len(out) >= 1


def _all_four_volumes_reported():
    ec2 = account_as_of_2026_09_29()
    out = guardian.idle_attached_volumes(ec2, now=TODAY)
    return len({w["resource"] for w in out}) == 4


def _waste_total_is_2_56():
    ec2 = account_as_of_2026_09_29()
    out = guardian.idle_attached_volumes(ec2, now=TODAY)
    return near(sum(w["est_monthly_usd"] for w in out), 2.56, tol=0.02)


def _account_does_not_report_clean():
    ec2 = account_as_of_2026_09_29()
    cw = FakeCloudWatch({})
    return len(all_waste(ec2, cw)) > 0


def _running_instances_volume_not_flagged():
    ec2 = FakeEC2(
        instances=[instance("i-live", state="running", name="x", volumes=["vol-live"])],
        volumes=[volume("vol-live", attached_to="i-live")])
    return guardian.idle_attached_volumes(ec2, now=TODAY) == []


check("the fixture account holds four instances and all of them are stopped",
      _fixture_four_stopped)
check("the fixture account holds four volumes and all of them are attached",
      _fixture_four_attached)
check("a volume attached to an instance stopped for weeks is reported as waste",
      _stopped_attached_volume_is_waste)
check("all four of the account's idle volumes are reported, one item each",
      _all_four_volumes_reported)
check("the waste total for that account is 2.56 a month", _waste_total_is_2_56)
check("the account of 29 September 2026 does not report as clean",
      _account_does_not_report_clean)
check("a volume attached to a running instance is not reported "
      "(becomes a control once the detector exists)",
      _running_instances_volume_not_flagged)


# ==========================================================================
# IA-201. Who the Guardian thinks it is.
# ==========================================================================

def _self_excluded_by_id():
    ec2 = FakeEC2(instances=[
        instance(GUARDIAN_ID, state="running", name="finops-guardian-ec2", tags=MANAGED)])
    cw = FakeCloudWatch({GUARDIAN_ID: [0.2]})
    return guardian.idle_instances(ec2, cw, self_instance_id=GUARDIAN_ID) == []


def _namesake_still_reported():
    ec2 = FakeEC2(instances=[
        instance(UNTRACKED_ID, state="running", name="finops-guardian")])
    cw = FakeCloudWatch({UNTRACKED_ID: [0.2]})
    out = guardian.idle_instances(ec2, cw, self_instance_id=GUARDIAN_ID)
    return len(out) == 1 and out[0]["resource"] == UNTRACKED_ID


def _unknown_identity_excludes_nothing():
    ec2 = FakeEC2(instances=[
        instance(GUARDIAN_ID, state="running", name="finops-guardian-ec2")])
    cw = FakeCloudWatch({GUARDIAN_ID: [0.2]})
    out = guardian.idle_instances(ec2, cw, self_instance_id=None)
    return len(out) == 1


check("the Guardian excludes itself by instance id, whatever its Name tag",
      _self_excluded_by_id)
check("an instance merely named finops-guardian is still reported",
      _namesake_still_reported)
check("when its own identity is unknown the Guardian excludes nothing",
      _unknown_identity_excludes_nothing)


# ==========================================================================
# IA-202. Gross or net.
# ==========================================================================

def _mtd_is_gross():
    with frozen(TODAY):
        fc = guardian.forecast(september_cost_explorer())
    return near(fc["mtd"], SEPT_GROSS_TOTAL, tol=0.02)


def _forecast_names_its_cost_view():
    with frozen(TODAY):
        fc = guardian.forecast(september_cost_explorer())
    return isinstance(fc.get("cost_view"), str) and fc["cost_view"] != ""


check("the month-to-date figure is gross, so credits cannot hide spend", _mtd_is_gross)
check("the forecast names the cost view it used", _forecast_names_its_cost_view)


# ==========================================================================
# IA-203. Which threshold.
# ==========================================================================

def _limit_comes_from_the_account():
    with frozen(TODAY):
        fc = guardian.forecast(september_cost_explorer(), budgets=september_budgets())
    return near(fc["budget"], 1.00)


def _verdict_is_over():
    with frozen(TODAY):
        fc = guardian.forecast(september_cost_explorer(), budgets=september_budgets())
    return fc["status"] == "OVER"


def _no_limit_means_no_verdict():
    with frozen(TODAY):
        fc = guardian.forecast(september_cost_explorer(), budgets=None)
    return fc["status"] not in ("OK", "OVER")


check("the budget limit comes from the account, not from a constant in the module",
      _limit_comes_from_the_account)
check("with September's own figures the verdict is OVER", _verdict_is_over)
check("when the limit cannot be read there is no verdict at all",
      _no_limit_means_no_verdict)


# ==========================================================================
# IA-199. What is here that nobody declared.
# ==========================================================================

def _untagged_resource_reported():
    ec2 = account_as_of_2026_09_29()
    out = guardian.undeclared_resources(ec2)
    return UNTRACKED_ID in {w["resource"] for w in out}


def _tagged_resource_not_reported():
    ec2 = account_as_of_2026_09_29()
    out = guardian.undeclared_resources(ec2)
    return GUARDIAN_ID not in {w["resource"] for w in out}


check("a resource with no ManagedBy tag is reported as undeclared",
      _untagged_resource_reported)
check("a resource tagged ManagedBy=terraform is not reported as undeclared",
      _tagged_resource_not_reported)


# ==========================================================================
# Found while writing this suite: an outage that looks like good news.
# ==========================================================================

def _outage_sets_data_ok_false():
    ce = september_cost_explorer()
    ce.unavailable = True
    with frozen(TODAY):
        fc = guardian.forecast(ce)
    return fc["data_ok"] is False


def _outage_is_not_an_ok_verdict():
    ce = september_cost_explorer()
    ce.unavailable = True
    with frozen(TODAY):
        fc = guardian.forecast(ce)
    return fc["status"] != "OK"


check("a Cost Explorer outage sets data_ok to false", _outage_sets_data_ok_false)
check("a Cost Explorer outage does not produce an OK verdict",
      _outage_is_not_an_ok_verdict)


# ==========================================================================

if BOTO3_STUBBED:
    print("NOTE  boto3 is not installed, so a stand-in was used to import the "
          "module.\n      No invariant calls it, and the stand-in raises if one ever does.")

print()
if FAILED:
    print(f"{len(FAILED)} of {len(RUN)} invariants do not hold.")
    raise SystemExit(1)
print(f"all {len(RUN)} invariants hold")
