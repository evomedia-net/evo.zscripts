# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# Invoke-Coverage.ps1 — run the Pester suite with code coverage.
#
#   .\tests\Invoke-Coverage.ps1            run everything, print the summary
#   .\tests\Invoke-Coverage.ps1 -Quiet     just the numbers (for tooling)
#
# Writes coverage/ :
#   pester-coverage.xml     JaCoCo, for anything that reads a standard format
#   coverage-summary.json   the same shape vitest/jest emit, so the fleet
#                           coverage collector reads all three identically
#
# WHY EVERY SCRIPT IS MEASURED, NOT JUST THE TESTED ONES
# ------------------------------------------------------
# CodeCoverage.Path covers every top-level *.ps1, including the ones no test
# touches. They report 0% and drag the total down, which is correct: the
# alternative measures only the files that already have tests and answers "how
# well covered is the covered code" - a question nobody is asking. The same
# mistake in vitest form made www look 91% covered when it was 17%.
#
# Pester counts *commands*, not statements. The collector labels it accordingly;
# the two are not interchangeable and averaging them would be nonsense.

[CmdletBinding(PositionalBinding = $false)]
param([switch]$Quiet)

$ErrorActionPreference = "Stop"

$RepoRoot = Split-Path -Parent $PSScriptRoot
$OutDir   = Join-Path $RepoRoot "coverage"
$Jacoco   = Join-Path $OutDir "pester-coverage.xml"
$Summary  = Join-Path $OutDir "coverage-summary.json"

Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop

# Every script in the repo root. ZKiller/ZKillOnly and friends are included
# deliberately - see the header.
$targets = @(Get-ChildItem -Path $RepoRoot -Filter "*.ps1" -File | Select-Object -ExpandProperty FullName)
if (-not $targets) { Write-Error "No *.ps1 found in $RepoRoot"; exit 1 }

if (Test-Path $OutDir) { Remove-Item $OutDir -Recurse -Force }
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$cfg = New-PesterConfiguration
$cfg.Run.Path                     = Join-Path $RepoRoot "tests"
$cfg.Run.PassThru                 = $true
$cfg.Output.Verbosity             = if ($Quiet) { "None" } else { "Normal" }
$cfg.CodeCoverage.Enabled         = $true
$cfg.CodeCoverage.Path            = $targets
$cfg.CodeCoverage.OutputFormat    = "JaCoCo"
$cfg.CodeCoverage.OutputPath      = $Jacoco
$cfg.CodeCoverage.UseBreakpoints  = $false   # the profiler-based collector; far faster
$cfg.Should.ErrorAction           = "Continue"

$r = Invoke-Pester -Configuration $cfg

$analyzed = [int]$r.CodeCoverage.CommandsAnalyzedCount
$executed = [int]$r.CodeCoverage.CommandsExecutedCount
$pct      = if ($analyzed -gt 0) { [math]::Round(($executed / $analyzed) * 100, 2) } else { 0 }

# Same shape as vitest/jest json-summary. "statements" is Pester's command
# count; the key is reused so one reader handles every tool, and the unit is
# named in the collector rather than pretended away here.
$json = [ordered]@{
    total = [ordered]@{
        statements = [ordered]@{ pct = $pct; covered = $executed; total = $analyzed }
    }
    tests = [ordered]@{
        passed  = [int]$r.PassedCount
        failed  = [int]$r.FailedCount
        skipped = [int]$r.SkippedCount
        total   = [int]$r.TotalCount
    }
    unit  = "commands"
} | ConvertTo-Json -Depth 6

# WriteAllText, not Set-Content: Set-Content -Encoding utf8 on 5.1 writes a BOM,
# and a BOM makes python's json.load throw on the first character.
[IO.File]::WriteAllText($Summary, $json, (New-Object Text.UTF8Encoding $false))

if (-not $Quiet) {
    Write-Host ""
    Write-Host "Coverage: $pct%  ($executed/$analyzed commands across $($targets.Count) scripts)" -ForegroundColor Cyan
    Write-Host "  $Jacoco"
    Write-Host "  $Summary"
    Write-Host ""
}

exit $(if ($r.FailedCount -gt 0) { 1 } else { 0 })
