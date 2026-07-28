# Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# zchecksums.ps1 - verify (or regenerate) SHA-256 checksums for the scripts.
#
# Usage:
#   zchecksums              verify every script against CHECKSUMS.txt
#   zchecksums -Update      regenerate CHECKSUMS.txt after changing a script
#   zchecksums -Quiet       verify, print only the summary line
#
# Exit codes: 0 = everything matches, 1 = a mismatch, missing or unlisted file.
#
# WHAT THIS DOES AND DOES NOT PROTECT AGAINST
# -------------------------------------------
# CHECKSUMS.txt lives in the same repo as the scripts, so anyone able to modify
# a script can also modify the manifest. This is an integrity check, not a
# signature. It reliably catches:
#
#   * a truncated or corrupted download / clone
#   * a file edited locally that you forgot about
#   * a script added or removed without going through a commit
#
# It does NOT prove the code came from this project - only a signature (GPG,
# Sigstore) or a hash published somewhere outside this repo can do that. Compare
# against the copy on GitHub if you need that assurance.
#
# Only *.ps1 and *.cmd are covered: they are what you actually execute, and
# .gitattributes pins them to CRLF on every platform, so their hashes are
# identical on Windows, Linux and macOS. Files without that pin would hash
# differently per platform and are deliberately left out.
#
# RUN -Update ON A CLEAN CHECKOUT
# ------------------------------
# Hash whatever is on disk. That is only the same as what a user clones if the
# working copy matches git's normalised form. An editor that writes LF leaves a
# file git still considers unchanged (it normalises to LF in the index either
# way), so the file sits there with LF while every clone gets CRLF - and the
# manifest generated from it fails for everyone else. If in doubt:
#
#   git status --short          # must be clean
#   git rm -r --cached . ; git reset --hard    # or delete the scripts and
#                                              # `git checkout -- .`
#
# then re-run -Update. The surest check is to clone the repo somewhere else and
# run `sha256sum -c CHECKSUMS.txt` there.

[CmdletBinding()]
param(
    [switch]$Update,
    [switch]$Quiet
)

$ErrorActionPreference = "Stop"

$ManifestName = "CHECKSUMS.txt"
$Manifest = Join-Path $PSScriptRoot $ManifestName

# The covered set: executable scripts, top level only. Sorted for a stable file.
function Get-CoveredFiles {
    Get-ChildItem -LiteralPath $PSScriptRoot -File |
        Where-Object { $_.Extension -in @('.ps1', '.cmd') } |
        Sort-Object Name
}

function Get-Sha256([string]$Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# sha256sum-compatible: "<hash>  <name>", LF endings, so `sha256sum -c` works on
# Linux/macOS as well as this script on Windows.
function Write-Manifest($Files) {
    $lines = foreach ($f in $Files) { "{0}  {1}" -f (Get-Sha256 $f.FullName), $f.Name }
    $text = ($lines -join "`n") + "`n"
    [IO.File]::WriteAllText($Manifest, $text, (New-Object Text.UTF8Encoding($false)))
}

function Read-Manifest {
    if (-not (Test-Path -LiteralPath $Manifest)) { return $null }
    $map = [ordered]@{}
    foreach ($line in [IO.File]::ReadAllLines($Manifest)) {
        $t = $line.Trim()
        if (-not $t -or $t.StartsWith('#')) { continue }
        # "<64 hex>  <name>" - two spaces is the sha256sum convention, but accept
        # any run of whitespace so a hand-edited file still parses.
        if ($t -match '^([0-9a-fA-F]{64})\s+(.+)$') {
            $map[$Matches[2].Trim()] = $Matches[1].ToLowerInvariant()
        }
    }
    return $map
}

$files = @(Get-CoveredFiles)

if ($Update) {
    Write-Manifest $files
    Write-Host ""
    Write-Host "=== zchecksums (updated) ===" -ForegroundColor Cyan
    Write-Host ("  Wrote {0} with {1} entries." -f $ManifestName, $files.Count) -ForegroundColor Green
    Write-Host "  Commit it alongside the script change, or verification will fail." -ForegroundColor DarkGray
    Write-Host ""
    exit 0
}

$expected = Read-Manifest
if ($null -eq $expected) {
    Write-Host "ERROR: $ManifestName not found. Run 'zchecksums -Update' to create it." -ForegroundColor Red
    exit 1
}

$ok = 0
$changed = @()
$missing = @()
$unlisted = @()

foreach ($f in $files) {
    if (-not $expected.Contains($f.Name)) { $unlisted += $f.Name; continue }
    if ((Get-Sha256 $f.FullName) -eq $expected[$f.Name]) { $ok++ } else { $changed += $f.Name }
}
foreach ($name in $expected.Keys) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $name))) { $missing += $name }
}

$bad = $changed.Count + $missing.Count + $unlisted.Count

if (-not $Quiet) {
    Write-Host ""
    Write-Host "=== zchecksums ===" -ForegroundColor Cyan
    foreach ($n in $changed)  { Write-Host "  CHANGED  $n" -ForegroundColor Red }
    foreach ($n in $missing)  { Write-Host "  MISSING  $n  (listed but not on disk)" -ForegroundColor Red }
    foreach ($n in $unlisted) { Write-Host "  UNLISTED $n  (on disk but not in $ManifestName)" -ForegroundColor Yellow }
}

if ($bad -eq 0) {
    Write-Host ("  OK - {0} file(s) match {1}." -f $ok, $ManifestName) -ForegroundColor Green
    Write-Host ""
    exit 0
}

Write-Host ("  FAILED - {0} ok, {1} changed, {2} missing, {3} unlisted." -f $ok, $changed.Count, $missing.Count, $unlisted.Count) -ForegroundColor Red
Write-Host "  If you changed a script on purpose, run: zchecksums -Update" -ForegroundColor DarkGray
Write-Host ""
exit 1
