###############################################################################
# aws-finops-guardian / infra / pilot.tf
#
# Support for the IA-45 pilot: a SEPARATE, narrowly scoped role that may start
# and stop exactly one instance, and nothing else, in an account whose default
# posture is read-only.
#
# What this file deliberately does NOT do:
#   - It does not touch aws_iam_role.guardian or its DenyAllMutations policy.
#     That statement is the reason D5 holds. A pilot is not a reason to weaken
#     an invariant; it is a reason to add a second, smaller one beside it.
#   - It creates nothing at all while pilot_enabled is false, which is the
#     default. Turning the pilot on is an explicit act with a visible plan.
###############################################################################

locals {
  pilot_count = var.pilot_enabled ? 1 : 0
}

# Who may assume the injector role.
#
# By default: whoever is running Terraform, resolved from the caller identity
# the provider already has. Nobody has to look up an ARN, paste it into a chat,
# or copy an account id into a file — the identifier never leaves the machine,
# and the repository stays free of it either way.
#
# The variable remains as an override for the case where the operator running
# apply is not the operator who should hold the injector role, and for the case
# below: if Terraform runs under an ASSUMED role, aws_caller_identity returns
# an arn:aws:sts::...:assumed-role/... ARN, which IAM will not accept as a trust
# principal. Then, and only then, the underlying role or user ARN has to be
# named explicitly.
locals {
  pilot_trust_principal = (
    var.pilot_injector_principal_arn != ""
    ? var.pilot_injector_principal_arn
    : data.aws_caller_identity.current.arn
  )
}

data "aws_iam_policy_document" "pilot_injector_trust" {
  count = local.pilot_count

  statement {
    sid     = "AllowOperatorToAssume"
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "AWS"
      identifiers = [local.pilot_trust_principal]
    }
  }
}

# The grant itself.
#
# ec2:StartInstances and ec2:StopInstances support resource-level permissions,
# so they are constrained twice: to the instance ARN, and to instances carrying
# the pilot tag. Either constraint alone would be enough; both together mean an
# instance has to be BOTH this one AND still tagged for the pilot.
#
# ec2:Describe* does not support resource-level permissions — AWS evaluates it
# against "*" or not at all. That is a property of the API, not a shortcut
# taken here, and it is why the deny below matters.
data "aws_iam_policy_document" "pilot_injector" {
  count = local.pilot_count

  statement {
    sid    = "StartStopThePilotTargetOnly"
    effect = "Allow"
    actions = [
      "ec2:StartInstances",
      "ec2:StopInstances",
    ]
    resources = ["arn:aws:ec2:${var.aws_region}:${data.aws_caller_identity.current.account_id}:instance/${aws_instance.guardian.id}"]

    condition {
      test     = "StringEquals"
      variable = "aws:ResourceTag/Pilot"
      values   = [var.pilot_tag_value]
    }
  }

  statement {
    sid    = "ReadOnlyVisibility"
    effect = "Allow"
    actions = [
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeTags",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:GetMetricData",
    ]
    resources = ["*"]
  }

  # The D5 pattern, applied to this role in its own right: everything that is
  # not one of the actions above is denied outright, so a policy attached to
  # this role by mistake tomorrow still cannot widen it. An Allow can never
  # override a Deny.
  statement {
    sid    = "DenyEverythingElse"
    effect = "Deny"
    not_actions = [
      "ec2:StartInstances",
      "ec2:StopInstances",
      "ec2:DescribeInstances",
      "ec2:DescribeInstanceStatus",
      "ec2:DescribeTags",
      "cloudwatch:ListMetrics",
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:GetMetricData",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role" "pilot_injector" {
  count = local.pilot_count

  name               = "${var.project_name}-pilot-injector"
  description        = "IA-45 pilot: start/stop the pilot target only. Not a general-purpose write role."
  assume_role_policy = data.aws_iam_policy_document.pilot_injector_trust[0].json

  # An hour is longer than any injection window in the pilot design.
  max_session_duration = 3600

  tags = {
    Pilot = var.pilot_tag_value
    Issue = "IA-46"
  }

  # IAM rejects an assumed-role ARN as a trust principal, and it does so at
  # apply time with a MalformedPolicyDocument that names nothing useful. Catch
  # it at plan time instead, with a sentence that says what to do.
  lifecycle {
    precondition {
      condition     = !startswith(local.pilot_trust_principal, "arn:aws:sts::")
      error_message = "Terraform is running under an assumed role, and IAM will not accept an assumed-role ARN as a trust principal. Set pilot_injector_principal_arn in terraform.tfvars to the underlying IAM user or role ARN that should hold the injector role."
    }
  }
}

resource "aws_iam_role_policy" "pilot_injector" {
  count = local.pilot_count

  name   = "${var.project_name}-pilot-injector"
  role   = aws_iam_role.pilot_injector[0].id
  policy = data.aws_iam_policy_document.pilot_injector[0].json
}
