# Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

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

if ($Projects.Count -eq 0) {
    $keys = (Get-ZProjectKeys) -join ', '
    Write-Host ""
    Write-Host "Usage: zkill <project> [<project> ...] [-Port N] [-KillAll]" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $keys" -ForegroundColor Gray
    Stop-ZTracking; exit 1
}

foreach ($key in $Projects) {
    $proj = Get-ZProject -Key $key
    $devPort = if ($Port -gt 0) { $Port } elseif ($proj.ports -and $proj.ports.dev) { [int]$proj.ports.dev } else { 0 }

    Write-Host ""
    Write-Host "=== zkill ($($proj.label)) ===" -ForegroundColor Cyan

    $killed = 0
    if ($devPort -gt 0) {
        Write-Host "Port: $devPort" -ForegroundColor DarkGray
        $killed += Stop-ListenersOnPort -Port $devPort
    } else {
        Write-Host "No dev port configured for '$key' - skipping port kill." -ForegroundColor DarkYellow
    }

    if ($KillAll -and $proj.localRoot) {
        $killed += Stop-ProjectProcesses -ProjectRoot $proj.localRoot
    }

    if ($killed -gt 0) {
        Write-Host "  $killed process(es) stopped" -ForegroundColor Magenta
    } else {
        Write-Host "  Nothing to kill" -ForegroundColor Green
    }
}

Write-Host ""
Write-Host "Kill complete." -ForegroundColor Cyan
Stop-ZTracking
