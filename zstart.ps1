# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.14

# zstart.ps1 — start local dev servers for any project defined in zconfig.json.
#
# Usage:
#   zstart <project> [<project> ...] [-Port N] [-BindHost host] [-Detached]
#
# Examples:
#   zstart pyapp
#   zstart viteapp -Port 3000
#   zstart pyapp nextapp -Detached
#
# Handlers by kind: python (python -m <startModule>, or uvicorn <startApp> for
# ASGI/FastAPI apps; prefers .venv), vite (npm run dev -- --host --port),
# nextjs (npm run dev with PORT).
#
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @(),
    [Alias("p")][int]$Port = 0,
    [string]$BindHost = "127.0.0.1",
    [switch]$Detached
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

if ($Projects.Count -eq 0) {
    $keys = (Get-ZProjectKeys) -join ', '
    Write-Host ""
    Write-Host "Usage: zstart <project> [<project> ...] [-Port N] [-Detached] [-BindHost host]" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $keys" -ForegroundColor Gray
    Stop-ZTracking; exit 1
}

function Test-PortNeedsAdmin {
    param([int]$ListenPort)
    if ($ListenPort -ge 1024) { return }
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        Write-Host "WARNING: Port $ListenPort requires Administrator privileges to bind. Run this shell as Administrator!" -ForegroundColor Red
    }
}

function Start-PythonProject {
    param([string]$Key, $Proj, [int]$ListenPort, [bool]$RunDetached, [string]$HostBind = "127.0.0.1")
    $root = $Proj.localRoot
    if (-not (Test-Path -LiteralPath $root)) { throw "Project root not found: $root" }
    $module = $Proj.startModule
    $app    = $Proj.startApp
    if (-not $module -and -not $app) {
        throw "Project '$Key' (kind=python) needs 'startModule' (python -m ...) or 'startApp' (uvicorn app:app) in zconfig.json."
    }
    Set-Location -LiteralPath $root
    $venvPython = Join-Path $root ".venv\Scripts\python.exe"
    $usingVenv  = Test-Path -LiteralPath $venvPython
    $exe = if ($usingVenv) { $venvPython } else { "python" }

    # Optional convention: if the project ships scripts/build_version_tool.py,
    # bump (or at least read) the build version on every dev start.
    $buildVersion = ""
    $versionTool = Join-Path $root "scripts\build_version_tool.py"
    if (Test-Path -LiteralPath $versionTool) {
        try {
            $bumpOut = & $exe $versionTool bump 2>$null
            if ($LASTEXITCODE -eq 0 -and $bumpOut) {
                $buildVersion = ($bumpOut | Select-Object -Last 1).ToString().Trim()
            }
        } catch { }
        if ([string]::IsNullOrWhiteSpace($buildVersion)) {
            try {
                $getOut = & $exe $versionTool get 2>$null
                if ($LASTEXITCODE -eq 0 -and $getOut) {
                    $buildVersion = ($getOut | Select-Object -Last 1).ToString().Trim()
                }
            } catch { }
        }
    }

    # startApp (uvicorn ASGI target, e.g. app.main:app) takes precedence over
    # startModule (python -m ...). uvicorn runs via the venv python's -m, and
    # gets zstart's bind-host + dev port.
    if ($app) {
        $runArgs = @("-m", "uvicorn", $app, "--host", $HostBind, "--port", "$ListenPort", "--reload")
        $what    = "uvicorn $app"
    } else {
        $runArgs = @("-m", $module)
        $what    = "python -m $module"
    }

    Write-Host ""
    Write-Host "=== zstart ($($Proj.label)) ===" -ForegroundColor Cyan
    if (-not $usingVenv) {
        Write-Host "No project venv at $root\.venv - using system 'python' (its deps may be missing)." -ForegroundColor Yellow
        Write-Host "  Create one: python -m venv .venv; .\.venv\Scripts\pip install -e ." -ForegroundColor DarkGray
    }
    Write-Host "Starting $what on port $ListenPort..." -ForegroundColor Cyan
    if (-not [string]::IsNullOrWhiteSpace($buildVersion)) {
        Write-Host "Build Version: $buildVersion" -ForegroundColor Magenta
    }

    Show-ProjectMotd -Root $root -BuildVersion $buildVersion

    Write-Host "Press Ctrl+C to stop the server" -ForegroundColor DarkGray
    Test-PortNeedsAdmin -ListenPort $ListenPort
    Write-Host ""

    if ($RunDetached) {
        Start-Process -FilePath $exe -ArgumentList $runArgs -WorkingDirectory $root | Out-Null
        Write-Host "Started in detached mode." -ForegroundColor Green
        Write-Host "Use zkill $Key to stop it." -ForegroundColor DarkGray
    } else {
        & $exe @runArgs
    }
}

function Start-ViteProject {
    param([string]$Key, $Proj, [int]$ListenPort, [string]$HostBind, [bool]$RunDetached)
    $root = $Proj.localRoot
    if (-not (Test-Path -LiteralPath $root)) { throw "Project root not found: $root" }
    if (-not (Test-Path -LiteralPath (Join-Path $root "package.json"))) {
        throw "package.json not found in $root"
    }
    Set-Location -LiteralPath $root

    Write-Host ""
    Write-Host "=== zstart ($($Proj.label) - Vite) ===" -ForegroundColor Cyan
    Write-Host "Directory: $root" -ForegroundColor DarkGray
    Write-Host "URL: http://${HostBind}:$ListenPort/" -ForegroundColor Cyan
    Write-Host ""

    if (-not (Test-Path -LiteralPath (Join-Path $root "node_modules"))) {
        Write-Host "node_modules missing - running npm install..." -ForegroundColor Yellow
        & npm install
        if ($LASTEXITCODE -ne 0) { throw "npm install failed with exit $LASTEXITCODE" }
    }

    Show-ProjectMotd -Root $root

    Write-Host "Press Ctrl+C to stop the dev server" -ForegroundColor DarkGray
    Test-PortNeedsAdmin -ListenPort $ListenPort
    Write-Host ""

    $npmArgs = @("run", "dev", "--", "--host", $HostBind, "--port", "$ListenPort")
    if ($RunDetached) {
        Start-Process -FilePath "npm" -ArgumentList $npmArgs -WorkingDirectory $root -WindowStyle Normal | Out-Null
        Write-Host "Started npm run dev in a new window (detached)." -ForegroundColor Green
        Write-Host "Use zkill $Key to free port $ListenPort." -ForegroundColor DarkGray
    } else {
        & npm @npmArgs
    }
}

function Start-NextProject {
    param([string]$Key, $Proj, [int]$ListenPort, [bool]$RunDetached)
    $root = $Proj.localRoot
    if (-not (Test-Path -LiteralPath $root)) { throw "Project root not found: $root" }
    if (-not (Test-Path -LiteralPath (Join-Path $root "package.json"))) {
        throw "package.json not found in $root"
    }
    Set-Location -LiteralPath $root

    Write-Host ""
    Write-Host "=== zstart ($($Proj.label) - Next.js) ===" -ForegroundColor Cyan
    Write-Host "Starting on port $ListenPort..." -ForegroundColor Cyan
    Write-Host ""

    Show-ProjectMotd -Root $root

    Write-Host "Press Ctrl+C to stop the server" -ForegroundColor DarkGray
    Test-PortNeedsAdmin -ListenPort $ListenPort
    Write-Host ""

    $env:PORT = "$ListenPort"
    if ($RunDetached) {
        Start-Process -FilePath "npm" -ArgumentList "run", "dev" -WorkingDirectory $root | Out-Null
        Write-Host "Started in detached mode on port $ListenPort." -ForegroundColor Green
        Write-Host "Use zkill $Key to stop it." -ForegroundColor DarkGray
    } else {
        npm run dev
    }
}

# Optional per-project pre-start steps from zconfig.json:
#   "start": { "gitPull": true, "env": { "SOME_FLAG": "1" } }
# gitPull runs 'git pull --ff-only' in the project root; env sets process
# environment variables before the server starts.
function Invoke-ProjectStartPrep {
    param($Proj)
    if (-not $Proj.start) { return }
    if ($Proj.start.env) {
        foreach ($item in $Proj.start.env.PSObject.Properties) {
            Set-Item -Path "Env:$($item.Name)" -Value ([string]$item.Value)
            Write-Host "  env $($item.Name)=$($item.Value)" -ForegroundColor DarkGray
        }
    }
    if ($Proj.start.gitPull -and (Test-Path (Join-Path $Proj.localRoot ".git"))) {
        Push-Location -LiteralPath $Proj.localRoot
        # GIT_TERMINAL_PROMPT=0 so a repo that needs credentials fails fast
        # instead of blocking the server start on a "Username for ..." prompt.
        $prev = $env:GIT_TERMINAL_PROMPT; $env:GIT_TERMINAL_PROMPT = "0"
        try {
            $pullOut = git pull --ff-only 2>&1
            $last = ($pullOut | Select-Object -Last 1)
            Write-Host "  git pull: $last" -ForegroundColor DarkGray
            if ($LASTEXITCODE -ne 0) {
                Write-Host "  Auto-pull skipped - starting with the current checkout. (git needs credentials here, or set start.gitPull=false)" -ForegroundColor Yellow
            }
        } finally {
            $env:GIT_TERMINAL_PROMPT = $prev
            Pop-Location
        }
    }
}

foreach ($key in $Projects) {
    $proj = Get-ZProject -Key $key
    $devPort = if ($Port -gt 0) { $Port } elseif ($proj.ports -and $proj.ports.dev) { [int]$proj.ports.dev } else { 3000 }

    Invoke-ProjectStartPrep -Proj $proj

    switch ([string]$proj.kind) {
        "python" { Start-PythonProject -Key $key -Proj $proj -ListenPort $devPort -HostBind $BindHost -RunDetached $Detached.IsPresent }
        "vite"   { Start-ViteProject   -Key $key -Proj $proj -ListenPort $devPort -HostBind $BindHost -RunDetached $Detached.IsPresent }
        "nextjs" { Start-NextProject   -Key $key -Proj $proj -ListenPort $devPort -RunDetached $Detached.IsPresent }
        default {
            Write-Host ""
            Write-Host "Project '$key' has kind '$($proj.kind)' - no local dev server to start." -ForegroundColor Yellow
            Write-Host "Supported kinds for zstart: python, vite, nextjs" -ForegroundColor Gray
        }
    }
}
Stop-ZTracking
