# evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.32

# ZKillOnly.ps1 — stop local dev server listeners for any project in zconfig.json.
#
# Usage:
#   zkill <project> [<project> ...] [-Port N] [-KillAll]
#
# Examples:
#   zkill viteapp
#   zkill pyapp nextapp
#   zkill nextapp -KillAll     # also kill stray node/python processes referencing the project
#
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @(),
    [Alias("p")][int]$Port = 0,
    [switch]$KillAll
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking
# Tracking ends on every exit, even a throw or Ctrl+C (#219); body not re-indented.
try {

if ($Projects.Count -eq 0) {
    $keys = (Get-ZProjectKeys) -join ', '
    Write-Host ""
    Write-Host "Usage: zkill <project> [<project> ...] | all  [-Port N] [-KillAll]" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $keys" -ForegroundColor Gray
    Write-Host "  'all' stops the dev server of every project that has one." -ForegroundColor Gray
    Stop-ZTracking; exit 1
}

# Tolerate switch-style args (zkill -myproject) from muscle memory.
$Projects = @($Projects | ForEach-Object { $_.TrimStart('-') })

# 'all' -> every project that actually has a local dev server (a ports.dev).
if ($Projects -contains 'all') {
    $cfg = Get-ZConfig
    $Projects = @(Get-ZProjectKeys | Where-Object { $cfg.projects.$_.ports -and $cfg.projects.$_.ports.dev })
    if ($Projects.Count -eq 0) {
        Write-Host "No projects have a dev port to kill." -ForegroundColor Yellow
        Stop-ZTracking; exit 0
    }
    Write-Host "Killing dev servers for: $($Projects -join ', ')" -ForegroundColor Cyan
}

$anyFailed = $false
foreach ($key in $Projects) {
    $proj = Get-ZProject -Key $key
    $devPort = if ($Port -gt 0) { $Port } elseif ($proj.ports -and $proj.ports.dev) { [int]$proj.ports.dev } else { 0 }

    Write-Host ""
    Write-Host "=== zkill ($($proj.label)) ===" -ForegroundColor Cyan

    $tally = New-StopTally
    if ($devPort -gt 0) {
        Write-Host "Port: $devPort" -ForegroundColor DarkGray
        Add-StopTally $tally (Stop-ListenersOnPort -Port $devPort)
    } else {
        Write-Host "No dev port configured for '$key' - skipping port kill." -ForegroundColor DarkYellow
    }

    if ($KillAll -and $proj.localRoot) {
        Add-StopTally $tally (Stop-ProjectProcesses -ProjectRoot $proj.localRoot)
    }

    # Only what actually went counts as stopped (#292).
    if ($tally.Stopped -gt 0) {
        Write-Host "  $($tally.Stopped) process(es) stopped" -ForegroundColor Magenta
    }
    if ($tally.Failed -gt 0) {
        Write-Host "  $($tally.Failed) process(es) could not be stopped and are still running" -ForegroundColor Red
        $anyFailed = $true
    }
    if ($tally.Stopped -eq 0 -and $tally.Failed -eq 0) {
        Write-Host "  Nothing to kill" -ForegroundColor Green
    }
}

Write-Host ""
# Non-zero, so zrestart stops instead of starting a second server on a port
# that is still taken.
if ($anyFailed) {
    Write-Host "Kill incomplete." -ForegroundColor Red
    Stop-ZTracking; exit 1
}
Write-Host "Kill complete." -ForegroundColor Cyan
Stop-ZTracking
} finally { Stop-ZTracking -IfActive }
