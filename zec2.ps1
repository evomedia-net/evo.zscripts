# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.11

# zec2.ps1 — quick reachability check (TCP + HTTP + live build version) for deployed projects.
#
# Usage:
#   zec2 <project> [<project> ...]
#   zec2 all                      # every project with a "domain" in zconfig.json
#   zec2 viteapp -HostName 203.0.113.10
#
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @(),
    [string]$HostName = ""
)

$ErrorActionPreference = "Continue"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

$cfg = Get-ZConfig
if (-not $HostName) { $HostName = $cfg.ec2.ip }

if ($Projects.Count -eq 0) {
    Write-Host ""
    Write-Host "Usage: zec2 <project> [<project> ...] | all  [-HostName <ip>]" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $((Get-ZProjectKeys) -join ', ')" -ForegroundColor Gray
    Write-Host "  'all' checks every project with a 'domain' configured." -ForegroundColor Gray
    Stop-ZTracking; exit 1
}
if ($Projects -contains 'all') {
    $Projects = @(Get-ZProjectKeys | Where-Object { $cfg.projects.$_.domain })
    if ($Projects.Count -eq 0) {
        Write-Host "No projects with a 'domain' configured in zconfig.json." -ForegroundColor Yellow
        Stop-ZTracking; exit 1
    }
}

function Test-Zec2Reachability {
    param([string]$Label, [int]$Port, [string]$HostHeader)
    Write-Host ""
    Write-Host "=== zec2: $Label ===" -ForegroundColor Cyan
    Write-Host "  Target:  ${HostName}:${Port}$(if ($HostHeader) { "  (Host: $HostHeader)" })" -ForegroundColor Gray
    Write-Host ""

    $tcpOk = $false
    Write-Host "  [1/2] TCP connect to port ${Port}..." -ForegroundColor Yellow
    try {
        $tn = Test-NetConnection -ComputerName $HostName -Port $Port -WarningAction SilentlyContinue
        if ($tn.TcpTestSucceeded) {
            Write-Host "    OK - port ${Port} is open (TCP succeeded)" -ForegroundColor Green
            $tcpOk = $true
        } else {
            Write-Host "    FAIL - port ${Port} did not accept TCP (check firewall/security group + app on the server)" -ForegroundColor Red
        }
    } catch {
        Write-Host "    FAIL - $($_.Exception.Message)" -ForegroundColor Red
    }

    if (-not $tcpOk) { return 1 }

    $uri = "http://${HostName}:${Port}/"
    Write-Host "  [2/2] HTTP GET $uri ..." -ForegroundColor Yellow
    try {
        $headers = @{}
        if ($HostHeader) { $headers['Host'] = $HostHeader }
        $resp = Invoke-WebRequest -Uri $uri -Headers $headers -UseBasicParsing -TimeoutSec 15 -MaximumRedirection 5
        $code = [int]$resp.StatusCode
        Write-Host "    OK - HTTP $code" -ForegroundColor Green
        if ($resp.Headers["Server"]) {
            Write-Host "    Server: $($resp.Headers['Server'])" -ForegroundColor Gray
        }
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status) {
            Write-Host "    HTTP response: $status (connection worked; app may redirect or require auth)" -ForegroundColor Yellow
        } else {
            Write-Host "    FAIL - $($_.Exception.Message)" -ForegroundColor Red
            return 1
        }
    }

    Write-Host ""
    Write-Host "  Done ($Label)." -ForegroundColor Cyan
    return 0
}

# Live build version by kind: python/nextjs expose /api/build-version,
# vite/static serves /build-version.json.
function Show-Zec2LiveVersion {
    param($Proj)
    if (-not $Proj.domain) { return }
    $headers = @{ Host = $Proj.domain }
    try {
        if ($Proj.kind -eq 'vite') {
            $r = Invoke-RestMethod -Uri "http://${HostName}/build-version.json" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            if ($r) { Write-Host "    Live build: $(Get-LabelFromBuildJsonObj $r)" -ForegroundColor Gray }
        } else {
            $r = Invoke-RestMethod -Uri "http://${HostName}/api/build-version" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            if ($r -and $r.build_version) { Write-Host "    Live build: $($r.build_version)" -ForegroundColor Gray }
        }
    } catch {
        Write-Host "    (Could not read live version endpoint - see 'Enabling deploy verification' in README)" -ForegroundColor DarkGray
    }
}

$exitCode = 0
foreach ($key in $Projects) {
    $proj = Get-ZProject -Key $key
    if (-not $proj.domain) {
        Write-Host ""
        Write-Host "Skipping '$key' - no domain configured." -ForegroundColor DarkYellow
        continue
    }
    $rc = Test-Zec2Reachability -Label "$($proj.label)" -Port 80 -HostHeader $proj.domain
    if ($rc -eq 0) { Show-Zec2LiveVersion -Proj $proj }
    if ($rc -ne 0) { $exitCode = $rc }
}

Write-Host ""
Write-Host "If TCP fails: open inbound TCP in the server's firewall/security group." -ForegroundColor Cyan
Write-Host "If TCP OK but HTTP fails: SSH in and check docker/nginx (curl -sI http://127.0.0.1/)." -ForegroundColor Cyan
Write-Host ""
Stop-ZTracking; exit $exitCode
