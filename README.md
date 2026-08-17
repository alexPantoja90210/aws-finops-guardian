# AWS FinOps Guardian

A lightweight, **read-only** cloud service that watches an AWS account,
forecasts the end-of-month bill, catches waste (idle EC2, orphaned EBS,
unused Elastic IPs), scores health, and produces an **AI executive brief**
with a prioritized, dollar-ranked action list.

Built hands-on on the AWS free tier and documented as a LinkedIn series.

## Why
Cloud cost sprawl + idle resources + zero visibility is exactly what FinOps
teams are paid to fix. This is a small, safe, governance-first take on it.

## Design principles
- **Least privilege:** v1 is strictly read-only. It cannot modify anything.
- **No secrets on the box:** the engine authenticates via an EC2 IAM role
  (instance profile) — no access keys stored anywhere.
- **Cost-safe:** a zero-spend budget alert guards the account; t2.micro only.

## Architecture (free tier)
- **EC2 t2.micro** — hosts `guardian.py` (runs on a schedule)
- **Cost Explorer API** — month-to-date spend + forecast
- **CloudWatch** — CPU metrics to detect idle instances
- **EC2 API** — inventory for orphaned EBS / unused Elastic IPs
- **nginx** — serves the dashboard
- **GitHub Actions** — CI/CD deploy on push

## Roadmap
- [x] Phase 0 — Account, budget guardrail, IAM user, CLI, repo
- [x] Phase 1 — Provision EC2 + read-only IAM role + SSH
- [x] Phase 2 — Burn-rate forecast (Cost Explorer)
- [x] Phase 3 — Waste detection (idle EC2 / orphan EBS / unused EIP)
- [x] Phase 4 — AI executive brief + dashboard
- [x] Phase 5 — CI/CD (GitHub Actions) + scheduling

## Status
✅ v1 complete — all 5 build phases shipped. Documented as a 5-part "Cloud, Hands-On" series on LinkedIn.

---
*Author: Alejandro Pantoja — IT Program & Project Manager*
