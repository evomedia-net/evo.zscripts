# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.14

# token-count.ps1 — measure script output volume to estimate AI agent token costs.
#
# Runs each z-script and captures lines + characters of output. Use the results
# to validate or update the figures in TOKEN_SAVINGS.md.
#
# Usage:
#   .\token-count.ps1 <project>              # run all scripts against a project key
#   .\token-count.ps1 <project> -Skip zbackup_ec2,zrepair   # skip slow/destructive ones
#   .\token-count.ps1 <project> -Only zdeploy,zec2          # run specific scripts only
#
# Output: a summary table with lines, chars, and estimated tokens per script.
# Estimated tokens = chars / 3.5 (Claude's approximate tokenization rate).

param(
    [Parameter(Position = 0, Mandatory = $true)]
    [string]$Project,
    [string[]]$Skip = @(),
    [string[]]$Only = @()
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")

$CHARS_PER_TOKEN = 3.5

$results = [System.Collections.Generic.List[hashtable]]::new()

function Invoke-Measured {
    param(
        [string]$Label,
        [string]$ScriptName,
        [scriptblock]$Block,
        [string]$Note = ""
    )

    if ($Only.Count -gt 0 -and $Only -notcontains $ScriptName) { return }
    if ($Skip -contains $ScriptName) {
        $results.Add(@{ label = $Label; skipped = $true; note = "skipped" })
        return
    }

    Write-Host "Running $Label..." -ForegroundColor DarkGray -NoNewline
    $tp = Join-Path ([System.IO.Path]::GetTempPath()) ("_zm_" + [System.Guid]::NewGuid().ToString("N") + ".txt")
    $global:_ZMeasuring = $true
    try {
        # Use Start-Transcript so Write-Host (stream 6) is captured.
        # _ZMeasuring tells Start-ZTracking in all called scripts to no-op,
        # so no inner script can replace or stop our transcript.
        Start-Transcript -Path $tp -NoClobber | Out-Null
        try { & $Block } catch {}
        try { Stop-Transcript | Out-Null } catch {}

        $raw = Get-Content -LiteralPath $tp -Raw -Encoding UTF8 -ErrorAction SilentlyContinue
        if (-not $raw) { $raw = "" }
        $allLines = @($raw -split "`n")
        $si = 0
        for ($i = 0; $i -lt $allLines.Count; $i++) {
            if ($allLines[$i] -match '^Transcript started') { $si = $i + 1; break }
        }
        $ei = $allLines.Count
        for ($i = $allLines.Count - 1; $i -ge 0; $i--) {
            if ($allLines[$i] -match '^\*{4}') { $ei = $i; break }
        }
        $body = if ($ei -gt $si) { @($allLines[$si..($ei - 1)]) } else { @() }
        $text = $body -join "`n"
        $lc   = ($body | Where-Object { $_.Trim() -ne "" }).Count
        $cc   = $text.Length
        $tokens = [math]::Round($cc / $CHARS_PER_TOKEN)
        $results.Add(@{
            label  = $Label
            script = $ScriptName
            lines  = $lc
            chars  = $cc
            tokens = $tokens
            note   = $Note
        })
        Write-Host " $lc lines / $cc chars / ~$tokens tokens" -ForegroundColor Green
    } catch {
        $results.Add(@{ label = $Label; script = $ScriptName; error = $_.Exception.Message })
        Write-Host " ERROR: $($_.Exception.Message)" -ForegroundColor Red
    } finally {
        $global:_ZMeasuring = $false
        try { Stop-Transcript | Out-Null } catch {}
        Remove-Item -LiteralPath $tp -Force -ErrorAction SilentlyContinue
    }
}

Write-Host ""
Write-Host "=== Token Count - project: $Project ===" -ForegroundColor Cyan
Write-Host "Chars per token: $CHARS_PER_TOKEN (Claude approximate)" -ForegroundColor DarkGray
Write-Host ""

# ── Local dev ──────────────────────────────────────────────────────────────────
Invoke-Measured "zstart    " "zstart"    { & (Join-Path $PSScriptRoot "zstart.ps1") $Project -Detached } `
    -Note "detached - output may be minimal"

Invoke-Measured "zkill     " "zkill"     { & (Join-Path $PSScriptRoot "ZKillOnly.ps1") $Project }

Invoke-Measured "zrestart  " "zrestart"  { & (Join-Path $PSScriptRoot "ZKiller.ps1") $Project -Detached } `
    -Note "detached"

# Takes no project key; brings up zscripts\docker\docker-compose.yml. Needs Docker
# Desktop running AND that compose file present, or it only emits an error.
Invoke-Measured "zstart_docker" "zstart_docker" { & (Join-Path $PSScriptRoot "zstart_docker.ps1") } `
    -Note "detached docker stack - needs Docker Desktop + docker/docker-compose.yml"

# ── Deploy ─────────────────────────────────────────────────────────────────────
Invoke-Measured "zdeploy   " "zdeploy"   { & (Join-Path $PSScriptRoot "zdeploy.ps1") $Project } `
    -Note "includes docker build - run twice; first may be inflated by package installs"

# ── Diagnostics ────────────────────────────────────────────────────────────────
Invoke-Measured "zec2      " "zec2"      { & (Join-Path $PSScriptRoot "zec2.ps1") $Project }

Invoke-Measured "zec2online" "zec2online" { & (Join-Path $PSScriptRoot "zec2online.ps1") $Project }

Invoke-Measured "zrepair   " "zrepair"   { & (Join-Path $PSScriptRoot "zrepair.ps1") $Project } `
    -Note "may restart containers on EC2"

# ── Backups ────────────────────────────────────────────────────────────────────
Invoke-Measured "zbackup   " "zbackup"   { & (Join-Path $PSScriptRoot "zbackup.ps1") $Project }

Invoke-Measured "zbackup_ec2" "zbackup_ec2" { & (Join-Path $PSScriptRoot "zbackup_ec2.ps1") $Project } `
    -Note "pulls from EC2 - skippable if slow"

Invoke-Measured "zsync     " "zsync"     { & (Join-Path $PSScriptRoot "zsync.ps1") }

# ── Summary table ──────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "=== Summary ===" -ForegroundColor Cyan
Write-Host ("{0,-14} {1,8} {2,10} {3,10}  {4}" -f "Script", "Lines", "Chars", "~Tokens", "Notes") -ForegroundColor Yellow
Write-Host ("-" * 70) -ForegroundColor DarkGray

$totalTokens = 0
foreach ($r in $results) {
    if ($r.skipped) {
        Write-Host ("{0,-14} {1,8}" -f $r.label, "(skipped)") -ForegroundColor DarkGray
    } elseif ($r.error) {
        Write-Host ("{0,-14} {1}" -f $r.label, "ERROR: $($r.error)") -ForegroundColor Red
    } else {
        Write-Host ("{0,-14} {1,8} {2,10} {3,10}  {4}" -f `
            $r.label, $r.lines, $r.chars, $r.tokens, $r.note) -ForegroundColor White
        $totalTokens += $r.tokens
    }
}

Write-Host ("-" * 70) -ForegroundColor DarkGray
Write-Host ("{0,-14} {1,8} {2,10} {3,10}" -f "TOTAL", "", "", $totalTokens) -ForegroundColor Cyan

# ── Dollar cost at current pricing ─────────────────────────────────────────────
Write-Host ""
Write-Host "=== Estimated cost if Claude orchestrated all of the above ===" -ForegroundColor Cyan
$models = @(
    @{ name = "Haiku 4.5"; blended = 2.25 },
    @{ name = "Sonnet 5 "; blended = 9.00 },
    @{ name = "Opus 4.8 "; blended = 15.00 },
    @{ name = "Fable 5  "; blended = 30.00 }
)
foreach ($m in $models) {
    $cost = [math]::Round($totalTokens / 1000000 * $m.blended, 6)
    Write-Host ("  {0}  ~{1,8} tokens  x  `${2}/1M blended  =  `${3}" -f `
        $m.name, $totalTokens, $m.blended, $cost) -ForegroundColor White
}

Write-Host ""
Write-Host "Note: zdeploy output varies significantly between runs." -ForegroundColor DarkGray
Write-Host "      First run after package updates can be 2-3x larger than a cached run." -ForegroundColor DarkGray
Write-Host "      Run zdeploy twice and use the second (cached) figure for TOKEN_SAVINGS.md." -ForegroundColor DarkGray
Write-Host ""
