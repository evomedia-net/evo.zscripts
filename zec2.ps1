# evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.30

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
# Tracking ends on every exit, even a throw or Ctrl+C (#219); body not re-indented.
try {

$cfg = Get-ZConfig
if (-not $HostName) { $HostName = $cfg.ec2.ip }
# Needed by the container-side version read below. zec2 had no ssh of its own
# before that, so the read referenced three variables this script never
# defined -- and because it sits inside a try/catch, the failure was silent:
# it fell through to the HTTP call and reported nothing once that endpoint
# stopped being public. Same names zec2online.ps1 uses.
$PemKey    = $cfg.ec2.pemKey
$SshTarget = Get-Ec2Target

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

    # A hostname the edge has armed refuses a request that did not come through
    # CloudFront, and the GET below is one: it would report a healthy site as
    # unreachable. So that hostname is asked on the server (#263).
    if ($Port -eq 80 -and (Test-OriginArmed -HostName $HostHeader)) {
        Write-Host "  [2/2] HTTP GET for $HostHeader, asked on the server (this hostname refuses direct requests)..." -ForegroundColor Yellow
        $code = Get-OriginStatus -HostName $HostHeader
        if ($code -ge 200 -and $code -lt 400) {
            Write-Host "    OK - HTTP $code" -ForegroundColor Green
        } elseif ($code) {
            Write-Host "    HTTP response: $code (connection worked; app may redirect or require auth)" -ForegroundColor Yellow
        } else {
            Write-Host "    FAIL - the origin gave no answer" -ForegroundColor Red
            return 1
        }
        Write-Host ""
        Write-Host "  Done ($Label)." -ForegroundColor Cyan
        return 0
    }

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

# Live build version. The public endpoint differs by kind: python/nextjs
# expose /api/build-version, vite serves /build-version.json.
#
# Asked on the server first, for every kind: the endpoint is not public on
# every project, and asking the edge answers from whichever vhost matches the
# Host header. That is the project's verify block, or for a vite build the
# stamp inside its container - the vite branch used to have only the public
# probe, so a project whose stamp the edge does not publish could never be
# read (#203).
#
# The public endpoint is the fallback, and never directly for a hostname the
# edge has armed: that request is refused, and it is written to the gate log
# as an attempt to reach the origin around CloudFront (#269). It is asked on
# the server instead.
function Show-Zec2LiveVersion {
    param($Proj)
    if (-not $Proj.domain) { return }
    $path  = if ($Proj.kind -eq 'vite') { '/build-version.json' } else { '/api/build-version' }
    $label = $null

    $execCmd = Get-ServerSideVersionCommand -Proj $Proj
    if (-not $execCmd) { $execCmd = Get-ContainerStampCommand -Proj $Proj }
    $onServer = [bool]($execCmd -and (Test-Path $PemKey))
    if ($onServer) {
        try {
            $raw = (ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $PemKey $SshTarget $execCmd | Out-String)
            $label = Get-LabelFromStampText $raw
        } catch { }
    }

    $armed = Test-OriginArmed -HostName $Proj.domain
    $notPublished = $false
    if (-not $label) {
        if ($armed) {
            $label = Get-OriginBuildLabel -HostName $Proj.domain -Path $path
        } else {
            try {
                $r = Invoke-RestMethod -Uri "http://${HostName}$path" -Headers @{ Host = $Proj.domain } -TimeoutSec 10 -ErrorAction Stop
                if ($Proj.kind -eq 'vite') { $label = Get-LabelFromBuildJsonObj $r }
                elseif ($r -and $r.build_version) { $label = [string]$r.build_version }
            } catch {
                $notPublished = [bool]($_.Exception.Response -and $_.Exception.Response.StatusCode.value__ -eq 404)
            }
        }
    }

    if ($label) {
        Write-Host "    Live build: $label" -ForegroundColor Gray
    } else {
        Write-Host "    $(Get-LiveBuildUnreadReason -OnServer $onServer -Armed $armed -NotPublished $notPublished)" -ForegroundColor DarkGray
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
} finally { Stop-ZTracking -IfActive }
