# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.22

# zstop.ps1 — stop docker compose stacks on the server without removing data or files.
#
# Usage:
#   zstop <project> [<project> ...]
#
# Examples:
#   zstop pyapp
#   zstop viteapp nextapp edge
#
# Data volumes are preserved. Run zdeploy <project> to bring a stack back up.
#
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @()
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

$cfg = Get-ZConfig

if ($Projects.Count -eq 0) {
    $keys = (Get-ZProjectKeys) -join ', '
    Write-Host ""
    Write-Host "Usage: zstop <project> [<project> ...]" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $keys" -ForegroundColor Gray
    Stop-ZTracking; exit 1
}

foreach ($key in $Projects) {
    $proj = Get-ZProject -Key $key
    $composeDir = Get-RemoteComposeDir -Key $key

    Write-Host "`n--- Stopping $($proj.label) ---" -ForegroundColor Cyan
    $cmd = "cd $composeDir && sudo docker compose down 2>&1 || true"
    ssh -o StrictHostKeyChecking=no -i $cfg.ec2.pemKey (Get-Ec2Target) $cmd
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  WARNING: docker compose down returned exit $LASTEXITCODE for $($proj.label)" -ForegroundColor Yellow
    } else {
        Write-Host "  $($proj.label) stopped." -ForegroundColor Green
    }
}

Write-Host "`nDone. Data volumes are intact. Run zdeploy <project> to restart." -ForegroundColor DarkGray
Stop-ZTracking
