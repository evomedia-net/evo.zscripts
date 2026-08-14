# Evomedia.net — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.11

# zversion.ps1 - manage the toolkit version.
#
# Usage:
#   zversion                     print the current version
#   zversion bump                build + 1        (one bump per PR / per defect fix)
#   zversion bump-stage alpha    alpha + 1, build -> 0
#   zversion bump-stage beta     beta  + 1, alpha/build -> 0
#   zversion bump-stage rc       rc    + 1, beta/alpha/build -> 0
#   zversion bump-stage release  major + 1, everything below -> 0
#   zversion set v1.2.0.0.5      set an exact version
#
# THE SCHEME
# ----------
#   v{major}.{rc}.{beta}.{alpha}.{build}
#
# Priority runs left to right, and bumping any stage zeroes every lower segment
# including build. One version for the whole toolkit, not per script.
#
# WHAT A BUMP TOUCHES
# -------------------
# Anything other than a plain read rewrites three things together, because they
# are only useful if they agree:
#   1. build-version.json  - the source of truth
#   2. the "# Version:" line in every .ps1 / .cmd header, so a script that has
#      been copied out of the repo still says which release it came from
#   3. CHECKSUMS.txt       - stamping changes every file, so the manifest must
#                            be regenerated or verification fails immediately
#
# Run this on a clean checkout: it hashes files as they sit on disk, and an
# editor that writes LF leaves a file git still considers unchanged. See the
# note in zchecksums.ps1.

[CmdletBinding()]
param(
    [Parameter(Position = 0)][string]$Command = "get",
    [Parameter(Position = 1)][string]$Value
)

$ErrorActionPreference = "Stop"

$VersionFile = Join-Path $PSScriptRoot "build-version.json"
$VersionRe = '^v(\d+)\.(\d+)\.(\d+)\.(\d+)\.(\d+)$'
$DefaultVersion = "v1.0.0.0.0"

function Read-Version {
    if (-not (Test-Path -LiteralPath $VersionFile)) { return $DefaultVersion }
    try {
        $v = (Get-Content -LiteralPath $VersionFile -Raw -Encoding UTF8 | ConvertFrom-Json).version
        if ($v -match $VersionRe) { return $v }
    } catch { }
    return $DefaultVersion
}

function Write-Version([string]$Version) {
    $json = [ordered]@{ version = $Version } | ConvertTo-Json
    [IO.File]::WriteAllText($VersionFile, $json + "`n", (New-Object Text.UTF8Encoding($false)))
}

function Split-Version([string]$Version) {
    if ($Version -notmatch $VersionRe) {
        throw "Invalid version '$Version'. Expected v{major}.{rc}.{beta}.{alpha}.{build}, e.g. v1.0.0.0.3."
    }
    return [int[]]@($Matches[1], $Matches[2], $Matches[3], $Matches[4], $Matches[5])
}

# Rewrite (or insert) the "# Version:" header line in every covered script.
function Set-ScriptVersionHeaders([string]$Version) {
    $stamped = 0
    foreach ($f in Get-ChildItem -LiteralPath $PSScriptRoot -File | Where-Object { $_.Extension -in @('.ps1', '.cmd') }) {
        $text = [IO.File]::ReadAllText($f.FullName)
        # Keep each file's own comment marker: # for PowerShell, REM for cmd.
        $marker = if ($f.Extension -eq '.cmd') { 'REM' } else { '#' }
        $line = "$marker Version: $Version"
        if ($text -match "(?m)^(#|REM) Version: v[\d\.]+\r?$") {
            $new = [regex]::Replace($text, "(?m)^(#|REM) Version: v[\d\.]+\r?$", [System.Text.RegularExpressions.MatchEvaluator] { param($m) $line })
        } else {
            # Insert directly after the licence line, which every header carries.
            $pattern = "(?m)^((#|REM) Licensed under the MIT License\. See LICENSE\.)\r?$"
            if ($text -notmatch $pattern) { continue }
            $new = [regex]::Replace($text, $pattern, [System.Text.RegularExpressions.MatchEvaluator] { param($m) $m.Groups[1].Value + "`r`n" + $line }, 1)
        }
        if ($new -ne $text) {
            # .ps1/.cmd are pinned to CRLF by .gitattributes - write them that
            # way or every stamped file shows up as changed on the next clone.
            $new = ($new -replace "`r`n", "`n") -replace "`n", "`r`n"
            [IO.File]::WriteAllText($f.FullName, $new, (New-Object Text.UTF8Encoding($false)))
            $stamped++
        }
    }
    return $stamped
}

function Update-Everything([string]$Version) {
    Write-Version $Version
    $n = Set-ScriptVersionHeaders $Version
    & (Join-Path $PSScriptRoot "zchecksums.ps1") -Update | Out-Null
    Write-Host ""
    Write-Host "=== zversion ===" -ForegroundColor Cyan
    Write-Host "  Version:   $Version" -ForegroundColor Green
    Write-Host "  Stamped:   $n script header(s)" -ForegroundColor Gray
    Write-Host "  Refreshed: CHECKSUMS.txt" -ForegroundColor Gray
    Write-Host "  Commit build-version.json, the stamped scripts and CHECKSUMS.txt together." -ForegroundColor DarkGray
    Write-Host ""
}

$current = Read-Version

switch ($Command.ToLowerInvariant().TrimStart('-')) {
    "get" {
        Write-Host $current
        exit 0
    }
    "bump" {
        $p = Split-Version $current
        Update-Everything ("v{0}.{1}.{2}.{3}.{4}" -f $p[0], $p[1], $p[2], $p[3], ($p[4] + 1))
        exit 0
    }
    "bump-stage" {
        $p = Split-Version $current
        $major, $rc, $beta, $alpha = $p[0], $p[1], $p[2], $p[3]
        switch (("$Value").ToLowerInvariant()) {
            "release" { $major++; $rc = 0; $beta = 0; $alpha = 0 }
            "rc"      { $rc++; $beta = 0; $alpha = 0 }
            "beta"    { $beta++; $alpha = 0 }
            "alpha"   { $alpha++ }
            default {
                Write-Host "ERROR: stage must be one of: release, rc, beta, alpha" -ForegroundColor Red
                exit 1
            }
        }
        # Bumping a stage zeroes every lower segment, build included.
        Update-Everything ("v{0}.{1}.{2}.{3}.0" -f $major, $rc, $beta, $alpha)
        exit 0
    }
    "set" {
        [void](Split-Version $Value)
        Update-Everything $Value
        exit 0
    }
    default {
        Write-Host ""
        Write-Host "Usage: zversion [get | bump | bump-stage <release|rc|beta|alpha> | set <version>]" -ForegroundColor Yellow
        Write-Host "  Scheme: v{major}.{rc}.{beta}.{alpha}.{build}  (current: $current)" -ForegroundColor Gray
        Write-Host "  bump        build + 1 - one per PR, one per defect fix" -ForegroundColor Gray
        Write-Host "  bump-stage  raise a stage; every lower segment resets to 0" -ForegroundColor Gray
        Write-Host ""
        exit 1
    }
}
