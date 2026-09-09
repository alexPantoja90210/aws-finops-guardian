<#
.SYNOPSIS
    Runs verify_readonly.sh on the Guardian instance and prints the result.

.DESCRIPTION
    IA-15 criterion 2 asks for the read-only guarantee to be verified at
    runtime. The role cannot be assumed from a laptop -- its trust policy names
    ec2.amazonaws.com only -- so the verification has to happen where the role
    actually lives. This ships the script over SSM, runs it under the instance
    profile, and brings the output back.

    Nothing is installed permanently and nothing is left behind: the script is
    written to /tmp on the box.

.EXAMPLE
    .\run_verify_on_box.ps1
    .\run_verify_on_box.ps1 -InstanceId i-0123456789abcdef0
#>
param(
    [string]$InstanceId = (terraform output -raw instance_id),
    [string]$ScriptPath = "$PSScriptRoot\verify_readonly.sh"
)

$ErrorActionPreference = "Stop"

Write-Host "Target instance: $InstanceId"

$state = aws ec2 describe-instances --instance-ids $InstanceId `
         --query "Reservations[0].Instances[0].State.Name" --output text
Write-Host "Instance state:  $state"
if ($state -ne "running") {
    Write-Host ""
    Write-Host "The instance is not running, so SSM cannot reach it." -ForegroundColor Yellow
    Write-Host "Start it, wait for SSM to register, then re-run:"
    Write-Host "    aws ec2 start-instances --instance-ids $InstanceId"
    exit 1
}

$b64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($ScriptPath))

# Sent as a file so PowerShell quoting never has to survive a round trip
# through the AWS CLI's JSON parser.
$params = @{
    commands = @(
        "echo '$b64' | base64 -d > /tmp/verify_readonly.sh",
        "chmod +x /tmp/verify_readonly.sh",
        "bash /tmp/verify_readonly.sh"
    )
} | ConvertTo-Json -Compress

$paramFile = Join-Path $env:TEMP "ia75-ssm-params.json"
Set-Content -Path $paramFile -Value $params -Encoding ASCII

$cmdId = aws ssm send-command `
    --instance-ids $InstanceId `
    --document-name "AWS-RunShellScript" `
    --comment "IA-75 runtime read-only verification" `
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

# The SSM command mirrors the script's own exit code, so a failed verification
# fails this wrapper too rather than being buried in the transcript.
if ($status -ne "Success") { exit 1 }
