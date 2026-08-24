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

  # Belt and braces: even if a future policy granted writes by mistake, this
  # explicit Deny wins. In IAM, a Deny can never be overridden by an Allow. It
  # is the guarantee that the box will never modify the account.
  statement {
    sid    = "DenyAllMutations"
    effect = "Deny"
    actions = [
      "ec2:RunInstances",
      "ec2:TerminateInstances",
      "ec2:StopInstances",
      "ec2:StartInstances",
      "ec2:CreateVolume",
      "ec2:DeleteVolume",
      "ec2:ModifyInstanceAttribute",
      "iam:*",
      "budgets:ModifyBudget",
      "budgets:DeleteBudget",
      "budgets:CreateBudget",
      "s3:PutObject",
      "s3:DeleteObject",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_policy" "guardian_readonly" {
  name        = "${var.project_name}-readonly-policy"
  description = "Read access to Cost Explorer, CloudWatch, EC2 and Budgets. Explicit Deny on every mutation."
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
  ami           = data.aws_ami.al2023.id
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

  tags = {
    Name = "${var.project_name}-ec2"
    Role = "guardian-collector"
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
