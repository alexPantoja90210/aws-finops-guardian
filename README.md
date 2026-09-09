# AWS FinOps Guardian

A read-only cloud service that watches an AWS account, forecasts the end-of-month
bill, catches waste (idle EC2, orphaned EBS, unused Elastic IPs), scores account
health, and produces an AI executive brief with a prioritized, dollar-ranked
action list.

Runs on the AWS free tier. Built and documented in public.

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
- **Budget-conscious.** A zero-spend budget guards the account, with both ACTUAL
  and FORECASTED notifications. It measures **gross** consumption
  (`include_credit = false`) so promotional credits cannot hide real spend.
- **Infrastructure as Code.** The whole stack is defined in Terraform and applied
  plan-first: every change is previewed and approved before it touches the
  account. See [`infra/README.md`](infra/README.md).

## Architecture

| Piece | Role |
|---|---|
| **Terraform** (`infra/`) | Defines the entire stack. Provider pinned via a versioned `.terraform.lock.hcl`. |
| **EC2 t3.micro** | Runs `guardian.py` on a schedule. Encrypted gp3 root volume, IMDSv2 required. |
| **IAM read-only role** | An enumerated read set, plus a `NotAction` Deny on everything outside it. Attached by instance profile. |
| **Cost Explorer API** | Month-to-date and forecast spend. |
| **CloudWatch** | CPU metrics used to flag idle instances. |
| **EC2 API** | Resource inventory for orphaned volumes and unused IPs. |
| **AWS Budgets** | Zero-spend guard, credit-blind by configuration. |
| **SSM Session Manager** | Administrative access, without opening a port. |
| **nginx** | Serves the dashboard. |
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

## Roadmap

- ✅ Phase 0 — Account, budget guard, IAM, CLI, repository
- ✅ Phase 1 — EC2 + read-only IAM role, administered through SSM Session Manager
- ✅ Phase 2 — End-of-month spend forecast via Cost Explorer
- ✅ Phase 3 — Waste detection (idle EC2, orphaned EBS, unused EIP)
- ✅ Phase 4 — AI executive brief and dashboard
- ✅ Phase 5 — CI/CD automation and scheduling
- ✅ Phase 6 — **Infrastructure as Code**: the stack rebuilt in Terraform, applied plan-first
- ✅ Phase 7 — **The read-only guarantee rewritten and proven**: `NotAction` Deny in place of thirteen named actions, verified at runtime from inside the account

## Status

**v1 complete.** The stack is defined in code, reviewed before every change,
public, and the safety claim is verified from the account rather than asserted
in this file.

## Related project

`report.json` feeds the **FinOps Copilot**, an AI agent that turns findings into
human-approved action plans:
[github.com/alexPantoja90210/agentic-copilots](https://github.com/alexPantoja90210/agentic-copilots)

The **[Migration Planner](https://github.com/alexPantoja90210/aws-migration-planner)**
estimates what a target *will* cost. This one measures what it *does* cost, from
the real account. Prediction against invoice.
