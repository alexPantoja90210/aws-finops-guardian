###############################################################################
# The FinOps Guardian stack.
#
# Project principle: the agent PROPOSES, a human APPROVES. That principle
# starts here, in IAM: the box cannot modify anything in the account, not even
# if someone asks it to. It only reads.
###############################################################################

data "aws_caller_identity" "current" {}

# Most recent Amazon Linux 2023 AMI, resolved at plan time.
# Looked up by filter instead of hardcoding an id: AMI ids differ per region
# and go stale.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.1-x86_64"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }
}

data "aws_vpc" "default" {
  default = true
}

###############################################################################
# IAM — the heart of this task.
# This is the role IA-3 and IA-4 need in order to read real AWS data.
###############################################################################

data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "guardian" {
  name               = "${var.project_name}-readonly-role"
  description        = "Read-only role for the FinOps Guardian. No write permissions by design (IA-7)."
  assume_role_policy = data.aws_iam_policy_document.assume_role.json
}

# The exact permissions the Guardian needs in order to produce report.json.
# Every block exists for a concrete reason; there are no wildcards of
# convenience.
data "aws_iam_policy_document" "guardian_readonly" {

  # Costs and waste. This is the raw material for the FinOps Copilot.
  statement {
    sid    = "CostExplorerRead"
    effect = "Allow"
    actions = [
      "ce:GetCostAndUsage",
      "ce:GetCostForecast",
      "ce:GetDimensionValues",
      "ce:GetReservationUtilization",
      "ce:GetRightsizingRecommendation",
      "ce:GetSavingsPlansUtilization",
      "ce:GetTags",
      "ce:GetUsageForecast",
      "ce:DescribeCostCategoryDefinition",
      "ce:ListCostCategoryDefinitions",
    ]
    resources = ["*"]
  }

  # Utilization metrics. Feeds both the FinOps Copilot's waste ranking and the
  # Ops Triage signals (IA-4).
  statement {
    sid    = "CloudWatchRead"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:DescribeAlarmHistory",
    ]
    resources = ["*"]
  }

  # Logs, so the IA-4 collector can read events without being able to write
  # them.
  statement {
    sid    = "CloudWatchLogsRead"
    effect = "Allow"
    actions = [
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:FilterLogEvents",
      "logs:GetLogEvents",
    ]
    resources = ["*"]
  }

  # Resource inventory. Without this there is no way to know what is running
  # and idle.
  statement {
    sid    = "EC2Inventory"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeVolumes",
      "ec2:DescribeAddresses",
      "ec2:DescribeSnapshots",
      "ec2:DescribeRegions",
      "ec2:DescribeInstanceTypes",
    ]
    resources = ["*"]
  }

  # Budget status, so the report knows how much headroom is left.
  statement {
    sid    = "BudgetsRead"
    effect = "Allow"
    actions = [
      "budgets:DescribeBudget",
      "budgets:DescribeBudgets",
      "budgets:ViewBudget",
    ]
    resources = ["*"]
  }

  # The guarantee, written as the code enforces it: this role may perform the
  # reads enumerated above, plus the SSM management-plane calls that Session
  # Manager needs, and NOTHING ELSE. In IAM a Deny can never be overridden by
  # an Allow, so this holds even if a broad policy is attached to the role by
  # mistake tomorrow.
  #
  # Written as NotAction rather than as a list of forbidden actions, because a
  # list of forbidden actions is only ever as complete as the day it was
  # written. The previous version named thirteen actions and described itself
  # as "every mutation"; rds:*, lambda:*, dynamodb:*, ec2:CreateTags and most
  # of AWS were not on it. See IA-75.
  #
  # The SSM exception is real and is stated rather than hidden.
  # AmazonSSMManagedInstanceCore is attached to this same role so the box can
  # be administered without opening SSH, and it writes instance inventory and
  # association status. Denying it would cut off access to the machine. The
  # guarantee is therefore "no mutation of this account's resources, identity
  # or billing" -- not "no write API call of any kind".
  statement {
    sid    = "DenyEverythingOutsideTheReadSet"
    effect = "Deny"
    not_actions = [
      # Cost Explorer -- must mirror CostExplorerRead above.
      "ce:GetCostAndUsage",
      "ce:GetCostForecast",
      "ce:GetDimensionValues",
      "ce:GetReservationUtilization",
      "ce:GetRightsizingRecommendation",
      "ce:GetSavingsPlansUtilization",
      "ce:GetTags",
      "ce:GetUsageForecast",
      "ce:DescribeCostCategoryDefinition",
      "ce:ListCostCategoryDefinitions",

      # CloudWatch metrics -- must mirror CloudWatchRead above.
      "cloudwatch:GetMetricData",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:ListMetrics",
      "cloudwatch:DescribeAlarms",
      "cloudwatch:DescribeAlarmHistory",

      # Logs -- must mirror CloudWatchLogsRead above.
      "logs:DescribeLogGroups",
      "logs:DescribeLogStreams",
      "logs:FilterLogEvents",
      "logs:GetLogEvents",

      # EC2 inventory -- must mirror EC2Inventory above.
      "ec2:DescribeInstances",
      "ec2:DescribeVolumes",
      "ec2:DescribeAddresses",
      "ec2:DescribeSnapshots",
      "ec2:DescribeRegions",
      "ec2:DescribeInstanceTypes",

      # Budgets -- must mirror BudgetsRead above.
      "budgets:DescribeBudget",
      "budgets:DescribeBudgets",
      "budgets:ViewBudget",

      # Session Manager. Without these the box becomes unreachable, since
      # there is no SSH ingress by design.
      "ssm:*",
      "ssmmessages:*",
      "ec2messages:*",

      # Identity read-back, so verify_readonly.sh can name the principal it is
      # testing. Grants no access to anything.
      "sts:GetCallerIdentity",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "guardian_readonly" {
  name        = "${var.project_name}-readonly-policy"
  description = "Read access to Cost Explorer, CloudWatch, Logs, EC2 and Budgets, plus the SSM management plane. Everything outside that set is explicitly denied (NotAction). See IA-75."
  policy      = data.aws_iam_policy_document.guardian_readonly.json
}

resource "aws_iam_role_policy_attachment" "guardian_readonly" {
  role       = aws_iam_role.guardian.name
  policy_arn = aws_iam_policy.guardian_readonly.arn
}

# Allows administering the box through SSM Session Manager, without opening SSH
# or storing keys. It is an AWS managed policy, limited to session operation.
resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.guardian.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

# The instance profile is what makes sure there are NO keys on the box: the
# instance obtains temporary credentials rotated by AWS.
resource "aws_iam_instance_profile" "guardian" {
  name = "${var.project_name}-instance-profile"
  role = aws_iam_role.guardian.name
}

###############################################################################
# Network — minimal Security Group.
###############################################################################

resource "aws_security_group" "guardian" {
  name = "${var.project_name}-sg"
  # NOTE: the EC2 API rejects any character outside ASCII in GroupDescription.
  # This is not a style preference: a single accented character here fails the
  # apply with InvalidParameterValue. Keep this string plain ASCII (IA-23).
  description = "Minimal access for the Guardian. Egress open to AWS APIs; ingress restricted to a single operator IP."
  vpc_id      = data.aws_vpc.default.id

  lifecycle {
    precondition {
      condition     = !var.enable_ssh || var.ssh_ingress_cidr != ""
      error_message = "enable_ssh is true but ssh_ingress_cidr is empty. Declare your IP as a /32, or set enable_ssh = false."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "ssh" {
  count = var.enable_ssh && var.ssh_ingress_cidr != "" ? 1 : 0

  security_group_id = aws_security_group.guardian.id
  description       = "SSH from the operator IP only"
  cidr_ipv4         = var.ssh_ingress_cidr
  from_port         = 22
  to_port           = 22
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "http" {
  count = var.http_ingress_cidr != "" ? 1 : 0

  security_group_id = aws_security_group.guardian.id
  description       = "nginx serving report.json, from the operator IP only"
  cidr_ipv4         = var.http_ingress_cidr
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
}

# Egress left open: the instance needs to reach the Cost Explorer, CloudWatch
# and EC2 endpoints. Restricting it would require VPC endpoints, which cost
# money and would break the zero-spend premise.
resource "aws_vpc_security_group_egress_rule" "all" {
  security_group_id = aws_security_group.guardian.id
  description       = "Egress to the AWS APIs"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

###############################################################################
# Compute.
###############################################################################

resource "aws_instance" "guardian" {
  # Pinned when var.pinned_ami_id is set, latest AL2023 otherwise.
  # See the variable's description for why the pilot requires the pin.
  ami           = var.pinned_ami_id != "" ? var.pinned_ami_id : data.aws_ami.al2023.id
  instance_type = var.instance_type
  key_name      = var.ssh_key_name != "" ? var.ssh_key_name : null

  iam_instance_profile   = aws_iam_instance_profile.guardian.name
  vpc_security_group_ids = [aws_security_group.guardian.id]

  # IMDSv2 required: closes the classic SSRF path to stealing the role's
  # credentials. With a read-only role the damage would be limited, but the
  # right posture should not depend on the blast radius being small.
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size           = var.root_volume_size_gb
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  monitoring = false

  # IA-46. Set EXPLICITLY, not left to the AWS default.
  #
  # t3 instances default to "unlimited", and this one was running that way:
  # the state showed credit_specification = unlimited with no block in this
  # file to have chosen it. Under unlimited, sustained CPU is billed as surplus
  # credits instead of draining the balance, which does two harmful things at
  # once for this account:
  #   - the CPUCreditBalance signal the pilot depends on never appears, and
  #   - load generated on purpose turns into real spend, against the very
  #     zero-spend premise the budget below exists to protect (D4).
  # "standard" makes the burst budget finite and observable, which is what both
  # the guardian and the pilot actually want.
  credit_specification {
    cpu_credits = "standard"
  }

  tags = merge(
    {
      Name = "${var.project_name}-ec2"
      Role = "guardian-collector"
    },
    # Only while the pilot is switched on. The IAM grant in pilot.tf is
    # conditioned on this tag, so removing the tag revokes the ability to
    # start or stop this instance without touching the role.
    var.pilot_enabled ? { Pilot = var.pilot_tag_value } : {},
    # IA-55. This instance is the tail of the dependency chain. A tag, not a
    # rebuild: adding user_data here would replace the machine IA-46 pinned.
    # DependsOn is deliberately absent on this node: it is the tail, and an
    # empty tag would read as "depends on nothing declared yet" rather than
    # "depends on nothing".
    var.chain_enabled ? { ChainRole = "db" } : {}
  )

  lifecycle {
    # An experiment whose target any plan can rebuild is not a controlled
    # experiment. Fail here, at plan time, rather than discovering mid-pilot
    # that the instance id in the ground-truth log refers to a dead machine.
    precondition {
      condition     = !var.pilot_enabled || var.pinned_ami_id != ""
      error_message = "pilot_enabled is true but pinned_ami_id is empty. The AL2023 data source tracks the most recent image, so any plan can replace the pilot target. Set pinned_ami_id in terraform.tfvars to the AMI the instance is running before enabling the pilot."
    }
  }
}

###############################################################################
# Zero-spend budget — the guard that makes it safe to run apply.
###############################################################################

resource "aws_budgets_budget" "zero_spend" {
  provider = aws.us_east_1

  name         = "${var.project_name}-zero-spend"
  budget_type  = "COST"
  limit_amount = var.budget_limit_usd
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Under the AWS Free Plan, credits absorb consumption, so the NET cost would
  # be zero and this budget would never alert — the cost guardian, blind in
  # exactly the account it is meant to watch. Excluding credits makes it
  # measure GROSS consumption, which is the real signal of how fast the
  # balance is burning.
  cost_types {
    include_credit = false
  }

  # Warns when ACTUAL spend crosses the threshold.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.budget_alert_threshold_percent
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = [var.budget_notification_email]
  }

  # And warns when the month's FORECAST would cross it: the alert arrives
  # before the money is spent, not after.
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = var.budget_alert_threshold_percent
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = [var.budget_notification_email]
  }
}
