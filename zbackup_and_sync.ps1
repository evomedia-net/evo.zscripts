# Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# zbackup_and_sync.ps1 — run backups, then sync the backups folder offsite.
#
# Usage:
#   zbackup_and_sync.ps1                          # backup everything + sync
#   zbackup_and_sync.ps1 <project> [<project> ...]
#
# Scheduled Task example (see setup_backup_schedule.ps1):
#   powershell -ExecutionPolicy Bypass -NoProfile -File "<scriptsRoot>\zbackup_and_sync.ps1"

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @()
)

$ErrorActionPreference = "Stop"
$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Definition
. (Join-Path $ScriptRoot "ZHelpers.ps1")
Start-ZTracking

Write-Host ""
Write-Host "============================================" -ForegroundColor Cyan
Write-Host "   Backup & Sync - $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -ForegroundColor Cyan
Write-Host "============================================" -ForegroundColor Cyan
Write-Host ""

Write-Host "[1/2] Running backups..." -ForegroundColor Yellow
$backupPath = Join-Path $ScriptRoot "zbackup.ps1"
if ($Projects.Count -gt 0) {
    & powershell -NoProfile -File $backupPath @Projects
} else {
    & powershell -NoProfile -File $backupPath
}
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
