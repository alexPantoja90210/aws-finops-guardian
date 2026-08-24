# `infra/` — the FinOps Guardian stack in Terraform

Infrastructure as code for the service that produces `report.json`.

The project's guiding principle — **the agent proposes, a human approves** — does not start in the agent's code. It starts here, in IAM: the instance cannot modify anything in the account, even if someone asks it to.

---

## What it provisions

| Resource | Purpose |
|---|---|
| EC2 `t3.micro` + encrypted 8 GB gp3 EBS | The box that runs the collector and serves `report.json` |
| Read-only IAM role + instance profile | Temporary credentials, no keys on disk |
| Minimal Security Group | HTTP/80 from the operator's IP only; egress open to the AWS APIs |
| Zero-spend budget | Email alert on actual **and** forecasted spend |

Ten resources in total, counting the policy attachments and the SG rules.

---

## Usage

### Requirements

- Terraform >= 1.6
- AWS CLI configured with credentials that can create IAM, EC2 and Budgets

### First run

```bash
cp terraform.tfvars.example terraform.tfvars
curl -s https://checkip.amazonaws.com          # your public IP
# edit terraform.tfvars: your IP as a /32, and your email
terraform init
terraform validate
terraform plan -out=tfplan
terraform apply tfplan
```

`plan` creates nothing and costs nothing. **Always review it before applying.**

### What to check in the plan

1. `aws_iam_policy.guardian_readonly` — that no statement with `Effect: "Allow"` contains `Put*`, `Create*`, `Delete*`, `Modify*` or `Terminate*` actions.
2. `cidr_ipv4` in the ingress rules — it must be your `/32`. If you see `0.0.0.0/0`, stop.
3. `aws_budgets_budget.zero_spend` — two `notification` blocks (`ACTUAL` and `FORECASTED`) and `cost_types.include_credit = false`.
4. The final count — all `to add`. Any unexpected `destroy` means the state is not clean.

### Reaching the instance

There is no SSH by default. Administration goes through Session Manager:

```bash
aws ssm start-session --target $(terraform output -raw instance_id)
```

Requires the [Session Manager plugin](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager-working-with-install-plugin.html), or connect from the EC2 web console → Connect → Session Manager.

To enable SSH, set `enable_ssh = true` and an `ssh_key_name` for an existing key pair. Not recommended: SSM covers the case without opening ports or guarding a private key.

### Tearing it down

```bash
terraform destroy
```

---

## Verifying the security invariant

This is the proof that the stack does what it claims. From inside the instance:

```bash
aws sts get-caller-identity
# → assumed-role/finops-guardian-readonly-role/<instance-id>
#   The instance assumed the role on its own. There are no credentials on disk.

aws ec2 describe-instances --region us-east-1
# → works. The box can see the whole account.

aws ec2 stop-instances --instance-ids <its-own-id> --region us-east-1
# → UnauthorizedOperation ... with an explicit deny in an identity-based policy
```

Look at the exact wording of the error: **"explicit deny"**. AWS is not saying "I never granted you that permission", it is saying "I denied it to you". That difference is what holds the design up.

---

## Design decisions

Each one exists for a concrete reason.

### An explicit `Deny` on top of not granting writes

The policy could simply grant reads and nothing else. It also carries a `DenyAllMutations` statement that explicitly denies the destructive actions.

In IAM, **a `Deny` can never be overridden by an `Allow`**. If someone attaches a permissive policy to this role tomorrow by mistake, the role still cannot touch the account. The invariant does not depend on nobody making a mistake later — which is the only kind of invariant that holds.

### IMDSv2 required

`http_tokens = "required"` and `http_put_response_hop_limit = 1`.

This closes the classic SSRF path to stealing the role's credentials. With a read-only role the damage would be limited, but the right posture should not depend on the blast radius being small.

### `validation` blocks on the variables

- `instance_type` only accepts free-tier types.
- `ssh_ingress_cidr` explicitly rejects `0.0.0.0/0`.
- `budget_notification_email` requires a well-formed address.

The error shows up in `plan` — for free — instead of on the bill or on an open port. These validations have already earned their keep: when `t2.micro` turned out not to be eligible, the fix was one line in `tfvars`, because `t3.micro` was already within the allowed set.

### Budget with `include_credit = false`

Under the AWS Free Plan, credits absorb consumption and the net cost is zero. A budget with default settings **would never alert** — the cost guardian, blind in exactly the account it is meant to watch.

Excluding credits makes it measure gross consumption, which is the real signal of how fast the balance is burning.

### AMI resolved by filter

`data.aws_ami.al2023` looks up the most recent one at plan time instead of hardcoding an id. AMI ids differ per region and go stale.

### Egress left open, on purpose

Restricting it would require VPC endpoints, which cost money and would break the zero-spend premise. It is a conscious trade-off, not an oversight.

### `AmazonSSMManagedInstanceCore` — the honest caveat

This managed policy includes three write-shaped actions: `ssm:UpdateInstanceInformation`, `ssmmessages:CreateControlChannel` and `ssmmessages:CreateDataChannel`. They do not mutate account resources — they open the session channel.

It is accepted knowingly: it is the price of having no private keys and no administrative ports open. A role that is perfectly read-only on paper, with an SSH key sitting on a disk, would be worse posture in practice.

---

## Provider API rules that `terraform validate` cannot catch

Two defects found during the first `apply`, both invisible to `validate` and `plan`:

- **A Security Group's `GroupDescription` only accepts ASCII.** A single accented character fails the `apply` with `InvalidParameterValue`. IAM does accept non-ASCII, so the restriction is not uniform across AWS — which is why the error surfaces halfway through the run.
- **Free-tier eligibility for an instance type is evaluated at `RunInstances`.** There is no way to know beforehand. Check it with `aws ec2 describe-instance-types --filters Name=free-tier-eligible,Values=true`.

The general lesson: **`validate` checks shape, `plan` checks the diff against state, and only `apply` checks that the provider accepts the values.** That is the argument for applying under supervision rather than automatically — each failure left the state consistent and let the run resume exactly where it broke, with no orphaned resources.

---

## Files that are never committed

`terraform.tfvars` · `terraform.tfstate*` · `.terraform/` · `tfplan` · `plan-*.txt`

The last two matter more than they look: **they contain the operator's public IP** inside the security group rules. This is a public repository; publishing them would serve up a map of the attack surface. Plan evidence lives in Jira attachments, not here.

`.terraform.lock.hcl` **is** versioned: it pins the provider hash and is what makes the plan reproducible.

---

## Free Plan warning

The account runs under the AWS **Free Plan**: 6 months, or until the credits run out — whichever comes first.

On expiry, **AWS closes the account automatically** and access to resources and data is lost; content is retained for 90 days before permanent deletion. Migrating to a paid plan within that window is the only thing that prevents it.

Every piece of infrastructure described here carries that expiry date.

---

## References

- Origin issue: **IA-7**
- Defects found: **IA-23** (non-ASCII in `GroupDescription`), **IA-24** (instance type not free-tier eligible)
- Consumers of `guardian_role_arn`: **IA-3** (FinOps Copilot), **IA-4** (Ops Triage)
