# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.0

# zrepair.ps1 — audit and repair container/proxy routing on the server, then smoke test.
#
# Usage:
#   zrepair <project> [<project> ...]
#
# For each project: shows compose status, starts the stack if it's down,
# validates the edge proxy's nginx config (once, if an edge project is defined),
# and smoke-tests the live domain.
#
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @()
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

$cfg    = Get-ZConfig
$EC2_IP = $cfg.ec2.ip

if ($Projects.Count -eq 0) {
    $keys = (Get-ZProjectKeys) -join ', '
    Write-Host ""
    Write-Host "Usage: zrepair <project> [<project> ...]" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $keys" -ForegroundColor Gray
    Stop-ZTracking; exit 1
}

Write-Host ""
Write-Host "=== Routing repair & diagnostics ===" -ForegroundColor Cyan
Write-Host "Target host: $EC2_IP" -ForegroundColor Gray

# Validate the edge proxy config once up front, if one is defined.
$edgeProj = Get-ZEdgeProject
if ($edgeProj -and $edgeProj.Config.proxyContainer) {
    $pc = $edgeProj.Config.proxyContainer
    Write-Host ""
    Write-Host "  [edge] Validating nginx config in proxy container '$pc'..." -ForegroundColor Yellow
    Invoke-Ec2Step -Label "nginx -t in $pc" -Bash "sudo docker exec $pc nginx -t 2>&1"
}

foreach ($key in $Projects) {
    $proj = Get-ZProject -Key $key
    $composeDir = Get-RemoteComposeDir -Key $key

    Write-Host ""
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host "=== Repairing $($proj.label) ($key) ===" -ForegroundColor Cyan
    Write-Host "=========================================" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  [1/3] Compose status on the server..." -ForegroundColor Yellow
    $statusBash = @"
cd $composeDir || exit 1
echo "Running containers:"
sudo docker compose ps
"@
    Invoke-Ec2Step -Label "Check compose status" -Bash $statusBash

    Write-Host "  [2/3] Ensuring stack is up..." -ForegroundColor Yellow
    $ensureBash = @"
cd $composeDir || exit 1
if ! sudo docker compose ps | grep -q "Up"; then
    echo "    [Action] Stack is down. Starting..."
    sudo docker compose up -d
else
    echo "    [OK] Stack is active and UP."
fi
"@
    Invoke-Ec2Step -Label "Ensure stack is up" -Bash $ensureBash

    if ($proj.domain) {
        Write-Host "  [3/3] Smoke test for https://$($proj.domain)..." -ForegroundColor Yellow
        try {
            $resp   = Invoke-WebRequest -Uri "http://$EC2_IP/" -Headers @{ Host = $proj.domain } -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5
            $status = [int]$resp.StatusCode
            if ($status -ge 200 -and $status -lt 400) {
                Write-Host "    PASS - responded with HTTP $status (Online)" -ForegroundColor Green
            } else {
                Write-Host "    WARNING - unexpected HTTP $status" -ForegroundColor Yellow
            }
        } catch {
            $status = $_.Exception.Response.StatusCode.value__
            if ($status -ge 200 -and $status -lt 500) {
                Write-Host "    PASS - responded with HTTP $status (Online/Redirect)" -ForegroundColor Green
            } else {
                Write-Host "    FAIL - smoke test failed: $($_.Exception.Message)" -ForegroundColor Red
            }
        }
    } else {
        Write-Host "  [3/3] No domain configured - skipping smoke test." -ForegroundColor DarkYellow
    }
}

Write-Host ""
Write-Host "=== Repair & diagnostics completed ===" -ForegroundColor Green
Write-Host ""
Stop-ZTracking
