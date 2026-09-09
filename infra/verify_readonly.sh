#!/bin/bash
# Runtime proof that the Guardian role is read-only. IA-75.
#
# IA-15 success criterion 2 asks for the read-only guarantee to be verified at
# runtime, not just in the plan. The plan says what Terraform intends to submit.
# This asks AWS what it actually enforces.
#
# RUN IT ON THE INSTANCE, with no arguments. The role is trusted by
# ec2.amazonaws.com only and cannot be assumed from a laptop -- so on the box
# the ambient credentials ARE the role, which makes this the real principal in
# the real place. Do not add a human to the trust policy to make it runnable
# elsewhere: that weakens the control being verified.
#
# Written in bash against the preinstalled AWS CLI, deliberately. The first
# version needed boto3, which is not on this AMI, and installing a package onto
# the machine under audit means mutating the subject of the test. This script
# adds nothing to the box.
#
# TWO SUITES, and both must pass:
#   NEGATIVE  a mutation per service family must come back AccessDenied.
#   POSITIVE  the reads guardian.py performs must still work.
# The positive suite is the point: a policy denying everything would pass all
# ten negative checks with the collector dead -- a gate that can only report
# good news, which is the defect this project has recorded thirteen times.
#
# SAFETY: every negative probe is a DELETE of a resource that does not exist,
# or an EC2 dry run. Nothing here can create or destroy anything.
#
# THREE OUTCOMES, not two. The first version had only DENIED and NOT DENIED,
# and reported "the role can do something it must not" for four probes that had
# simply never reached the authorisation check -- a malformed instance id, a
# CLI usage error, and S3 answering 404 before 403 because it will not leak
# whether a bucket exists. That is the same defect this script exists to find:
# a check that cannot tell "refused" from "never got far enough to ask".
#
# So a probe that dies before AWS evaluates permissions is INCONCLUSIVE. It is
# never counted as a pass, it is reported loudly, and the run does not claim
# success while any remain.

set -uo pipefail

REGION="${AWS_REGION:-us-east-1}"
DENIED='AccessDenied|AccessDeniedException|UnauthorizedOperation|AuthFailure|not authorized|explicit deny'
neg_pass=0; neg_total=0; neg_incon=0
pos_pass=0; pos_total=0

# Errors proving the request never reached the authorisation decision.
PREAUTH='Malformed|InvalidID|ValidationError|ValidationException|usage: aws|Unknown options|NoSuchBucket|InvalidParameterValue'


must_deny() {
  local label="$1"; shift
  neg_total=$((neg_total + 1))
  local out rc
  out=$("$@" --region "$REGION" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    echo "  !! SUCCEEDED   $label -- the role performed a mutation"
    return
  fi
  if grep -qE 'DryRunOperation' <<<"$out"; then
    echo "  !! ALLOWED     $label -- the dry run was authorised"
    return
  fi
  if grep -qE "$DENIED" <<<"$out"; then
    echo "  DENIED        $label"
    neg_pass=$((neg_pass + 1))
    return
  fi
  if grep -qE "$PREAUTH" <<<"$out"; then
    neg_incon=$((neg_incon + 1))
    echo "  ?? INCONCLUSIVE $label -- died before AWS judged permissions: $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
    return
  fi
  echo "  !! NOT DENIED  $label -- $(tr '\n' ' ' <<<"$out" | cut -c1-200)"
}

must_work() {
  local label="$1"; shift
  pos_total=$((pos_total + 1))
  local out rc
  out=$("$@" --region "$REGION" 2>&1); rc=$?
  if [ $rc -eq 0 ]; then
    echo "  OK            $label"
    pos_pass=$((pos_pass + 1))
  else
    echo "  !! BROKEN     $label -- $(tr '\n' ' ' <<<"$out" | cut -c1-140)"
  fi
}

echo "Principal under test:"
aws sts get-caller-identity --region "$REGION" --query Arn --output text 2>&1 | sed 's/^/  /'
echo

echo "NEGATIVE -- every mutation below must be refused by AWS:"
# EC2 dry runs use THIS instance's own id, read from the metadata service. A
# well-formed, existing id means AWS evaluates permissions instead of rejecting
# the parameter, and DryRun guarantees nothing happens either way.
TOKEN=$(curl -sS -X PUT "http://169.254.169.254/latest/api/token" \
        -H "X-aws-ec2-metadata-token-ttl-seconds: 60" 2>/dev/null)
SELF=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
       http://169.254.169.254/latest/meta-data/instance-id 2>/dev/null)
SELF_AMI=$(curl -sS -H "X-aws-ec2-metadata-token: $TOKEN" \
           http://169.254.169.254/latest/meta-data/ami-id 2>/dev/null)
[ -z "$SELF" ] && { echo "  cannot read own instance id from IMDS; aborting"; exit 2; }
echo "  (EC2 probes dry-run against $SELF -- DryRun performs no action)"
echo

must_deny "ec2:RunInstances" \
  aws ec2 run-instances --image-id "$SELF_AMI" --instance-type t3.micro \
      --count 1 --dry-run
must_deny "ec2:TerminateInstances" \
  aws ec2 terminate-instances --instance-ids "$SELF" --dry-run
must_deny "ec2:CreateTags" \
  aws ec2 create-tags --resources "$SELF" --tags Key=ia75,Value=probe --dry-run
must_deny "ec2:CreateSecurityGroup" \
  aws ec2 create-security-group --group-name ia75-probe --description ia75-probe --dry-run
must_deny "iam:DeleteUser" \
  aws iam delete-user --user-name ia75-does-not-exist
# S3 is deliberately absent. DeleteBucket on a bucket that does not exist
# answers NoSuchBucket before it answers AccessDenied, by design, so it cannot
# produce a clean signal without first creating a bucket -- and creating one to
# test a delete would be a mutation. logs:DeleteLogGroup covers the same ground
# better: reads on logs ARE granted, so denying the write proves the boundary
# runs between verbs and not merely between services.
must_deny "logs:DeleteLogGroup" \
  aws logs delete-log-group --log-group-name ia75-does-not-exist
must_deny "rds:DeleteDBInstance" \
  aws rds delete-db-instance --db-instance-identifier ia75-does-not-exist --skip-final-snapshot
must_deny "lambda:DeleteFunction" \
  aws lambda delete-function --function-name ia75-does-not-exist
must_deny "dynamodb:DeleteTable" \
  aws dynamodb delete-table --table-name ia75-does-not-exist
must_deny "cloudwatch:DeleteAlarms" \
  aws cloudwatch delete-alarms --alarm-names ia75-does-not-exist
must_deny "budgets:DeleteBudget" \
  aws budgets delete-budget --account-id 000000000000 --budget-name ia75-does-not-exist

echo
echo "POSITIVE -- every read the collector depends on must still work:"
must_work "ec2:DescribeInstances" \
  aws ec2 describe-instances --max-items 5
must_work "ec2:DescribeVolumes" \
  aws ec2 describe-volumes --max-items 5
must_work "ec2:DescribeAddresses" \
  aws ec2 describe-addresses
must_work "cloudwatch:ListMetrics" \
  aws cloudwatch list-metrics --max-items 5
must_work "ce:GetCostAndUsage" \
  aws ce get-cost-and-usage --time-period Start=2026-09-01,End=2026-09-02 \
      --granularity DAILY --metrics UnblendedCost

neg_allowed=$((neg_total - neg_pass - neg_incon))

echo
echo "$neg_pass/$neg_total mutations denied - $neg_incon inconclusive - $neg_allowed allowed"
echo "$pos_pass/$pos_total reads working"

if [ "$neg_pass" -eq "$neg_total" ] && [ "$pos_pass" -eq "$pos_total" ]; then
  echo "PASS - read-only enforced by the account, collector intact."
  exit 0
fi
if [ "$neg_allowed" -gt 0 ]; then
  echo "FAIL - the role performed something it must not. This is a real finding."
fi
if [ "$neg_incon" -gt 0 ]; then
  echo "FAIL - $neg_incon probe(s) never reached the authorisation decision, so"
  echo "       this run proves nothing about them. Fix the probe, not the policy."
fi
[ "$pos_pass" -ne "$pos_total" ] && echo "FAIL - the policy is too tight and the collector is broken."
exit 1
