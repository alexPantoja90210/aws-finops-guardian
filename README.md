# AWS FinOps Guardian

A read-only cloud service that watches an AWS account, forecasts the end-of-month
bill, catches waste (idle EC2, orphaned EBS, unused Elastic IPs), scores account
health, and produces an AI executive brief with a prioritized, dollar-ranked
action list.

Runs on the AWS free tier. Built and documented in public as a LinkedIn series.

## Why

Cloud spend grows quietly: unused resources plus poor visibility. That is the
problem FinOps addresses. This is a compact, safe, governance-first take on it.

## Design Principles

- **Least privilege.** v1 is read-only. The IAM policy grants named read actions
  and adds an **explicit `Deny`** on every mutating action. A `Deny` can never be
  overridden by a later `Allow`, so the invariant does not depend on nobody
  making a mistake in the future.
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
| **Terraform** (`infra/`) | Defines the entire stack — 10 managed resources. Provider pinned via a versioned `.terraform.lock.hcl`. |
| **EC2 t3.micro** | Runs `guardian.py` on a schedule. Encrypted gp3 root volume, IMDSv2 required. |
| **IAM read-only role** | Named read actions plus an explicit `Deny` on all mutations. Attached by instance profile. |
| **Cost Explorer API** | Month-to-date and forecast spend. |
| **CloudWatch** | CPU metrics used to flag idle instances. |
| **EC2 API** | Resource inventory for orphaned volumes and unused IPs. |
| **AWS Budgets** | Zero-spend guard, credit-blind by configuration. |
| **SSM Session Manager** | Administrative access, without opening a port. |
| **nginx** | Serves the dashboard. |
| **GitHub Actions** | Deployment automation. |

## Infrastructure as Code

The stack is not clicked together. `infra/` holds `versions.tf`, `variables.tf`,
`main.tf`, `outputs.tf` and `terraform.tfvars.example`.

The workflow is **plan-first**: `terraform plan` is free and is the artifact that
gets reviewed; `apply` runs only after a human reads the plan. That ordering was
not decorative — two applies failed mid-run against real provider rules that
neither `validate` nor `plan` can see, and in both cases the state stayed
consistent and the run resumed exactly where it broke, with no orphaned
resources.

The lesson is written up in [`infra/README.md`](infra/README.md): `validate`
checks shape, `plan` checks the diff against state, and only `apply` checks that
the provider accepts the values.

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
- ✅ Phase 6 — **Infrastructure as Code**: the stack rebuilt in Terraform,
  applied plan-first, with the read-only invariant verified in a live run

## Status

**v1 complete.** The stack is defined in code, reviewed before every change, and
public.

## Related project

`report.json` feeds the **FinOps Copilot**, an AI agent that turns findings into
human-approved action plans:
[github.com/alexPantoja90210/agentic-copilots](https://github.com/alexPantoja90210/agentic-copilots)
