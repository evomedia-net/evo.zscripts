# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.9

# zbackup_and_sync.ps1 — run backups, then sync the backups folder offsite.
#
# Usage:
#   zbackup_and_sync.ps1 <project> [<project> ...]
#   zbackup_and_sync.ps1 all                      # backup everything + sync
#
# Scheduled Task example (see setup_backup_schedule.ps1):
#   powershell -ExecutionPolicy Bypass -NoProfile -File "<scriptsRoot>\zbackup_and_sync.ps1" all

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @()
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ScriptRoot "ZHelpers.ps1")
Start-ZTracking

# Tolerate switch-style args from muscle memory; require an explicit target
# ('all' included) — same convention as zbackup/zdeploy.
$Projects = @($Projects | ForEach-Object { $_.TrimStart('-') })
if ($Projects.Count -eq 0) {
    $keys = (Get-ZProjectKeys) -join ', '
    Write-Host ""
    Write-Host "Usage: zbackup_and_sync <project> [<project> ...] | all" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $keys" -ForegroundColor Gray
    Write-Host "  'all' backs up every project plus the scripts folder, then syncs offsite." -ForegroundColor Gray
    Stop-ZTracking; exit 1
}

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Backup & Sync - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "[1/2] Running backups..." -ForegroundColor Yellow
$backupPath = Join-Path $ScriptRoot "zbackup.ps1"
& powershell -NoProfile -File $backupPath @Projects
$backupExitCode = $LASTEXITCODE

if ($backupExitCode -ne 0) {
    Write-Host "Backup failed (exit code: $backupExitCode)" -ForegroundColor Red
    Stop-ZTracking; exit $backupExitCode
}

Write-Host ""
Write-Host "[2/2] Syncing offsite..." -ForegroundColor Yellow
$syncPath = Join-Path $ScriptRoot "zsync.ps1"
& powershell -NoProfile -File $syncPath
$syncExitCode = $LASTEXITCODE

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
if ($syncExitCode -eq 0) {
    Write-Host "      Backup & Sync Complete [OK]" -ForegroundColor Green
} else {
    Write-Host "      Sync had issues (exit code: $syncExitCode)" -ForegroundColor Yellow
}
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Stop-ZTracking; exit $syncExitCode
