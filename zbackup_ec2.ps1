# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.14

# zbackup_ec2.ps1 — pull backups down from the server: a Postgres dump for projects
# with a "db" config block, plus a zip of server-side data dirs (uploads/archive/dist).
#
# Usage:
#   zbackup_ec2 <project> [<project> ...]
#   zbackup_ec2 all                      # every project with a remote.path
#
# Output:
#   <paths.backupsEc2>\<project>\<timestamp>_<project>_db.sql    (projects with a db block)
#   <paths.backupsEc2>\<project>\<timestamp>_<project>_files.zip

param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @()
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

$cfg           = Get-ZConfig
$PEM_KEY       = $cfg.ec2.pemKey
$SSH_TARGET    = Get-Ec2Target
$RemoteHome    = Get-Ec2Home
$Ec2BackupRoot = $cfg.paths.backupsEc2

if ($Projects.Count -eq 0) {
    Write-Host ""
    Write-Host "Usage: zbackup_ec2 <project> [<project> ...] | all" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $((Get-ZProjectKeys) -join ', ')" -ForegroundColor Gray
    Write-Host "  'all' pulls a server backup of every project with a remote.path." -ForegroundColor Gray
    Stop-ZTracking; exit 1
}
if ($Projects -contains 'all') {
    $Projects = @(Get-ZProjectKeys | Where-Object { $cfg.projects.$_.remote -and $cfg.projects.$_.remote.path })
}

function Get-BackupTimestamp { return Get-Date -Format "yyyyMMdd-HHmmss" }

function Ensure-Ec2BackupDir {
    param([string]$ProjectKey)
    $dir = Join-Path $Ec2BackupRoot $ProjectKey
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    return $dir
}

function Invoke-ScpFromEc2 {
    param([string]$RemotePath, [string]$LocalPath)
    scp -o StrictHostKeyChecking=no -i $PEM_KEY "${SSH_TARGET}:$RemotePath" $LocalPath
    if ($LASTEXITCODE -ne 0) { throw "SCP download failed: $RemotePath -> $LocalPath (exit $LASTEXITCODE)" }
}

function Invoke-ProjectEc2Backup {
    param([string]$Key)
    $proj       = Get-ZProject -Key $Key
    $remotePath = $proj.remote.path
    $composeDir = Get-RemoteComposeDir -Key $Key
    $ts         = Get-BackupTimestamp
    $outDir     = Ensure-Ec2BackupDir -ProjectKey $Key
    $remoteDb   = "$RemoteHome/ec2_${Key}_db_$ts.sql"
    $remoteZip  = "$RemoteHome/ec2_${Key}_files_$ts.zip"
    $localDb    = Join-Path $outDir "${ts}_${Key}_db.sql"
    $localZip   = Join-Path $outDir "${ts}_${Key}_files.zip"
    $hasDb      = ($proj.db -and $proj.db.user -and $proj.db.name)

    Write-Host ""
    Write-Host "=== [$($Key.ToUpper())] Server backup ($($proj.label)) ===" -ForegroundColor Cyan

    if ($hasDb) {
        Write-Host "  [1/4] PostgreSQL dump on the server..." -ForegroundColor Yellow
        $dumpCmd = "cd $composeDir && sudo docker compose exec -T db pg_dump -U $($proj.db.user) -d $($proj.db.name) > $remoteDb"
        Invoke-Ec2Step "pg_dump $($proj.db.name)" $dumpCmd
    } else {
        Write-Host "  [1/4] No db config block - skipping database dump." -ForegroundColor DarkGray
    }

    Write-Host "  [2/4] Zipping server-side data (uploads/archive/dist if present)..." -ForegroundColor Yellow
    $zipCmd = @(
        "sudo apt-get install -y zip >/dev/null 2>&1",
        "FILES=''",
        "test -d $remotePath/uploads && FILES=`"`$FILES $remotePath/uploads`"",
        "test -d $remotePath/archive && FILES=`"`$FILES $remotePath/archive`"",
        "test -d $remotePath/dist && FILES=`"`$FILES $remotePath/dist`"",
        "test -f $remotePath/build-version.json && FILES=`"`$FILES $remotePath/build-version.json`"",
        "if [ -z `"`$FILES`" ]; then echo 'no data dirs found' | sudo zip $remoteZip - >/dev/null; else sudo zip -r $remoteZip `$FILES; fi"
    ) -join '; '
    try {
        Invoke-Ec2Step "zip $Key files" $zipCmd
    } catch {
        Write-Host "    WARNING: files zip failed - continuing: $($_.Exception.Message)" -ForegroundColor DarkYellow
        Invoke-Ec2Step "placeholder zip" "sudo apt-get install -y zip >/dev/null 2>&1; echo 'zip failed' | sudo zip $remoteZip -"
    }

    Write-Host "  [3/4] Downloading to local..." -ForegroundColor Yellow
    if ($hasDb) { Invoke-ScpFromEc2 -RemotePath $remoteDb -LocalPath $localDb }
    Invoke-ScpFromEc2 -RemotePath $remoteZip -LocalPath $localZip

    Write-Host "  [4/4] Cleaning up remote..." -ForegroundColor Yellow
    Invoke-Ec2Step "remove remote temp files" "rm -f $remoteDb $remoteZip"

    $result = @{ ok = $true; zipPath = $localZip }
    $result.zipMb = if (Test-Path $localZip) { [math]::Round((Get-Item $localZip).Length / 1MB, 2) } else { 0 }
    if ($hasDb -and (Test-Path $localDb)) {
        $result.dbPath = $localDb
        $result.dbMb   = [math]::Round((Get-Item $localDb).Length / 1MB, 2)
    }
    return $result
}

$exitCode = 0
$results  = @()

foreach ($key in $Projects) {
    try {
        $results += @{ project = $key; result = Invoke-ProjectEc2Backup -Key $key }
    } catch {
        Write-Host "  FAILED [$key]: $($_.Exception.Message)" -ForegroundColor Red
        $results += @{ project = $key; failed = $_.Exception.Message }
        if ($exitCode -eq 0) { $exitCode = 1 }
    }
}

Write-Host ""
Write-Host "=== Server backup summary ===" -ForegroundColor Cyan
foreach ($r in $results) {
    if ($r.result) {
        $line = "  $($r.project) ->"
        if ($r.result.dbPath)  { $line += " $($r.result.dbPath) ($($r.result.dbMb) MB) |" }
        if ($r.result.zipPath) { $line += " $($r.result.zipPath) ($($r.result.zipMb) MB)" }
        Write-Host $line -ForegroundColor Green
    } else {
        Write-Host ("  {0} -> FAILED: {1}" -f $r.project, $r.failed) -ForegroundColor Red
    }
}
Write-Host ""

Stop-ZTracking; exit $exitCode
