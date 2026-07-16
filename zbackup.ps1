# Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# zbackup.ps1 — local backups: zip project sources (plus a Postgres dump when the
# project's .env has a DATABASE_URL) into the backups folder.
#
# Usage:
#   zbackup                              # every project in zconfig.json + this scripts folder
#   zbackup <project> [<project> ...]
#   zbackup scripts                      # just this scripts folder ('scripts' is a reserved word)
#   zbackup pyapp -Tag "pre-migration"
#
# Output: <paths.backupsLocal>\<project>\<timestamp>_<project>[_tag].zip

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @(),
    [string]$Tag = ""
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

$cfg = Get-ZConfig
$ProjectsBackupRoot = $cfg.paths.backupsLocal

$includeScripts = $false
if ($Projects.Count -eq 0) {
    $Projects = @(Get-ZProjectKeys)
    $includeScripts = $true
} elseif ($Projects -contains 'scripts') {
    $Projects = @($Projects | Where-Object { $_ -ne 'scripts' })
    $includeScripts = $true
}

function Get-BackupTimestamp { return Get-Date -Format "yyyyMMdd-HHmmss" }

function Get-TagSuffix {
    if ([string]::IsNullOrWhiteSpace($Tag)) { return "" }
    return "_" + ($Tag.Trim() -replace '\s+', '_')
}

function Ensure-BackupDir {
    param([string]$ProjectKey)
    $dir = Join-Path $ProjectsBackupRoot $ProjectKey
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

# Dump the project's Postgres database if its .env declares a DATABASE_URL.
# Checks <root>\.env, then <root>\backend\.env (frontend/backend split projects).
function Invoke-LocalPgDump {
    param([string]$Root, [string]$OutPath)
    $envFile = Join-Path $Root ".env"
    if (-not (Test-Path -LiteralPath $envFile)) { $envFile = Join-Path $Root "backend\.env" }
    if (-not (Test-Path -LiteralPath $envFile)) { return $false }
    $dbLine = @(Get-Content -LiteralPath $envFile | Where-Object { $_ -match "^DATABASE_URL=" } | Select-Object -First 1)
    if ($dbLine.Count -eq 0) { return $false }

    $dbUrl = ($dbLine[0] -replace "^DATABASE_URL=", "").Trim()
    $dbUrl = $dbUrl -replace '^postgresql\+[^:]+://', 'postgresql://'
    $rx = [regex]::Match(
        $dbUrl,
        '^postgresql://(?<user>[^:]+):(?<pass>[^@]+)@(?<host>[^:]+):(?<port>\d+)/(?<db>[^?]+)'
    )
    if (-not $rx.Success) {
        Write-Host '    Could not parse DATABASE_URL - skipping PG backup' -ForegroundColor Red
        return $false
    }
    $env:PGPASSWORD = [Uri]::UnescapeDataString($rx.Groups['pass'].Value)
    $pgUser = $rx.Groups['user'].Value
    $pgHost = $rx.Groups['host'].Value
    $pgPort = $rx.Groups['port'].Value
    $pgDb   = $rx.Groups['db'].Value

    $pgDump = "pg_dump"
    $pgBinPaths = @(
        "C:\Program Files\PostgreSQL\18\bin\pg_dump.exe",
        "C:\Program Files\PostgreSQL\17\bin\pg_dump.exe",
        "C:\Program Files\PostgreSQL\16\bin\pg_dump.exe",
        "C:\Program Files\PostgreSQL\15\bin\pg_dump.exe"
    )
    foreach ($candidate in $pgBinPaths) {
        if (Test-Path $candidate) { $pgDump = $candidate; break }
    }
    & $pgDump -h $pgHost -p $pgPort -U $pgUser -d $pgDb -F p -f $OutPath 2>$null
    $ok = ($LASTEXITCODE -eq 0) -and (Test-Path -LiteralPath $OutPath)
    Remove-Item Env:\PGPASSWORD -ErrorAction SilentlyContinue
    if ($ok) {
        $size = [math]::Round((Get-Item $OutPath).Length / 1KB, 1)
        Write-Host "    PostgreSQL dump: ${size} KB" -ForegroundColor Green
    } else {
        Write-Host "    pg_dump failed (exit $LASTEXITCODE)" -ForegroundColor Red
    }
    return $ok
}

function Invoke-ProjectBackup {
    param([string]$Key)
    $proj    = Get-ZProject -Key $Key
    $root    = $proj.localRoot
    $ts      = Get-BackupTimestamp
    $suffix  = Get-TagSuffix
    $outDir  = Ensure-BackupDir -ProjectKey $Key
    $zipPath = Join-Path $outDir "${ts}_${Key}${suffix}.zip"

    Write-Host ""
    Write-Host "=== [$($Key.ToUpper())] Local backup ($($proj.label)) ===" -ForegroundColor Cyan
    Write-Host "  Output: $zipPath" -ForegroundColor Gray

    if (-not (Test-Path -LiteralPath $root)) { throw "$($proj.label) root not found: $root" }

    $dumpDir = Join-Path $env:TEMP "zbackup_${Key}_dump_$ts"
    if (Test-Path $dumpDir) { Remove-Item $dumpDir -Recurse -Force }
    New-Item -ItemType Directory -Path $dumpDir -Force | Out-Null

    try {
        $extraFiles = @()
        Write-Host "  [1/3] Checking for a local database to dump..." -ForegroundColor Yellow
        $dbDumpPath = Join-Path $dumpDir "database_pg.sql"
        if (Invoke-LocalPgDump -Root $root -OutPath $dbDumpPath) {
            $extraFiles += $dbDumpPath
        } else {
            Write-Host "    No local DATABASE_URL - source-only backup." -ForegroundColor DarkGray
        }

        Write-Host "  [2/3] Archiving source..." -ForegroundColor Yellow
        New-ProjectArchive -SourcePath $root -DestinationZip $zipPath `
            -TopLevelExclude (Get-ArchiveExcludes -Project $proj -ForBackup) -ExtraFiles $extraFiles

        Write-Host "  [3/3] Done." -ForegroundColor Yellow
        $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
        return @{ ok = $true; path = $zipPath; sizeMb = $zipSize }
    }
    finally {
        if (Test-Path $dumpDir) { Remove-Item $dumpDir -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

function Invoke-ScriptsBackup {
    $ts      = Get-BackupTimestamp
    $suffix  = Get-TagSuffix
    $outDir  = Ensure-BackupDir -ProjectKey "scripts"
    $zipPath = Join-Path $outDir "${ts}_scripts${suffix}.zip"
    $scriptsRoot = $cfg.paths.scriptsRoot

    Write-Host ""
    Write-Host "=== [SCRIPTS] Local backup (this scripts folder) ===" -ForegroundColor Cyan
    Write-Host "  Output: $zipPath" -ForegroundColor Gray

    if (-not (Test-Path -LiteralPath $scriptsRoot)) { throw "Scripts root not found: $scriptsRoot" }

    Write-Host "  [1/2] Archiving source..." -ForegroundColor Yellow
    New-ProjectArchive -SourcePath $scriptsRoot -DestinationZip $zipPath `
        -TopLevelExclude @(".git", "archive", "tmp", "nul") -IncludeScriptFiles

    Write-Host "  [2/2] Done." -ForegroundColor Yellow
    $zipSize = [math]::Round((Get-Item $zipPath).Length / 1MB, 2)
    return @{ ok = $true; path = $zipPath; sizeMb = $zipSize }
}

$exitCode = 0
$results  = @()

foreach ($key in $Projects) {
    try {
        $results += @{ project = $key; result = Invoke-ProjectBackup -Key $key }
    } catch {
        Write-Host "  FAILED [$key]: $($_.Exception.Message)" -ForegroundColor Red
        $results += @{ project = $key; failed = $_.Exception.Message }
        if ($exitCode -eq 0) { $exitCode = 1 }
    }
}

if ($includeScripts) {
    try {
        $results += @{ project = "scripts"; result = Invoke-ScriptsBackup }
    } catch {
        Write-Host "  FAILED [scripts]: $($_.Exception.Message)" -ForegroundColor Red
        $results += @{ project = "scripts"; failed = $_.Exception.Message }
        if ($exitCode -eq 0) { $exitCode = 1 }
    }
}

Write-Host ""
Write-Host "=== Backup summary ===" -ForegroundColor Cyan
foreach ($r in $results) {
    if ($r.result) {
        Write-Host ('  {0} -> {1} ({2} MB)' -f $r.project, $r.result.path, $r.result.sizeMb) -ForegroundColor Green
    } else {
        Write-Host ('  {0} -> FAILED: {1}' -f $r.project, $r.failed) -ForegroundColor Red
    }
}
Write-Host ""

Stop-ZTracking; exit $exitCode
