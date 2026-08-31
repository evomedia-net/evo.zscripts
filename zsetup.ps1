# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.20

# zsetup.ps1 — prepare a project for local dev: create its Python venv and install
# dependencies (python kind), or run `npm install` (vite/nextjs). Idempotent -
# safe to re-run to refresh deps. `zstart` only warns when a venv is missing;
# this is the command that creates it.
#
# Usage:
#   zsetup <project> [<project> ...]
#   zsetup <project> -Force             # recreate the python venv from scratch
#
# Python install command (first match wins):
#   1. the project's "install" config field (e.g. "-e backend", "-r reqs.txt")
#   2. auto: pyproject.toml / setup.py -> "-e ."   |   requirements.txt -> "-r requirements.txt"

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @(),
    [switch]$Force
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

$Projects = @($Projects | ForEach-Object { $_.TrimStart('-') })

if ($Projects.Count -eq 0) {
    Write-Host ""
    Write-Host "Usage: zsetup <project> [<project> ...] [-Force]" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $((Get-ZProjectKeys) -join ', ')" -ForegroundColor Gray
    Write-Host "  Creates the python venv + installs deps (or runs npm install for vite/nextjs)." -ForegroundColor Gray
    Stop-ZTracking; exit 1
}

# pip install args for a python project: config .install, else auto-detect a
# root pyproject.toml/setup.py or requirements.txt. Empty array = unknown.
function Get-PyInstallArgs {
    param([string]$Root, $Proj)
    if ($Proj.install) { return @([string]$Proj.install -split '\s+' | Where-Object { $_ -ne '' }) }
    if ((Test-Path (Join-Path $Root "pyproject.toml")) -or (Test-Path (Join-Path $Root "setup.py"))) { return @("-e", ".") }
    if (Test-Path (Join-Path $Root "requirements.txt")) { return @("-r", "requirements.txt") }
    return @()
}

function Invoke-PythonSetup {
    param([string]$Key, [string]$Root, $Proj)
    $installArgs = Get-PyInstallArgs -Root $Root -Proj $Proj
    if ($installArgs.Count -eq 0) {
        Write-Host "  Can't determine dependencies for '$Key' (no pyproject.toml/setup.py/requirements.txt in $Root)." -ForegroundColor Red
        Write-Host "  Add an `"install`" field to the project, e.g.  `"install`": `"-e backend`"  or  `"-r requirements.txt`"." -ForegroundColor DarkGray
        return $false
    }
    $venv       = Join-Path $Root ".venv"
    $venvPython = Join-Path $venv "Scripts\python.exe"
    if ($Force -and (Test-Path -LiteralPath $venv)) {
        Write-Host "  Removing existing venv (-Force)..." -ForegroundColor DarkGray
        Remove-Item -LiteralPath $venv -Recurse -Force
    }
    if (-not (Test-Path -LiteralPath $venvPython)) {
        Write-Host "  Creating venv: $venv" -ForegroundColor Cyan
        & python -m venv $venv
        if ($LASTEXITCODE -ne 0) { Write-Host "  venv creation failed" -ForegroundColor Red; return $false }
    } else {
        Write-Host "  venv exists: $venv (installing/updating deps)" -ForegroundColor DarkGray
    }
    $pip = Join-Path $venv "Scripts\pip.exe"
    Write-Host "  pip install $($installArgs -join ' ')" -ForegroundColor Cyan
    Push-Location -LiteralPath $Root
    try { & $pip install @installArgs; $ok = ($LASTEXITCODE -eq 0) } finally { Pop-Location }
    if (-not $ok) { Write-Host "  pip install failed" -ForegroundColor Red; return $false }
    Write-Host "  $Key ready - zstart $Key will use $venvPython." -ForegroundColor Green
    return $true
}

function Invoke-NodeSetup {
    param([string]$Key, [string]$Root)
    if (-not (Test-Path -LiteralPath (Join-Path $Root "package.json"))) {
        Write-Host "  No package.json in $Root" -ForegroundColor Red; return $false
    }
    Write-Host "  npm install (in $Root)..." -ForegroundColor Cyan
    Push-Location -LiteralPath $Root
    try { & npm install; $ok = ($LASTEXITCODE -eq 0) } finally { Pop-Location }
    if (-not $ok) { Write-Host "  npm install failed" -ForegroundColor Red; return $false }
    Write-Host "  $Key node_modules ready." -ForegroundColor Green
    return $true
}

$exitCode = 0
foreach ($key in $Projects) {
    $proj = Get-ZProject -Key $key
    $root = $proj.localRoot
    Write-Host ""
    Write-Host "=== zsetup ($($proj.label)) ===" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $root)) { Write-Host "  Project root not found: $root" -ForegroundColor Red; $exitCode = 1; continue }
    switch ([string]$proj.kind) {
        "python" { if (-not (Invoke-PythonSetup -Key $key -Root $root -Proj $proj)) { $exitCode = 1 } }
        "vite"   { if (-not (Invoke-NodeSetup   -Key $key -Root $root)) { $exitCode = 1 } }
        "nextjs" { if (-not (Invoke-NodeSetup   -Key $key -Root $root)) { $exitCode = 1 } }
        default  { Write-Host "  kind '$($proj.kind)' - nothing to set up locally." -ForegroundColor DarkGray }
    }
}
Write-Host ""
Stop-ZTracking; exit $exitCode
