<#
.SYNOPSIS
    Runs the fixed guardian.py on the Guardian instance and prints the report.

.DESCRIPTION
    IA-208 shipped six fixes whose evidence is a suite of invariants running
    against fixtures. A green suite means the logic behaves as specified. It
    does not mean the account behaves as the fixtures describe, and only a run
    under the instance role, against the real account, closes that gap.

    Same shape as run_verify_on_box.ps1 and for the same reason: the role's
    trust policy names ec2.amazonaws.com only, so it cannot be assumed from a
    laptop. The script is shipped over SSM, run under the instance profile,
    and its output brought back.

    Nothing is installed and nothing is left behind. guardian.py is written to
    /tmp on the box and report.json is produced there, not in the repository
    checkout, so the box is not mutated by being measured.

.EXAMPLE
    .\run_guardian_on_box.ps1
    .\run_guardian_on_box.ps1 -InstanceId i-0123456789abcdef0
#>
param(
    [string]$InstanceId = (terraform output -raw instance_id),
    [string]$ScriptPath = "$PSScriptRoot\..\src\guardian.py"
)

$ErrorActionPreference = "Stop"

Write-Host "Target instance: $InstanceId"

$state = aws ec2 describe-instances --instance-ids $InstanceId `
         --query "Reservations[0].Instances[0].State.Name" --output text
Write-Host "Instance state:  $state"
if ($state -ne "running") {
    Write-Host ""
    Write-Host "The instance is not running, so SSM cannot reach it." -ForegroundColor Yellow
    Write-Host "Start it, give SSM a minute to register, then re-run:"
    Write-Host "    aws ec2 start-instances --instance-ids $InstanceId"
    Write-Host ""
    Write-Host "And stop it again afterwards. A running t3.micro is the only" -ForegroundColor Yellow
    Write-Host "part of this exercise that costs more than pennies a month."
    exit 1
}

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ScriptPath))

# Sent as a file so PowerShell quoting never has to survive a round trip
# through the AWS CLI's JSON parser. Same reasoning as run_verify_on_box.ps1.
$params = @{
    commands = @(
        "echo '$b64' | base64 -d > /tmp/guardian.py",
        "cd /tmp",
        # Stated rather than assumed: if boto3 is not on the box the run must
        # say so and stop, not be diagnosed from a stack trace. Nothing is
        # installed to make it pass.
        "python3 -c 'import boto3' 2>/dev/null || { echo 'boto3 is not installed on this instance. Not installing it: putting software on the machine under audit mutates the subject of the test. See README, Proving the read-only claim.'; exit 2; }",
        "python3 /tmp/guardian.py",
        "echo '--- report.json ---'",
        "cat /tmp/report.json"
    )
} | ConvertTo-Json -Compress

$paramFile = Join-Path $env:TEMP "ia208-ssm-params.json"
Set-Content -Path $paramFile -Value $params -Encoding ASCII

$cmdId = aws ssm send-command `
    --instance-ids $InstanceId `
    --document-name "AWS-RunShellScript" `
    --comment "IA-208 run the fixed Guardian against the real account" `
    --parameters file://$paramFile `
    --query "Command.CommandId" --output text

Write-Host "SSM command: $cmdId"
Write-Host "Waiting for the box to answer..."

$status = "Pending"
for ($i = 0; $i -lt 40 -and $status -in @("Pending", "InProgress", "Delayed"); $i++) {
    Start-Sleep -Seconds 3
    $status = aws ssm get-command-invocation --command-id $cmdId `
              --instance-id $InstanceId --query "Status" --output text 2>$null
}

Write-Host ""
Write-Host "=== stdout ===" -ForegroundColor Cyan
aws ssm get-command-invocation --command-id $cmdId --instance-id $InstanceId `
    --query "StandardOutputContent" --output text

$err = aws ssm get-command-invocation --command-id $cmdId --instance-id $InstanceId `
       --query "StandardErrorContent" --output text
if ($err -and $err -ne "None" -and $err.Trim() -ne "") {
    Write-Host "=== stderr ===" -ForegroundColor Yellow
    Write-Host $err
}

Write-Host ""
Write-Host "SSM status: $status"
Remove-Item $paramFile -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Remember to stop the instance again:" -ForegroundColor Yellow
Write-Host "    aws ec2 stop-instances --instance-ids $InstanceId"

# The run's exit code is mirrored, so a Guardian that cannot run fails this
# wrapper too rather than being buried in the transcript.
if ($status -ne "Success") { exit 1 }
