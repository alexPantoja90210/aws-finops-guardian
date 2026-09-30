# AWS FinOps Guardian

A read-only FinOps tool for an AWS account. It forecasts the end-of-month bill
on **gross** consumption, reports idle and undeclared resources, scores account
health, and produces a dollar-ranked brief with a recommended action for each
finding.

> **It is not running.** The Terraform stack is applied and its read-only
> guarantee is verified from inside the account. The Python is tested against
> 41 invariants. The two have never been connected: `guardian.py` is not on the
> instance, its dependency is not installed there, nothing schedules it, and
> Cost Explorer records 12 API requests in August and 2 in September against
> the ~30 a month a daily run would make. This file described a running service
> until 29 September 2026. See [Is it deployed](#is-it-deployed) (IA-213).

The brief is generated from a template, not by a model. This file said "an AI
executive brief" until 29 September 2026, when someone read `build_brief` and
found f-strings (IA-209).

Runs on the AWS free tier. Built and documented in public, **including its own
defects**: nine were found in this repository on a single day and are recorded
as IA-199 to IA-206 and IA-209. What is fixed and what is not is set out under
[What is not fixed](#what-is-not-fixed), rather than summarised in a number here
that would drift.

## Why

Cloud spend grows quietly: unused resources plus poor visibility. That is the
problem FinOps addresses. This is a compact, safe, governance-first take on it.

## Design Principles

- **Least privilege, as a deny-by-default.** v1 is read-only. The IAM policy
  permits an enumerated read set and then **denies everything outside it**,
  using `NotAction` rather than a list of forbidden actions. A `Deny` can never
  be overridden by a later `Allow`, so the invariant does not depend on nobody
  making a mistake in future — and because it denies by exclusion, it also
  covers **AWS actions that do not exist yet**.
- **The guarantee is verified from inside the account, not from the plan.** A
  script runs on the instance under the role itself and tries to mutate things.
  Latest run: **11/11 mutations denied, 0 inconclusive, 5/5 reads working.**
  See [Proving the read-only claim](#proving-the-read-only-claim).
- **No secrets on the box.** The instance authenticates through an EC2 IAM
  instance profile. No access keys on disk, no private key to guard. IMDSv2 is
  required, which closes the SSRF path to stealing the role's credentials.
- **No inbound admin access.** Administration goes through AWS Systems Manager
  Session Manager. SSH is disabled by design — there is no port 22 and no key
  pair.
- **Budget-aware, and it notifies rather than guards.** A zero-spend budget
  sends ACTUAL and FORECASTED email notifications, measuring **gross**
  consumption (`include_credit = false`) so promotional credits cannot hide
  real spend. It has no power to stop, throttle or detach anything. This file
  said it "guards the account" until IA-204, which is a claim about power the
  resource does not have: the budget was breached by 343%, the emails were
  delivered and read, and the spend continued for four weeks. Giving the
  account a real brake was considered and declined, because an AWS Budgets
  Action would put a role in the account that can stop instances, and the
  strongest sentence this project can make is that it cannot change your
  account. The condition for revisiting that decision is written on IA-204.
- **Infrastructure as Code, with a stated reach.** Everything this project
  manages is defined in Terraform and applied plan-first: every change is
  previewed and approved before it touches the account. This file said "the
  whole stack" until IA-199, which is a larger claim. A clean `terraform plan`
  says the **managed** resources match the code; it is silent about anything
  outside the state, and silence reads as absence. On 29 September 2026 the
  account held one EC2 instance and two budgets that no plan declared, and no
  run of `terraform plan` could have reported them, however often it was run.
  See [`infra/README.md`](infra/README.md).

## Architecture

| Piece | Role |
|---|---|
| **Terraform** (`infra/`) | Defines everything this project manages, and a clean plan speaks only about those resources. Provider pinned via a versioned `.terraform.lock.hcl`. |
| **EC2 t3.micro** | **Provisioned and empty.** Intended to run `guardian.py` on a schedule; today it holds neither the program nor `boto3`. Encrypted gp3 root volume, IMDSv2 required. See [Is it deployed](#is-it-deployed). |
| **IAM read-only role** | An enumerated read set, plus a `NotAction` Deny on everything outside it. Attached by instance profile. |
| **Cost Explorer API** | Month-to-date and forecast spend. |
| **CloudWatch** | CPU metrics used to flag idle instances. |
| **EC2 API** | Resource inventory for orphaned volumes and unused IPs. |
| **AWS Budgets** | Zero-spend guard, credit-blind by configuration. |
| **SSM Session Manager** | Administrative access, without opening a port. |
| **nginx** | Intended to serve the dashboard. Reports `inactive`, and no dashboard has ever been generated on the instance. |
| **GitHub Actions** | Deployment automation. |

## The read-only policy, as the code implements it

The first version of this policy listed **thirteen** mutating actions and denied
those. The README described it as "an explicit Deny on every mutating action."

**Those two sentences were not the same claim, and the difference is the whole
problem.** A Deny that enumerates what is forbidden is out of date the day AWS
ships one more service. It can only ever be as complete as the day it was
written.

It is now inverted. `DenyEverythingOutsideTheReadSet` uses `NotAction`: the
listed entries are the *exception*, and everything else is denied.

```hcl
statement {
  sid         = "DenyEverythingOutsideTheReadSet"
  effect      = "Deny"
  not_actions = [ /* the read set, plus the SSM management plane */ ]
  resources   = ["*"]
}
```

The exclusion list holds the Cost Explorer, CloudWatch, Logs, EC2-describe and
Budgets reads the agent actually uses — each one mirroring an `Allow` above it —
plus three families that are there for a specific reason:

```hcl
"ssm:*", "ssmmessages:*", "ec2messages:*",
```

**Session Manager is the only way into the box.** There is no SSH ingress by
design, so omitting those would have locked the operator out of the instance
while proving nothing about read-only. That is a deliberate, stated exception,
not an oversight — and it is the kind of thing a `NotAction` policy forces you
to decide explicitly.

`sts:GetCallerIdentity` is also excluded, so the verifier can name the principal
it is testing. It grants access to nothing.

## Proving the read-only claim

**A policy is a claim until something tries to break it.** `terraform plan` shows
what was *declared*; it cannot show what a principal can actually do.

`infra/verify_readonly.sh` runs **on the instance, under the role itself**, and
attempts mutations. `infra/run_verify_on_box.ps1` ships it there over SSM and
returns the output.

It reports **three** outcomes, not two:

| Outcome | Meaning |
|---|---|
| `DENIED` | The call reached authorization and was refused. This is a pass. |
| `NOT DENIED` | The call reached authorization and was allowed. This is a failure. |
| `INCONCLUSIVE` | The call never reached authorization — malformed id, CLI usage error, a 404 before the 403. **Proves nothing, and is never counted as a pass.** |

That third outcome exists because the first version did not have it. It reported
four probes as "the role can do something it must not" when those probes had died
before the authorization check ever ran — a malformed instance id, a CLI argument
error, and S3 answering 404 before it would have answered 403. **The verifier
raised a false alarm against a policy that was already correct.**

The fix: real resource ids read from IMDS with `--dry-run`, a `PREAUTH` pattern
that recognises a call that failed early, and `logs:DeleteLogGroup` in place of
the S3 probe.

Current result, run under `assumed-role/finops-guardian-readonly-role`:

```
11/11 mutations DENIED · 0 INCONCLUSIVE · 5/5 reads working
```

**The script refuses to run as a human principal**, and says why: adding a person
to the role's trust policy to make the check convenient would change the subject
of the test. The trust policy is `ec2.amazonaws.com` and stays that way.

It is also written in `bash` against the preinstalled AWS CLI rather than in
Python with `boto3`. The first version needed a package the instance did not
have — and **installing software onto the machine under audit means mutating the
subject of the test.**

## Infrastructure as Code

The stack is not clicked together. `infra/` holds `versions.tf`, `variables.tf`,
`main.tf`, `outputs.tf` and `terraform.tfvars.example`.

The workflow is **plan-first**: `terraform plan` is free and is the artifact that
gets reviewed; `apply` runs only after a human reads the plan. That ordering was
not decorative — applies have failed mid-run against real provider rules that
neither `validate` nor `plan` can see, and in each case the state stayed
consistent and the run resumed exactly where it broke, with no orphaned
resources.

The lesson is written up in [`infra/README.md`](infra/README.md): `validate`
checks shape, `plan` checks the diff against state, `apply` checks that the
provider accepts the values — **and only execution under the real principal
checks what that principal can do.** Each layer catches something the one before
it structurally cannot.

**To reproduce:** copy `terraform.tfvars.example` to `terraform.tfvars` and fill
in your own region, operator IP and alert email — `terraform.tfvars` is
gitignored on purpose and is never published. Then `terraform init`, `plan`,
review, `apply`.

## What is detected, and by which mechanism

Stating the reach of a check beside the check is the practice this whole
repository is an argument for.

| Mechanism | Catches | Cannot catch |
| --- | --- | --- |
| `idle_instances` | running instances under 5% average CPU | anything that is stopped |
| `orphan_volumes` | volumes attached to nothing | volumes that are attached |
| `idle_attached_volumes` | volumes on instances stopped over 7 days | volumes on running instances |
| `unused_ips` | Elastic IPs with no association | associated addresses |
| `undeclared_resources` | resources with no `ManagedBy=terraform` tag | a resource Terraform created and later lost from state, which keeps its tags |
| `terraform plan` | drift in the resources the state lists | anything outside the state |

The first three lines exist because of IA-200: before `idle_attached_volumes`,
a stopped instance with an attached volume fell between "not running, so not
idle EC2" and "attached, so not an orphan", and billed every hour while both
other detectors reported nothing.

The last two lines are the open one. Neither can see a resource Terraform
created and then lost from state. The check that would is IA-210.

## The invariant suite

```
python test_invariants.py     ->  all 44 invariants hold
python prove_it_can_fail.py   ->  all 11 mutations were caught
```

No credentials, no network, no account, no spend. `boto3` is stood in for when
it is absent, and the stand-in raises if any test ever calls it.

Until 29 September 2026 this repository had no test of any kind, and CI ran
`py_compile` on two files and printed a tick (IA-205). Every defect found that
day compiles cleanly, so the tick was never evidence of anything.

The suite is written as statements of what the Guardian **must** do rather than
as a description of what it does. It was committed red, reproducing eight
defects in one command, and turned green by fixing them.

**The fakes refuse rather than ignore.** Both broken detectors were broken in
their *filter*, so a fake that returned everything regardless would have made
them look correct. `fakes.py` implements filter semantics and raises
`UnsupportedFilter` on a filter it does not model. The Cost Explorer fake models
credits as separate records, because gross against net was the whole of IA-202.
Five invariants are controls on the fakes themselves: if the fakes are wrong,
nothing else in the file means anything.

**The fixture is the account.** `account_as_of_2026_09_29()` matches
`describe-instances` and `describe-volumes` tag for tag, checked against the
live account the same day.

### Passing is not the claim

`prove_it_can_fail.py` copies the tree, breaks the code eleven ways, and checks
that the suite goes red **and that the invariants which should catch each break
are the ones that do**. A mutation that reddens the suite for an unrelated
reason proves nothing, so each one names the invariants it expects.

One mutation targets `fakes.py` rather than the product: if the fakes stop
refusing filters they do not model, several invariants keep passing while
testing nothing. A broken fake has to be caught too.

**The harness has two controls of its own**, because the same argument applies
to it. When an anchor no longer matches the source it prints
`SKIP  the anchor has moved, so this proves nothing` and exits non-zero, rather
than passing quietly on a rule it never tested. And planting a mutation that
changes only a comment makes it report `the suite stayed green` and exit
non-zero. Both were run deliberately before this was committed.

**A word that now means two things in this file, said plainly rather than left
to collide.** The read-only section reports *11/11 mutations denied*: those are
AWS API calls attempted against the instance role, and denying them is the
point. Here, *11 mutations caught* means deliberate edits to this repository's
own source, and catching them is the point. Same word, opposite direction,
unrelated elevens. The coincidence is accidental.

Three invariants were added while writing it, for cases no mutation could reach
because nothing covered them: an instance whose stop time AWS does not report,
the undeclared *volume* as distinct from the undeclared instance, and a canary
on the detector count. That is the harness doing its job before it ran.

### What a green suite does not mean

It means the logic behaves as specified against fixtures. It does not mean the
account behaves as the fixtures describe. Confirming runs against the live
account are tracked on their issues and are not claimed here as done.

## Is it deployed

**No.** Written down here rather than left to be discovered, because for six
weeks this file said otherwise.

A read-only probe of the instance under SSM on 29 September 2026, plus two
queries against the account's own billing:

| Checked | Result |
| --- | --- |
| `guardian.py` anywhere on the instance | not present |
| `boto3`, its only dependency, any interpreter or venv | not installed, and no copy on disk |
| `crontab` | not installed |
| systemd timers | seven, all stock system units, none for the Guardian |
| `report.json` or `dashboard.html`, ever | neither has ever existed there |
| `nginx` | `inactive` |
| Cost Explorer API requests, August 2026 | **12** |
| Cost Explorer API requests, September 2026 | **2** |
| EC2 compute hours, August 2026 | **3.07** |

The last three matter most, because they do not depend on which instance is
examined. A forecast cannot be produced without calling `get_cost_and_usage`,
and Cost Explorer counts every request. A daily run needs about thirty a month.
Twelve is what a handful of development sessions looks like, and the machine was
powered on for three hours in the whole of August.

**What is real, so the correction does not overshoot.** The Terraform stack
plans and applies and matches its state. The `NotAction` Deny exists and the
11/11 mutations-denied run is genuine evidence, because `verify_readonly.sh` is
bash against the preinstalled AWS CLI, which is precisely why it runs on a box
where Python cannot. IMDSv2, no SSH and SSM-only administration are all true of
the managed instance. The Python is correct and tested.

The accurate sentence is that this project is **a verified piece of
infrastructure and a tested program that have never been connected to each
other.** Smaller than this file used to claim, and much larger than nothing.

### Why none of the checks caught it

`terraform plan` proves the infrastructure matches the code, and it does.
`verify_readonly.sh` proves the role cannot mutate, and it cannot. The invariant
suite proves the Python behaves as specified, and it does. **Not one of them
asks whether the program is on the machine and running.** Three correct
mechanisms, and the product lived in the space between them.

Phase 12 is the check that closes it.

## Roadmap

- ✅ Phase 0 — Account, budget guard, IAM, CLI, repository
- ✅ Phase 1 — EC2 + read-only IAM role, administered through SSM Session Manager
- ✅ Phase 2 — End-of-month spend forecast via Cost Explorer, **written and tested. Not deployed** (IA-213)
- ✅ Phase 3 — Waste detection, **written and tested. Not deployed** (IA-213)
- ✅ Phase 4 — Templated executive brief and dashboard, **written and tested. Never generated on the instance** (IA-213). Called an AI brief here until IA-209
- ✅ Phase 5 — CI in GitHub Actions
- ⬜ Phase 5b — **Scheduling on the instance. Never built** (IA-213)
- ✅ Phase 6 — **Infrastructure as Code**: the stack rebuilt in Terraform, applied plan-first
- ✅ Phase 7 — **The read-only guarantee rewritten and proven**: `NotAction` Deny in place of thirteen named actions, verified at runtime from inside the account
- ✅ Phase 8 — **An invariant suite, and CI that runs it**: 44 invariants, five of them controls, committed red and turned green
- ⬜ Phase 9 — A CI check comparing Terraform state against the account (IA-210)
- ⬜ Phase 10 — A budget alert that names the resources, the amount and one action, and escalates when it repeats (IA-211)
- ✅ Phase 11 — **`prove_it_can_fail.py`**: eleven mutations, each naming the invariants that must catch it, with two controls on the harness itself (IA-214)
- ⬜ Phase 12 — **A liveness check**: `report.json` carries `generated_at`, so anything reading it can refuse when it is stale and say so. Without this, a deployment would recreate IA-213 in a different shape

## Status

**Not deployed.** The stack is defined in code, reviewed before every change,
public, and the safety claim is verified from the account rather than asserted
in this file. The program that stack exists to run has never run on it.

This section said **"v1 complete"** until IA-209, and the whole file described a
live service until IA-213. Ten defects were recorded against this repository on
29 September 2026, and "complete" is not a word that survives that. A reader
takes it to mean nothing known is outstanding.

### What is not fixed

| | |
| --- | --- |
| IA-199 | `i-0318219b00fc4df65` is still in the account and still outside the state. Its root volume bills. Snapshot before anything is terminated: `DeleteOnTermination` is true on all four root volumes. |
| IA-202 | The forecast fix is verified against a fixture. The pair of `get-cost-and-usage` calls against the live account has not been run, so the half of that defect the fixture assumes is still assumed. |
| IA-204 | The budget notifies and does not act. That is a decision, recorded with the condition for revisiting it, not an omission. |
| IA-210 | Nothing compares the Terraform state against the account. |
| IA-211 | The alert is still a percentage, with no resource, no amount and no action. |
| IA-213 | **The Guardian has never run.** Four roadmap phases and two architecture rows described a service that was never deployed. The claims are corrected above; the deployment itself is not done, and must not be done without Phase 12. |
| IA-215 | An IAM role and instance profile outside Terraform carry `ReadOnlyAccess` with no Deny. `undeclared_resources()` sees neither: it enumerates instances and volumes only. |
| | No second person has followed this repository's runbook on a machine that is not the author's. |

## Related project

`report.json` feeds the **FinOps Copilot**, an AI agent that turns findings into
human-approved action plans:
[github.com/alexPantoja90210/agentic-copilots](https://github.com/alexPantoja90210/agentic-copilots)

The **[Migration Planner](https://github.com/alexPantoja90210/aws-migration-planner)**
estimates what a target *will* cost. This one measures what it *does* cost, from
the real account. Prediction against invoice.
