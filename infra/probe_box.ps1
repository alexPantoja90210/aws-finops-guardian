<#
.SYNOPSIS
    Read-only probe of the Guardian instance: what is installed, what is
    scheduled, and whether guardian.py has ever produced a report there.

.DESCRIPTION
    run_guardian_on_box.ps1 refused to run because `python3 -c 'import boto3'`
    failed on the box. That establishes one thing only: boto3 is not importable
    by the python3 that an SSM shell sees. It does NOT establish that boto3 is
    absent, or that guardian.py has never run, because a virtualenv or a second
    interpreter would not be on that PATH.

    This script answers the difference. It installs nothing, writes nothing
    outside /tmp, and changes no state.

.EXAMPLE
    .\probe_box.ps1
    .\probe_box.ps1 -InstanceId i-0123456789abcdef0
#>
param(
    [string]$InstanceId = (terraform output -raw instance_id)
)

$ErrorActionPreference = "Stop"

$state = aws ec2 describe-instances --instance-ids $InstanceId `
         --query "Reservations[0].Instances[0].State.Name" --output text
Write-Host "Target instance: $InstanceId  ($state)"
if ($state -ne "running") { Write-Host "Not running; start it first." -ForegroundColor Yellow; exit 1 }

$probe = @'
echo "=== interpreters on PATH ==="
which -a python3 python pip3 pip 2>/dev/null
python3 -V 2>&1

echo
echo "=== boto3, tried against every interpreter found ==="
for p in $(which -a python3 python 2>/dev/null | sort -u); do
  printf "%-28s " "$p"
  "$p" -c 'import boto3; print("boto3", boto3.__version__)' 2>&1 | head -1
done

echo
echo "=== any boto3 on disk at all, including inside a venv ==="
find / -xdev -maxdepth 8 -type d -name boto3 2>/dev/null | head -5
echo "(empty above means none was found)"

echo
echo "=== where the project lives, if it does ==="
ls -d /opt/* /srv/* /home/*/ 2>/dev/null
find / -xdev -name guardian.py -not -path '/proc/*' 2>/dev/null | head -5
echo "(empty above means guardian.py is not on this box)"

echo
echo "=== is anything scheduled ==="
crontab -l 2>&1 | head -20
ls -la /etc/cron.d/ 2>/dev/null
systemctl list-timers --all --no-pager 2>/dev/null | head -10

echo
echo "=== has it ever produced output ==="
find / -xdev \( -name report.json -o -name dashboard.html \) -not -path '/proc/*' 2>/dev/null | head -5
echo "(empty above means no report and no dashboard exist on this box)"

echo
echo "=== nginx, which the README says serves the dashboard ==="
systemctl is-active nginx 2>&1
ls -la /usr/share/nginx/html/ 2>/dev/null | head -8

echo
echo "=== how long this machine has been up, and since when ==="
uptime
'@

$b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probe))

$params = @{
    commands = @(
        "echo '$b64' | base64 -d > /tmp/probe.sh",
        "bash /tmp/probe.sh"
    )
} | ConvertTo-Json -Compress

$paramFile = Join-Path $env:TEMP "ia213-ssm-params.json"
Set-Content -Path $paramFile -Value $params -Encoding ASCII

$cmdId = aws ssm send-command --instance-ids $InstanceId `
    --document-name "AWS-RunShellScript" `
    --comment "Read-only probe: is guardian.py runnable on this box" `
    --parameters file://$paramFile --query "Command.CommandId" --output text

# $ErrorActionPreference = "Stop" does not catch a native command's failure,
# so send-command can fail and leave $cmdId empty while the script carries on
# and polls for a command that does not exist. Checked rather than assumed.
if (-not $cmdId -or $cmdId -eq "None" -or $cmdId -match "error") {
    Write-Host ""
    Write-Host "send-command returned no command id, so there is nothing to poll." -ForegroundColor Yellow
    Write-Host "Two causes look identical here and the next two commands tell them apart:"
    Write-Host ""
    Write-Host "  # does this instance even have a role SSM could use?"
    Write-Host "  aws ec2 describe-instances --instance-ids $InstanceId ``"
    Write-Host "    --query `"Reservations[].Instances[].IamInstanceProfile.Arn`" --output text"
    Write-Host ""
    Write-Host "  # has the agent registered yet? it lags a minute or two after boot"
    Write-Host "  aws ssm describe-instance-information ``"
    Write-Host "    --query `"InstanceInformationList[].{Id:InstanceId,Ping:PingStatus}`" --output table"
    Remove-Item $paramFile -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "SSM command: $cmdId"
$status = "Pending"
for ($i = 0; $i -lt 40 -and $status -in @("Pending","InProgress","Delayed"); $i++) {
    Start-Sleep -Seconds 3
    $status = aws ssm get-command-invocation --command-id $cmdId `
              --instance-id $InstanceId --query "Status" --output text 2>$null
}

Write-Host ""
aws ssm get-command-invocation --command-id $cmdId --instance-id $InstanceId `
    --query "StandardOutputContent" --output text

$err = aws ssm get-command-invocation --command-id $cmdId --instance-id $InstanceId `
       --query "StandardErrorContent" --output text
if ($err -and $err -ne "None" -and $err.Trim() -ne "") {
    Write-Host "=== stderr ===" -ForegroundColor Yellow; Write-Host $err
}

Write-Host ""
Write-Host "SSM status: $status"
Remove-Item $paramFile -ErrorAction SilentlyContinue
