# Evomedia.net — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.10

# zrelease.ps1 - package the current version as a downloadable zip.
#
# Usage:
#   zrelease            build releases/zscripts-<version>.zip
#   zrelease -Force     overwrite an existing zip for this version
#   zrelease -Verify    re-check the zip already on disk for this version
#
# For people who want the toolkit without cloning: one zip, one hash to check.
#
# WHAT GOES IN
# ------------
#   every *.ps1 / *.cmd      the commands themselves
#   CHECKSUMS.txt            per-file manifest, so the contents can be
#                            re-verified after unzipping
#   zconfig.example.json     you need it to configure anything
#   README.md, CHANGELOG.md, LICENSE, TOKEN_SAVINGS.md
#   build-version.json       which release this is
#
# Left out: tests/ (a user does not need the suite to run the commands) and
# releases/ (never package the packages).
#
# WHAT COMES OUT
#   releases/zscripts-v1.0.0.0.1.zip
#   releases/zscripts-v1.0.0.0.1.zip.sha256   <- sha256sum format, one line
#
# Two layers on purpose: the .sha256 verifies you downloaded the zip intact,
# and CHECKSUMS.txt inside verifies the individual scripts after extraction.
# Both are integrity checks, not signatures - see the note in zchecksums.ps1.

[CmdletBinding()]
param(
    [switch]$Force,
    [switch]$Verify
)

$ErrorActionPreference = "Stop"

$ReleasesDir = Join-Path $PSScriptRoot "releases"
$VersionFile = Join-Path $PSScriptRoot "build-version.json"

if (-not (Test-Path -LiteralPath $VersionFile)) {
    Write-Host "ERROR: build-version.json not found. Run 'zversion set v1.0.0.0.0' first." -ForegroundColor Red
    exit 1
}
$version = (Get-Content -LiteralPath $VersionFile -Raw -Encoding UTF8 | ConvertFrom-Json).version
if ($version -notmatch '^v\d+\.\d+\.\d+\.\d+\.\d+$') {
    Write-Host "ERROR: build-version.json holds an invalid version '$version'." -ForegroundColor Red
    exit 1
}

$zipName = "zscripts-$version.zip"
$zipPath = Join-Path $ReleasesDir $zipName
$shaPath = "$zipPath.sha256"

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# ---- verify mode -------------------------------------------------------------
if ($Verify) {
    if (-not (Test-Path -LiteralPath $zipPath)) {
        Write-Host "ERROR: $zipName not found in releases/." -ForegroundColor Red
        exit 1
    }
    if (-not (Test-Path -LiteralPath $shaPath)) {
        Write-Host "ERROR: $zipName.sha256 not found." -ForegroundColor Red
        exit 1
    }
    $expected = ((Get-Content -LiteralPath $shaPath -Raw) -split '\s+')[0].ToLowerInvariant()
    $actual = Get-Sha256 $zipPath
    Write-Host ""
    Write-Host "=== zrelease (verify) ===" -ForegroundColor Cyan
    if ($actual -eq $expected) {
        Write-Host "  OK - $zipName matches its .sha256." -ForegroundColor Green
        Write-Host ""
        exit 0
    }
    Write-Host "  FAILED - $zipName does not match its .sha256." -ForegroundColor Red
    Write-Host ""
    exit 1
}

# ---- build mode --------------------------------------------------------------
if ((Test-Path -LiteralPath $zipPath) -and -not $Force) {
    Write-Host ""
    Write-Host "ERROR: releases/$zipName already exists." -ForegroundColor Red
    Write-Host "  A released version is immutable - bump instead: zversion bump" -ForegroundColor DarkGray
    Write-Host "  (or pass -Force if you are rebuilding one that was never published)" -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

# Refuse to package scripts that disagree with the manifest.
& (Join-Path $PSScriptRoot "zchecksums.ps1") -Quiet | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "ERROR: checksum verification failed - refusing to package." -ForegroundColor Red
    Write-Host "  Run 'zchecksums' to see what differs, then 'zversion bump' to restamp." -ForegroundColor DarkGray
    Write-Host ""
    exit 1
}

New-Item -ItemType Directory -Force -Path $ReleasesDir | Out-Null

$staging = Join-Path ([IO.Path]::GetTempPath()) ("zrel-" + [guid]::NewGuid().ToString("N"))
New-Item -ItemType Directory -Path $staging -Force | Out-Null
try {
    $scripts = @(Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in @('.ps1', '.cmd') })
    foreach ($f in $scripts) { Copy-Item -LiteralPath $f.FullName -Destination $staging }

    $extras = @('CHECKSUMS.txt', 'zconfig.example.json', 'README.md', 'CHANGELOG.md', 'LICENSE', 'TOKEN_SAVINGS.md', 'build-version.json')
    $included = @()
    foreach ($name in $extras) {
        $p = Join-Path $PSScriptRoot $name
        if (Test-Path -LiteralPath $p) { Copy-Item -LiteralPath $p -Destination $staging; $included += $name }
    }

    if (Test-Path -LiteralPath $zipPath) { Remove-Item -LiteralPath $zipPath -Force }
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
    [IO.Compression.ZipFile]::CreateFromDirectory($staging, $zipPath, [IO.Compression.CompressionLevel]::Optimal, $false)
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force -ErrorAction SilentlyContinue
}

$hash = Get-Sha256 $zipPath
# sha256sum format, LF ending, so `sha256sum -c` works on Linux/macOS.
[IO.File]::WriteAllText($shaPath, "$hash  $zipName`n", (New-Object Text.UTF8Encoding($false)))

$sizeKb = [math]::Round((Get-Item -LiteralPath $zipPath).Length / 1KB, 1)

Write-Host ""
Write-Host "=== zrelease ===" -ForegroundColor Cyan
Write-Host "  Version: $version" -ForegroundColor Green
Write-Host "  Zip:     releases/$zipName  ($sizeKb KB, $($scripts.Count) scripts + $($included.Count) support file(s))" -ForegroundColor Gray
Write-Host "  SHA-256: $hash" -ForegroundColor Gray
Write-Host "  Digest:  releases/$zipName.sha256" -ForegroundColor Gray
Write-Host ""
Write-Host "  Commit both files - a release lives in the repo under releases/." -ForegroundColor DarkGray
Write-Host ""
exit 0
