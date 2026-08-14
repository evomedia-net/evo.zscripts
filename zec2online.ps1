# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.11

# zec2online.ps1 — deep health check: verify apps are live AND running the expected
# build; auto-start downed stacks via docker compose and stream diagnostics.
#
# Usage:
#   zec2online <project> [<project> ...]
#   zec2online all                      # every project with a "domain" in zconfig.json
#
# Verification compares the LOCAL build version against what the server is actually
# serving. A plain HTTP-200 check passes even when a stale cached build is live —
# the version match is what proves the deployed build is the one running.
#
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @(),
    [string]$HostName = ""
)

$ErrorActionPreference = 'SilentlyContinue'
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

$cfg = Get-ZConfig
if (-not $HostName) { $HostName = $cfg.ec2.ip }
$PemKey   = $cfg.ec2.pemKey
$SshTarget = Get-Ec2Target
$edgeProj = Get-ZEdgeProject

if ($Projects.Count -eq 0) {
    Write-Host ""
    Write-Host "Usage: zec2online <project> [<project> ...] | all  [-HostName <ip>]" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $((Get-ZProjectKeys) -join ', ')" -ForegroundColor Gray
    Write-Host "  'all' deep-checks every project with a 'domain' (and auto-starts any that are down)." -ForegroundColor Gray
    Stop-ZTracking; exit 1
}
if ($Projects -contains 'all') {
    $Projects = @(Get-ZProjectKeys | Where-Object { $cfg.projects.$_.domain })
    if ($Projects.Count -eq 0) {
        Write-Host "No projects with a 'domain' configured in zconfig.json." -ForegroundColor Yellow
        Stop-ZTracking; exit 1
    }
}

# ── Version helpers ──────────────────────────────────────────────────────────

function Get-LocalVersionLabel {
    param($Proj)
    switch ([string]$Proj.kind) {
        "python" {
            $tool = Join-Path $Proj.localRoot "scripts\build_version_tool.py"
            if (Test-Path $tool) {
                try {
                    $out = python $tool get 2>$null
                    if ($LASTEXITCODE -eq 0 -and $out) {
                        $val = ($out | Select-Object -Last 1).ToString().Trim()
                        if ($val) { return $val }
                    }
                } catch { }
            }
            $bvFile = Join-Path $Proj.localRoot ".build_version"
            if (Test-Path $bvFile) {
                $val = (Get-Content $bvFile -ErrorAction SilentlyContinue | Select-Object -Last 1)
                if ($val) { return $val.Trim() }
            }
            return "unknown"
        }
        "vite" {
            $j = Read-JsonBuildVersion (Join-Path $Proj.localRoot "build-version.json")
            if ($j) { return Get-LabelFromBuildJsonObj $j }
            return "unknown"
        }
        "nextjs" {
            $j = Read-JsonBuildVersion (Join-Path $Proj.localRoot "public\build-version.json")
            if ($j) { return Get-LabelFromBuildJsonObj $j }
            return "unknown"
        }
        default { return "unknown" }
    }
}

function Get-RemoteVersionLabel {
    param($Proj)
    $headers = @{}
    if ($Proj.domain) { $headers['Host'] = $Proj.domain }
    try {
        if ($Proj.kind -eq 'vite') {
            $r = Invoke-RestMethod -Uri "http://${HostName}/build-version.json" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            if ($r) { return Get-LabelFromBuildJsonObj $r }
        } else {
            $r = Invoke-RestMethod -Uri "http://${HostName}/api/build-version" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            if ($r -and $r.build_version) { return [string]$r.build_version }
        }
    } catch { }
    # python fallback: read the recorded version file over SSH
    if ($Proj.kind -eq 'python' -and (Test-Path $PemKey) -and $Proj.remote.path) {
        try {
            $out = ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $PemKey $SshTarget "cat $($Proj.remote.path)/.build_version 2>/dev/null || true"
            if ($LASTEXITCODE -eq 0 -and $out) {
                $val = ($out | Select-Object -Last 1).ToString().Trim()
                if ($val) { return $val }
            }
        } catch { }
    }
    return "unknown"
}

function Compare-BuildVersions {
    param([string]$Key, [string]$Local, [string]$Server)
    if ($Local -eq "unknown" -and $Server -eq "unknown") {
        Write-Host "  Version: unable to determine local or server version (see 'Enabling deploy verification' in README)" -ForegroundColor DarkGray
    } elseif ($Local -eq "unknown") {
        Write-Host "  Server:  $Server" -ForegroundColor Magenta
        Write-Host "  Local:   unknown (could not read local build version)" -ForegroundColor DarkGray
    } elseif ($Server -eq "unknown") {
        Write-Host "  Local:   $Local" -ForegroundColor Magenta
        Write-Host "  Server:  unknown (could not read server build version)" -ForegroundColor DarkGray
    } elseif ($Local -eq $Server) {
        Write-Host "  Version: $Server (local and server match)" -ForegroundColor Green
    } else {
        Write-Host "  Local:   $Local" -ForegroundColor Magenta
        Write-Host "  Server:  $Server" -ForegroundColor Magenta
        Write-Host "  WARNING: local and server versions differ - redeploy with: zdeploy $Key" -ForegroundColor Yellow
    }
}

# ── HTTP / recovery helpers ──────────────────────────────────────────────────

function Test-HttpOnline {
    param([int]$Port, [string]$HostHeader)
    $tn = Test-NetConnection -ComputerName $HostName -Port $Port -WarningAction SilentlyContinue -InformationLevel Quiet 2>$null
    if (-not $tn) { return $false }
    try {
        $headers = @{}
        if ($HostHeader) { $headers['Host'] = $HostHeader }
        $resp = Invoke-WebRequest -Uri "http://${HostName}:${Port}/" -Headers $headers -UseBasicParsing -TimeoutSec 8 -MaximumRedirection 5 -ErrorAction Stop
        if ($resp.StatusCode -lt 500) {
            Write-Host "  HTTP $($resp.StatusCode) - service reachable." -ForegroundColor DarkGreen
            return $true
        }
        Write-Host "  HTTP $($resp.StatusCode) - unexpected server response." -ForegroundColor DarkYellow
        return $false
    } catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -ge 300 -and $status -lt 500) {
            Write-Host "  HTTP $status - redirect from app, server is live." -ForegroundColor DarkGreen
            return $true
        }
        return $false
    }
}

function Invoke-DockerStart {
    param([string]$StartCmd)
    if (-not (Test-Path $PemKey)) {
        Write-Host "  Cannot start: PEM key not found at: $PemKey" -ForegroundColor Red
        return $false
    }
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $PemKey $SshTarget $StartCmd
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  SSH failed (exit $LASTEXITCODE). Check connectivity and PEM key." -ForegroundColor Red
        return $false
    }
    return $true
}

function Show-Diagnostics {
    param([string]$Key, $Proj, [string]$Reason)
    if (-not (Test-Path $PemKey)) {
        Write-Host "  Diagnostics skipped: PEM key not found at $PemKey" -ForegroundColor DarkGray
        return
    }
    $composeDir = Get-RemoteComposeDir -Key $Key
    Write-Host ''
    Write-Host "  --- $Key diagnostics ($Reason) ---" -ForegroundColor Magenta
    $lines = @(
        "echo '== services =='; cd $composeDir 2>/dev/null && sudo docker compose ps",
        "echo '== uptime / df =='; uptime; df -h /",
        "echo '== oom =='; dmesg -T 2>/dev/null | grep -iE 'oom|killed' | tail -n 10",
        "echo '== app logs (80) =='; cd $composeDir 2>/dev/null && sudo docker compose logs --tail 80"
    )
    if ($edgeProj -and $edgeProj.Config.proxyContainer) {
        $pc = $edgeProj.Config.proxyContainer
        $lines += "echo '== edge proxy state =='; sudo docker ps --filter name=$pc --format 'table {{.Names}}\t{{.Status}}\t{{.Ports}}'"
        $lines += "echo '== edge proxy logs (40) =='; sudo docker logs --tail 40 $pc 2>&1 | tail -n 40"
    }
    ssh -o StrictHostKeyChecking=no -o ConnectTimeout=15 -i $PemKey $SshTarget ($lines -join '; ')
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Diagnostics SSH failed (exit $LASTEXITCODE)." -ForegroundColor DarkYellow
    }
    Write-Host "  --- end $Key diagnostics ---" -ForegroundColor Magenta
    Write-Host ''
}

function Wait-UntilOnline {
    param([scriptblock]$TestFn, [int]$Seconds = 30)
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 3
        Write-Host '      checking...' -ForegroundColor DarkGray
        if (& $TestFn) { return $true }
    }
    return $false
}

function Invoke-OnlineCheck {
    param([string]$Key, $Proj)

    Write-Host ''
    Write-Host "=== zec2online: $($Proj.label) ($Key) ===" -ForegroundColor Cyan
    Write-Host "  Target: http://${HostName}/  (Host: $($Proj.domain))" -ForegroundColor Gray
    Write-Host ''

    Write-Host '  [1] Checking TCP + HTTP...' -ForegroundColor Yellow
    if (Test-HttpOnline -Port 80 -HostHeader $Proj.domain) {
        Compare-BuildVersions -Key $Key -Local (Get-LocalVersionLabel $Proj) -Server (Get-RemoteVersionLabel $Proj)
        Write-Host "  UP - $($Proj.label) is running." -ForegroundColor Green
        Write-Host ''
        return 0
    }

    Write-Host '  DOWN - Service not responding.' -ForegroundColor Red
    Show-Diagnostics -Key $Key -Proj $Proj -Reason 'DOWN before recovery'

    Write-Host '  [2] Starting stack (and edge proxy if defined)...' -ForegroundColor Yellow
    $composeDir = Get-RemoteComposeDir -Key $Key
    $startLines = @(
        "sudo docker network create web 2>/dev/null || true",
        "if [ -f $composeDir/docker-compose.yml ]; then cd $composeDir && sudo docker compose up -d 2>&1 | tail -10; else echo 'compose missing at $composeDir'; exit 2; fi"
    )
    if ($edgeProj -and $edgeProj.Config.remote.path) {
        $edgeDir = $edgeProj.Config.remote.path
        $startLines += "if [ -f $edgeDir/docker-compose.yml ]; then cd $edgeDir && sudo docker compose up -d 2>&1 | tail -10; fi"
    }
    if (-not (Invoke-DockerStart -StartCmd ($startLines -join '; '))) { return 1 }

    Write-Host ''
    Write-Host '  [3] Waiting for service (up to 30s)...' -ForegroundColor Yellow
    $domain = $Proj.domain
    $online = Wait-UntilOnline -TestFn { Test-HttpOnline -Port 80 -HostHeader $domain }.GetNewClosure()

    Write-Host ''
    if ($online) {
        Compare-BuildVersions -Key $Key -Local (Get-LocalVersionLabel $Proj) -Server (Get-RemoteVersionLabel $Proj)
        Write-Host "  UP - $($Proj.label) is now running." -ForegroundColor Green
        return 0
    }

    Write-Host '  TIMEOUT - Service did not respond within 30 seconds.' -ForegroundColor Red
    Show-Diagnostics -Key $Key -Proj $Proj -Reason 'recovery TIMEOUT'
    return 1
}

$exitCode = 0
foreach ($key in $Projects) {
    $proj = Get-ZProject -Key $key
    if (-not $proj.domain) {
        Write-Host ""
        Write-Host "Skipping '$key' - no domain configured." -ForegroundColor DarkYellow
        continue
    }
    $rc = Invoke-OnlineCheck -Key $key -Proj $proj
    if ($rc -ne 0) { $exitCode = $rc }
}

Stop-ZTracking; exit $exitCode
