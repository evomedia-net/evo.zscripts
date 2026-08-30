# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.19

# setup_backup_schedule.ps1 — create a scheduled task for daily backups + OneDrive sync
#
# Usage:
#   Right-click PowerShell -> "Run as Administrator"
#   Then run: .\setup_backup_schedule.ps1
#
# This creates a task that runs zbackup_and_sync.ps1 every day at 2:00 AM

#Requires -RunAsAdministrator

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")

$cfg        = Get-ZConfig
$ScriptPath = Join-Path $cfg.paths.scriptsRoot "zbackup_and_sync.ps1"
$TaskName   = "ZScripts-Backup-And-Sync"

Write-Host ""
Write-Host "Setting up scheduled backup task..." -ForegroundColor Cyan
Write-Host ""

if (-not (Test-Path -LiteralPath $ScriptPath)) {
    Write-Host "ERROR: Script not found: $ScriptPath" -ForegroundColor Red
    Write-Host "       Check paths.scriptsRoot in zconfig.json" -ForegroundColor DarkGray
    Write-ZTrailer
    exit 1
}

$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Write-Host "Task already exists: $TaskName" -ForegroundColor Yellow
    Write-Host ""
    $deleteChoice = Read-Host "Delete and recreate? (y/n)"
    if ($deleteChoice -eq "y") {
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
        Write-Host "Deleted existing task." -ForegroundColor Green
    } else {
        Write-Host "Keeping existing task. Exiting." -ForegroundColor Yellow
        Write-ZTrailer
        exit 0
    }
}

$trigger  = New-ScheduledTaskTrigger -Daily -At "02:00"
$action   = New-ScheduledTaskAction `
    -Execute "powershell.exe" `
    -Argument "-ExecutionPolicy Bypass -NoProfile -File `"$ScriptPath`" all"
$settings = New-ScheduledTaskSettingsSet `
    -AllowStartIfOnBatteries `
    -DontStopIfGoingOnBatteries `
    -StartWhenAvailable `
    -Compatibility Win8

Write-Host "Creating scheduled task: $TaskName" -ForegroundColor Yellow
Register-ScheduledTask `
    -TaskName $TaskName `
    -Trigger $trigger `
    -Action $action `
    -Settings $settings `
    -Description "Daily backup of all projects + OneDrive sync. Runs at 2:00 AM daily." `
    -Force

Write-Host ""
Write-Host "Success! Scheduled task created." -ForegroundColor Green
Write-Host ""
Write-Host "Task Details:" -ForegroundColor Cyan
Write-Host "  Name:        $TaskName" -ForegroundColor Gray
Write-Host "  Schedule:    Daily at 2:00 AM" -ForegroundColor Gray
Write-Host "  Action:      $ScriptPath" -ForegroundColor Gray
Write-Host ""
Write-Host "To manage the task:" -ForegroundColor Gray
Write-Host "  View:        Get-ScheduledTask -TaskName '$TaskName'" -ForegroundColor DarkGray
Write-Host "  Run now:     Start-ScheduledTask -TaskName '$TaskName'" -ForegroundColor DarkGray
Write-Host "  Disable:     Disable-ScheduledTask -TaskName '$TaskName'" -ForegroundColor DarkGray
Write-Host "  Delete:      Unregister-ScheduledTask -TaskName '$TaskName'" -ForegroundColor DarkGray
Write-Host ""
