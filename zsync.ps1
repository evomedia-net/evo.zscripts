# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.9

# zsync.ps1 — copy new backup files offsite; or build + mirror a vite project's dist.
#
# Usage:
#   zsync                                # new files: backups folder -> paths.oneDriveBackups
#   zsync <viteproject> -Destination 'D:\mirror\dist'
#
# The no-args mode copies only files that don't exist at the destination yet
# (never overwrites, never deletes). The project mode runs npm run build, then
# robocopy /MIR of dist/ to -Destination (or $env:ZSYNC_DEST).
#
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @(),
    [string]$Destination = $env:ZSYNC_DEST
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

$cfg = Get-ZConfig
$BackupsRoot         = Split-Path -Parent $cfg.paths.backupsLocal
$OneDriveBackupsRoot = $cfg.paths.oneDriveBackups

# Copy any file under $SourceRoot that does not yet exist at the matching path under $DestinationRoot.
function Sync-NewFilesTree {
    param(
        [Parameter(Mandatory)] [string]$SourceRoot,
        [Parameter(Mandatory)] [string]$DestinationRoot
    )
    if (-not (Test-Path -LiteralPath $SourceRoot)) {
        Write-Host "  Source not found (skipped): $SourceRoot" -ForegroundColor DarkYellow
        return @{ copied = 0; skipped = 0 }
    }
    if (-not (Test-Path -LiteralPath $DestinationRoot)) {
        New-Item -ItemType Directory -Path $DestinationRoot -Force | Out-Null
    }

    $sourceFull = (Get-Item -LiteralPath $SourceRoot).FullName.TrimEnd('\')
    $files = Get-ChildItem -LiteralPath $SourceRoot -Recurse -File -Force -ErrorAction SilentlyContinue
    $copied = 0
    $skipped = 0

    foreach ($file in $files) {
        $rel = $file.FullName.Substring($sourceFull.Length).TrimStart('\')
        $destFile = Join-Path $DestinationRoot $rel
        $destParent = Split-Path -Parent $destFile
        if ($destParent -and -not (Test-Path -LiteralPath $destParent)) {
            New-Item -ItemType Directory -Path $destParent -Force | Out-Null
        }
        if (Test-Path -LiteralPath $destFile) { $skipped++; continue }
        Copy-Item -LiteralPath $file.FullName -Destination $destFile -Force
        $sizeMb = "{0:N2}" -f ($file.Length / 1MB)
        Write-Host "    Copied: $rel ($sizeMb MB)" -ForegroundColor Green
        $copied++
    }
    return @{ copied = $copied; skipped = $skipped }
}

if ($Projects.Count -eq 0) {
    Write-Host ""
    Write-Host "=== zsync (backups -> offsite) ===" -ForegroundColor Cyan
    Write-Host "  Source:      $BackupsRoot" -ForegroundColor Gray
    Write-Host "  Destination: $OneDriveBackupsRoot" -ForegroundColor Gray
    Write-Host "  Mode:        new files and folders only" -ForegroundColor Gray
    Write-Host ""

    if ([string]::IsNullOrWhiteSpace($OneDriveBackupsRoot)) {
        Write-Host "  paths.oneDriveBackups is not set in zconfig.json - nothing to do." -ForegroundColor Yellow
        Stop-ZTracking; exit 0
    }

    $stats = Sync-NewFilesTree -SourceRoot $BackupsRoot -DestinationRoot $OneDriveBackupsRoot
    Write-Host ""
    Write-Host "  Done: $($stats.copied) copied, $($stats.skipped) already present" -ForegroundColor Cyan
    Write-Host ""
    Stop-ZTracking; exit 0
}

foreach ($key in $Projects) {
    $proj = Get-ZProject -Key $key
    if ($proj.kind -ne "vite") {
        Write-Host ""
        Write-Host "zsync project mode only supports vite kind (builds and mirrors dist/). '$key' is kind '$($proj.kind)'." -ForegroundColor Yellow
        Stop-ZTracking; exit 1
    }
    $root = $proj.localRoot

    if ([string]::IsNullOrWhiteSpace($Destination)) {
        Write-Host ""
        Write-Host "=== zsync ($($proj.label)) ===" -ForegroundColor Cyan
        Write-Host "No destination set." -ForegroundColor Yellow
        Write-Host "Set ZSYNC_DEST or run: zsync $key -Destination 'D:\path\to\folder'" -ForegroundColor DarkGray
        Write-Host "This runs npm run build, then robocopy dist -> destination." -ForegroundColor DarkGray
        Stop-ZTracking; exit 1
    }

    $prevLoc = Get-Location
    try {
        Set-Location -LiteralPath $root

        Write-Host ""
        Write-Host "=== zsync ($($proj.label)) ===" -ForegroundColor Cyan
        Write-Host "Build + mirror dist -> $Destination" -ForegroundColor Cyan
        Write-Host ""

        & npm run build
        if ($LASTEXITCODE -ne 0) { throw "npm run build failed" }

        $dist = Join-Path $root "dist"
        if (-not (Test-Path -LiteralPath $dist)) { throw "dist/ missing after build." }

        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        & robocopy $dist $Destination /MIR /NFL /NDL /NJH /NJS /NP
        $rc = $LASTEXITCODE
        if ($rc -ge 8) { throw "robocopy failed with exit code $rc" }

        Write-Host ""
        Write-Host "Sync complete." -ForegroundColor Green
    }
    finally {
        Set-Location -LiteralPath $prevLoc
    }
}
Stop-ZTracking
