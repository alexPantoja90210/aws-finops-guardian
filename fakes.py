"""
Fakes for the AWS clients the Guardian uses, so its logic can be exercised
without an account, without credentials, without network and without spend.

Two rules govern everything here.

**A fake that ignores a filter cannot test code that relies on one.** These
fakes implement filter semantics rather than returning everything, and they
raise on a filter they do not understand instead of quietly ignoring it. A
fake that silently ignored an unknown filter would make broken code look
correct, which is the defect this whole repository is about.

**A fake that cannot distinguish two cases cannot test the difference.** The
Cost Explorer fake models credits as separate records, because the defect
under test is the difference between gross and net consumption.
"""

from __future__ import annotations

import datetime as dt
from datetime import datetime, timezone


class UnsupportedFilter(Exception):
    """Raised rather than ignoring a filter this fake does not implement."""


# --------------------------------------------------------------------------
# EC2
# --------------------------------------------------------------------------

def instance(iid, *, state="running", itype="t3.micro", name=None,
             tags=None, stopped_at=None, volumes=()):
    t = list(tags or [])
    if name is not None:
        t.append({"Key": "Name", "Value": name})
    inst = {
        "InstanceId": iid,
        "InstanceType": itype,
        "State": {"Name": state},
        "Tags": t,
        "BlockDeviceMappings": [
            {"DeviceName": "/dev/xvda", "Ebs": {"VolumeId": v}} for v in volumes
        ],
    }
    if stopped_at is not None:
        inst["StateTransitionReason"] = (
            f"User initiated ({stopped_at.strftime('%Y-%m-%d %H:%M:%S')} GMT)")
    return inst


def volume(vid, *, size=8, vtype="gp3", state="in-use", attached_to=None,
           tags=None):
    v = {
        "VolumeId": vid,
        "Size": size,
        "VolumeType": vtype,
        "State": state,
        "Tags": list(tags or []),
        "Attachments": [],
    }
    if attached_to is not None:
        v["Attachments"] = [{"InstanceId": attached_to, "State": "attached",
                             "DeleteOnTermination": True}]
    return v


def address(ip, *, associated=False):
    a = {"PublicIp": ip}
    if associated:
        a["AssociationId"] = "eipassoc-" + ip.replace(".", "")
    return a


class FakeEC2:
    def __init__(self, instances=(), volumes=(), addresses=()):
        self._instances = list(instances)
        self._volumes = list(volumes)
        self._addresses = list(addresses)

    # -- filters ----------------------------------------------------------

    @staticmethod
    def _match(entity_value, values):
        return entity_value in values

    def describe_instances(self, Filters=None):
        out = self._instances
        for f in (Filters or []):
            key, values = f["Name"], f["Values"]
            if key == "instance-state-name":
                out = [i for i in out if self._match(i["State"]["Name"], values)]
            elif key.startswith("tag:"):
                want = key[4:]
                out = [i for i in out
                       if any(t["Key"] == want and t["Value"] in values
                              for t in i.get("Tags", []))]
            else:
                raise UnsupportedFilter(
                    f"describe_instances does not implement the filter {key!r}. "
                    "This fake refuses rather than returning everything, because "
                    "a fake that ignores a filter cannot test code that uses one.")
        return {"Reservations": [{"Instances": list(out)}]} if out else {"Reservations": []}

    def describe_volumes(self, Filters=None):
        out = self._volumes
        for f in (Filters or []):
            key, values = f["Name"], f["Values"]
            if key == "status":
                out = [v for v in out if self._match(v["State"], values)]
            elif key.startswith("tag:"):
                want = key[4:]
                out = [v for v in out
                       if any(t["Key"] == want and t["Value"] in values
                              for t in v.get("Tags", []))]
            else:
                raise UnsupportedFilter(
                    f"describe_volumes does not implement the filter {key!r}.")
        return {"Volumes": list(out)}

    def describe_addresses(self):
        return {"Addresses": list(self._addresses)}


# --------------------------------------------------------------------------
# CloudWatch
# --------------------------------------------------------------------------

class FakeCloudWatch:
    """cpu maps an instance id to a list of average CPU percentages.

    An instance absent from the map returns no datapoints, which is what a
    stopped instance does in the real API and is a case the Guardian handles.
    """

    def __init__(self, cpu=None):
        self._cpu = dict(cpu or {})

    def get_metric_statistics(self, Namespace, MetricName, Dimensions,
                              StartTime, EndTime, Period, Statistics):
        iid = None
        for d in Dimensions:
            if d["Name"] == "InstanceId":
                iid = d["Value"]
        if iid is None:
            raise UnsupportedFilter(
                "this fake answers only per-InstanceId queries")
        return {"Datapoints": [{"Average": v} for v in self._cpu.get(iid, [])]}


# --------------------------------------------------------------------------
# Cost Explorer
# --------------------------------------------------------------------------

class DataUnavailable(Exception):
    pass


class _CEExceptions:
    DataUnavailableException = DataUnavailable


def _filter_excludes_credits(flt):
    """True when the filter is the standard 'Not RECORD_TYPE in (Credit, ...)'.

    Anything else raises, rather than being treated as no filter.
    """
    if flt is None:
        return False
    if "Not" in flt and "Dimensions" in flt["Not"]:
        dim = flt["Not"]["Dimensions"]
        if dim.get("Key") == "RECORD_TYPE":
            return "Credit" in dim.get("Values", [])
    raise UnsupportedFilter(
        f"this Cost Explorer fake implements only a Not/RECORD_TYPE filter, got {flt!r}")


class FakeCostExplorer:
    """gross_per_day and credit_per_day are amounts in USD.

    Without a filter the response nets credits against usage, which is what
    the real API does and is the behaviour under test.
    """

    exceptions = _CEExceptions()

    def __init__(self, *, start, days, gross_per_day, credit_per_day=0.0,
                 unavailable=False):
        self.start = start
        self.days = days
        self.gross = gross_per_day
        self.credit = credit_per_day
        self.unavailable = unavailable
        self.calls = []

    def get_cost_and_usage(self, TimePeriod, Granularity, Metrics, Filter=None):
        self.calls.append({"TimePeriod": TimePeriod, "Filter": Filter})
        if self.unavailable:
            raise DataUnavailable("no data for this period")
        excludes = _filter_excludes_credits(Filter)
        amount = self.gross if excludes else (self.gross - self.credit)
        buckets = []
        for n in range(self.days):
            day = self.start + dt.timedelta(days=n)
            buckets.append({
                "TimePeriod": {"Start": day.isoformat(),
                               "End": (day + dt.timedelta(days=1)).isoformat()},
                "Total": {"UnblendedCost": {"Amount": f"{amount:.10f}",
                                            "Unit": "USD"}},
            })
        return {"ResultsByTime": buckets}


# --------------------------------------------------------------------------
# Budgets
# --------------------------------------------------------------------------

class FakeBudgets:
    def __init__(self, budgets=()):
        self._budgets = list(budgets)

    def describe_budgets(self, AccountId=None, MaxResults=None):
        return {"Budgets": [
            {"BudgetName": b["name"],
             "BudgetLimit": {"Amount": f"{b['limit']:.2f}", "Unit": "USD"},
             "TimeUnit": "MONTHLY",
             "CostTypes": {"IncludeCredit": b.get("include_credit", False)}}
            for b in self._budgets]}


# --------------------------------------------------------------------------
# A frozen clock, so a forecast is a fact rather than a function of today
# --------------------------------------------------------------------------

def frozen_datetime(at):
    class Frozen(datetime):
        @classmethod
        def now(cls, tz=None):
            return at
    return Frozen


# --------------------------------------------------------------------------
# The account as it actually stood on 29 September 2026
# --------------------------------------------------------------------------

SEP_2 = datetime(2026, 9, 2, 17, 26, tzinfo=timezone.utc)
SEP_1 = datetime(2026, 9, 1, 14, 27, tzinfo=timezone.utc)
AUG_15 = datetime(2026, 8, 15, 16, 19, tzinfo=timezone.utc)
TODAY = datetime(2026, 9, 29, 12, 0, tzinfo=timezone.utc)

GUARDIAN_ID = "i-0460bd1bda7ca477f"
UNTRACKED_ID = "i-0318219b00fc4df65"
MANAGED = [{"Key": "ManagedBy", "Value": "terraform"}]


def account_as_of_2026_09_29():
    """Every instance stopped, every volume attached. The real thing."""
    insts = [
        instance(GUARDIAN_ID, state="stopped", name="finops-guardian-ec2",
                 tags=MANAGED, stopped_at=SEP_1, volumes=["vol-069cf7f74a69e7da4"]),
        instance("i-08c1e3a6ce3b2c1a9", state="stopped", name="finops-guardian-web",
                 tags=MANAGED, stopped_at=SEP_2, volumes=["vol-042c35b9811b1f07d"]),
        instance("i-08345ec41b2b86175", state="stopped", name="finops-guardian-app",
                 tags=MANAGED, stopped_at=SEP_2, volumes=["vol-03bdc97ce11d2d29e"]),
        # No ManagedBy tag: this is the one Terraform does not know about.
        instance(UNTRACKED_ID, state="stopped", name="finops-guardian",
                 stopped_at=AUG_15, volumes=["vol-0218c95fdf637ff4b"]),
    ]
    vols = [
        volume("vol-069cf7f74a69e7da4", attached_to=GUARDIAN_ID, tags=MANAGED),
        volume("vol-042c35b9811b1f07d", attached_to="i-08c1e3a6ce3b2c1a9", tags=MANAGED),
        volume("vol-03bdc97ce11d2d29e", attached_to="i-08345ec41b2b86175", tags=MANAGED),
        volume("vol-0218c95fdf637ff4b", attached_to=UNTRACKED_ID),
    ]
    return FakeEC2(instances=insts, volumes=vols, addresses=[])


# Measured: EC2-Other for 1 to 29 September 2026 was 2.32 USD and reconciles
# with 29.2 GiB-months of gp3. Total gross for the month to date was 3.44 USD,
# and credits absorbed it, so the net view reports approximately nothing.
SEPT_GROSS_TOTAL = 3.44
SEPT_DAYS = 29


def september_cost_explorer():
    per_day = SEPT_GROSS_TOTAL / SEPT_DAYS
    return FakeCostExplorer(
        start=dt.date(2026, 9, 1), days=SEPT_DAYS,
        gross_per_day=per_day, credit_per_day=per_day)


def september_budgets():
    return FakeBudgets([{"name": "finops-guardian-zero-spend", "limit": 1.00,
                         "include_credit": False}])
