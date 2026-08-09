# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.0

# zstart_docker.ps1 — bring up a local docker compose stack from <scriptsRoot>\docker\.
#
# Usage:
#   zstart_docker [-Build] [-Attached] [-Solo]
#
#   -Build      rebuild images before starting
#   -Attached   stream logs in the foreground (default is detached)
#   -Solo       use docker-compose.solo.yml (app only, no proxy)
#
param(
    [switch]$Build,
    [switch]$Attached,
    [switch]$Solo
)

$ErrorActionPreference = "Stop"
Set-Location -Path $PSScriptRoot
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

Write-Host "=== zstart_docker ===" -ForegroundColor Cyan

$composeFileName = if ($Solo) { "docker-compose.solo.yml" } else { "docker-compose.yml" }

$dockerPing = Start-Process -FilePath "docker" -ArgumentList "info" -Wait -NoNewWindow -PassThru
if ($dockerPing.ExitCode -ne 0) {
    Write-Host ""
    Write-Host "ERROR: Docker Engine is not running or this shell cannot reach it." -ForegroundColor Red
    Write-Host "  (npipe dockerDesktopLinuxEngine missing usually means Docker Desktop is stopped or still starting.)" -ForegroundColor DarkYellow
    Write-Host ""
    Write-Host "Try:" -ForegroundColor Cyan
    Write-Host "  1. Start Docker Desktop from the Start menu; wait until it shows Running." -ForegroundColor Gray
    Write-Host "  2. If it hangs: open PowerShell as Administrator, run: wsl --shutdown" -ForegroundColor Gray
    Write-Host "     then start Docker Desktop again." -ForegroundColor Gray
    Write-Host ""
    Stop-ZTracking; exit 1
}

$composeFile = Join-Path $PSScriptRoot "docker\$composeFileName"
if (-not (Test-Path $composeFile)) {
    Write-Host "ERROR: Missing $composeFile" -ForegroundColor Red
    Stop-ZTracking; exit 1
}

$envFile = Join-Path $PSScriptRoot ".env"
if (-not (Test-Path $envFile)) {
    Write-Host "WARNING: .env not found at $envFile - compose may still start if env vars are set elsewhere." -ForegroundColor DarkYellow
}

Push-Location -Path (Join-Path $PSScriptRoot "docker")
try {
    $dcArgs = @("compose", "-f", $composeFileName, "up")
    if (-not $Attached) {
        $dcArgs += "-d"
    }
    if ($Build) {
        $dcArgs += "--build"
    }
    Write-Host "Running: docker $($dcArgs -join ' ')" -ForegroundColor DarkGray
    & docker @dcArgs
    if ($LASTEXITCODE -ne 0) {
        Stop-ZTracking; exit $LASTEXITCODE
    }
} finally {
    Pop-Location
}

Write-Host ""
Write-Host "Stack: http://localhost/" -ForegroundColor Green
if (-not $Attached) {
    Write-Host 'Logs:  docker compose -f docker/docker-compose.yml logs -f' -ForegroundColor DarkGray
    Write-Host 'Stop:  docker compose -f docker/docker-compose.yml down' -ForegroundColor DarkGray
}
Stop-ZTracking
