# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.18

# ZKiller.ps1 — kill then restart dev servers for any project in zconfig.json.
#
# Usage:
#   zrestart <project> [<project> ...] [-Port N] [-KillAll] [-NoRestart] [-Detached] [-BindHost host]
#
# Examples:
#   zrestart viteapp
#   zrestart pyapp -Detached
#
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @(),
    [Alias("p")][int]$Port = 0,
    [switch]$KillAll,
    [switch]$NoRestart,
    [switch]$Detached,
    [string]$BindHost = "127.0.0.1"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

$KillScript  = Join-Path $PSScriptRoot "ZKillOnly.ps1"
$StartScript = Join-Path $PSScriptRoot "zstart.ps1"

if ($Projects.Count -eq 0) {
    $keys = (Get-ZProjectKeys) -join ', '
    Write-Host ""
    Write-Host "Usage: zrestart <project> [<project> ...] [-Port N] [-KillAll] [-NoRestart] [-Detached] [-BindHost host]" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $keys" -ForegroundColor Gray
    Stop-ZTracking; exit 1
}

Write-Host ""
Write-Host "=== zrestart ===" -ForegroundColor Cyan

foreach ($key in $Projects) {
    Write-Host "--- $key ---" -ForegroundColor DarkCyan

    # Splat named params via a hashtable, not an array. The target scripts bind
    # $Projects with ValueFromRemainingArguments (greedy), which swallows an
    # array-splatted "-Detached"/"-KillAll" string as a literal project value
    # instead of binding the switch. Hashtable splatting binds switches reliably.
    $killParams = @{}
    if ($Port -gt 0) { $killParams.Port = $Port }
    if ($KillAll)    { $killParams.KillAll = $true }
    & $KillScript $key @killParams
    if ($LASTEXITCODE -ne 0) { Stop-ZTracking; exit $LASTEXITCODE }

    if (-not $NoRestart) {
        Start-Sleep -Seconds 1
        $startParams = @{}
        if ($Port -gt 0)               { $startParams.Port = $Port }
        if ($BindHost -ne "127.0.0.1") { $startParams.BindHost = $BindHost }
        if ($Detached)                 { $startParams.Detached = $true }
        & $StartScript $key @startParams
        if ($LASTEXITCODE -ne 0) { Stop-ZTracking; exit $LASTEXITCODE }
    }
}
Stop-ZTracking
