# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.25

# zmerge.ps1 - merge the fleet's ready pull requests in one pass.
#
# Usage:
#   zmerge                        dry run: list every open PR and its verdict
#   zmerge -Execute               merge everything that is genuinely ready
#   zmerge -e                     the same; -e is an alias, as -s is for -Scan
#   zmerge -Exclude 431           skip PRs by number (repeatable)
#   zmerge -Repo <name>           limit to one repo
#   zmerge -Only 68,67            merge just these
#   zmerge -Execute -Yes          skip the confirmation prompt
#
# WHY THIS EXISTS
# ---------------
# Eleven ready PRs across three repos is eleven trips through the GitHub UI, and
# the failure mode is not the clicking - it is that `gh pr create` and the merge
# button will both happily accept a PR that cannot actually merge. Mergeability
# is computed asynchronously, so a PR reports UNKNOWN for a few seconds after any
# push and CONFLICTING only later. Merging by hand, the tenth PR is the one that
# gets rubber-stamped.
#
# So this refuses to merge anything it has not just re-checked, and it re-checks
# after every merge, because merging one PR can conflict another in the same
# repo.
#
# WHAT IT WILL NOT DO
# -------------------
#   * merge a PR that is not MERGEABLE/CLEAN at the moment it is reached
#   * merge a draft, or one with a failing required check
#   * bump versions - each repo stamps differently (zbump for zscripts,
#     bump_build_version.mjs for www), and a wrong stamp is worse than none.
#     The follow-up commands are printed instead.
#   * deploy anything. Deploys are run by hand, deliberately.
#
# ON UNKNOWN
# ----------
# GitHub returns mergeable=UNKNOWN while it computes, which is indistinguishable
# from trouble if you only look once. Each PR is polled up to $PollTries times
# before being treated as not ready, so a slow answer does not read as a failure
# and a real CONFLICTING never reads as "probably fine".

param(
    [Alias('e')][switch]$Execute,
    [switch]$Yes,
    [int[]]$Exclude = @(),
    [int[]]$Only = @(),
    [string]$Repo,
    [int]$PollTries = 6,
    [int]$PollDelaySeconds = 4
)

$ErrorActionPreference = "Stop"

# Two blank lines at the end of a run, matching every other z-script, so output
# is separated from the next prompt. Local copy rather than ZHelpers: this
# script does not dot-source it.
function Write-ZTrailer { Write-Host ""; Write-Host "" }

# Every repository in the org, asked of GitHub rather than remembered here.
#
# Local to this script for the same reason Write-ZTrailer is: zmerge needs gh
# and nothing else, and dot-sourcing 1,200 lines of deploy helpers for one
# function would trade that away.
#
# THROWS rather than returning an empty list when gh fails. A merge tool that
# quietly scans nothing prints exactly the same reassuring line as one that
# scanned everything and found nothing, and those two must never be
# confusable - which is precisely how the list this replaced hid its own rot.
function Get-FleetRepos {
    param([Parameter(Mandatory)][string]$Org)
    $raw = & gh repo list $Org --limit 200 --json name,isArchived 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "gh repo list $Org failed ($LASTEXITCODE): $($raw -join ' ')"
    }
    try { $all = $raw | ConvertFrom-Json } catch {
        throw "gh repo list $Org did not return JSON: $($raw -join ' ')"
    }
    if (-not $all) { throw "gh repo list $Org returned no repositories" }
    $names = @($all | Where-Object { -not $_.isArchived } |
        ForEach-Object { $_.name } | Sort-Object)
    if ($names.Count -eq 0) { throw "every repository in $Org is archived?" }
    return $names
}



$ORG = "evomedia-net"
# Discovered, never listed. The list this replaced had fallen fourteen
# repositories behind: a scan covered sixteen of thirty and said "Nothing open
# to merge" while a ready PR sat in one of the fourteen it could not see.
$REPOS = Get-FleetRepos -Org $ORG

# How each repo advances its build stamp after a merge. Printed as follow-up,
# never run: see the header.
$BUMP = @{
    "evo.zscripts" = "zbump"
    "evo.www"      = "node scripts/bump_build_version.mjs bump   (on main, then push)"
}

function Invoke-Gh {
    param([string[]]$GhArgs, [switch]$AllowFail)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $out = & gh @GhArgs 2>&1 | ForEach-Object { "$_" }
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $prev }
    if ($code -ne 0 -and -not $AllowFail) {
        throw "gh $($GhArgs -join ' ') failed ($code): $($out -join "`n")"
    }
    return [pscustomobject]@{ Output = ($out -join "`n"); Code = $code }
}

function Get-OpenPrs {
    param([string]$RepoName)
    $r = Invoke-Gh @("pr", "list", "-R", "$ORG/$RepoName", "--state", "open",
        "--limit", "100", "--json", "number,title,isDraft,headRefName") -AllowFail
    if ($r.Code -ne 0 -or -not $r.Output) { return @() }
    return @($r.Output | ConvertFrom-Json)
}

# Re-checked immediately before every merge, and again after each one, because
# merging into the default branch can conflict a sibling PR in the same repo.
function Get-Readiness {
    param([string]$RepoName, [int]$Number)
    for ($i = 1; $i -le $PollTries; $i++) {
        $r = Invoke-Gh @("pr", "view", "$Number", "-R", "$ORG/$RepoName",
            "--json", "mergeable,mergeStateStatus,state,isDraft") -AllowFail
        if ($r.Code -ne 0) { return [pscustomobject]@{ Ready = $false; Why = "cannot read PR" } }
        $j = $r.Output | ConvertFrom-Json
        if ($j.state -ne "OPEN")  { return [pscustomobject]@{ Ready = $false; Why = "state is $($j.state)" } }
        if ($j.isDraft)           { return [pscustomobject]@{ Ready = $false; Why = "draft" } }
        if ($j.mergeable -eq "MERGEABLE" -and $j.mergeStateStatus -eq "CLEAN") {
            return [pscustomobject]@{ Ready = $true; Why = "MERGEABLE/CLEAN" }
        }
        if ($j.mergeable -eq "CONFLICTING") {
            return [pscustomobject]@{ Ready = $false; Why = "CONFLICTING - rebase it" }
        }
        # UNKNOWN, or a non-CLEAN state such as BLOCKED/BEHIND: give GitHub a
        # moment, since it computes mergeability asynchronously.
        if ($j.mergeable -ne "UNKNOWN" -and $j.mergeStateStatus -ne "UNKNOWN") {
            return [pscustomobject]@{ Ready = $false; Why = "$($j.mergeable)/$($j.mergeStateStatus)" }
        }
        Start-Sleep -Seconds $PollDelaySeconds
    }
    return [pscustomobject]@{ Ready = $false; Why = "still UNKNOWN after $PollTries tries" }
}

$targets = if ($Repo) { @($Repo) } else { $REPOS }

Write-Host ""
Write-Host "Scanning $($targets.Count) repo(s) for open pull requests..." -ForegroundColor Cyan

$queue = @()
foreach ($r in $targets) {
    foreach ($pr in (Get-OpenPrs -RepoName $r)) {
        if ($Exclude -contains $pr.number) { continue }
        if ($Only.Count -gt 0 -and $Only -notcontains $pr.number) { continue }
        $queue += [pscustomobject]@{ Repo = $r; Number = $pr.number; Title = $pr.title; Draft = $pr.isDraft }
    }
}

if ($queue.Count -eq 0) { Write-Host "Nothing open to merge." -ForegroundColor Yellow; Write-ZTrailer; exit 0 }

Write-Host ""
foreach ($p in $queue) {
    $v = Get-Readiness -RepoName $p.Repo -Number $p.Number
    $p | Add-Member -NotePropertyName Ready -NotePropertyValue $v.Ready -Force
    $p | Add-Member -NotePropertyName Why   -NotePropertyValue $v.Why   -Force
    $mark = if ($v.Ready) { "OK  " } else { "SKIP" }
    $col  = if ($v.Ready) { "Green" } else { "Yellow" }
    Write-Host ("  {0} {1,-14} #{2,-4} {3}" -f $mark, $p.Repo, $p.Number, $p.Title) -ForegroundColor $col
    if (-not $v.Ready) { Write-Host ("       -> {0}" -f $v.Why) -ForegroundColor DarkYellow }
}

$ready = @($queue | Where-Object { $_.Ready })
Write-Host ""
Write-Host "$($ready.Count) of $($queue.Count) ready to merge." -ForegroundColor Cyan

if (-not $Execute) {
    Write-Host ""
    Write-Host "Dry run. Re-run with -Execute (or -e) to merge." -ForegroundColor Yellow
    Write-ZTrailer
    exit 0
}
if ($ready.Count -eq 0) { Write-ZTrailer; exit 1 }

if (-not $Yes) {
    Write-Host ""
    $answer = Read-Host "Squash-merge these $($ready.Count) PRs and delete their branches? (y/N)"
    if ($answer -notmatch '^(y|yes)$') { Write-Host "Aborted." -ForegroundColor Yellow; Write-ZTrailer; exit 1 }
}

$merged = @(); $failed = @()
foreach ($p in $ready) {
    # Re-check: an earlier merge in this same repo may have conflicted this one.
    $v = Get-Readiness -RepoName $p.Repo -Number $p.Number
    if (-not $v.Ready) {
        Write-Host ("  SKIP {0} #{1} - {2}" -f $p.Repo, $p.Number, $v.Why) -ForegroundColor Yellow
        $failed += [pscustomobject]@{ Repo = $p.Repo; Number = $p.Number; Why = $v.Why }
        continue
    }
    $r = Invoke-Gh @("pr", "merge", "$($p.Number)", "-R", "$ORG/$($p.Repo)",
        "--squash", "--delete-branch") -AllowFail
    if ($r.Code -eq 0) {
        Write-Host ("  MERGED {0} #{1}" -f $p.Repo, $p.Number) -ForegroundColor Green
        $merged += $p
    } else {
        Write-Host ("  FAILED {0} #{1}" -f $p.Repo, $p.Number) -ForegroundColor Red
        Write-Host ("         {0}" -f $r.Output) -ForegroundColor DarkRed
        $failed += [pscustomobject]@{ Repo = $p.Repo; Number = $p.Number; Why = $r.Output }
    }
}

Write-Host ""
Write-Host "merged $($merged.Count), failed/skipped $($failed.Count)" -ForegroundColor Cyan

# Verify rather than trust the exit codes - a merge can report success and leave
# the PR in an unexpected state.
if ($merged.Count -gt 0) {
    Write-Host ""
    Write-Host "Verifying:" -ForegroundColor Cyan
    foreach ($p in $merged) {
        $r = Invoke-Gh @("pr", "view", "$($p.Number)", "-R", "$ORG/$($p.Repo)",
            "--json", "state,mergedAt") -AllowFail
        $j = if ($r.Code -eq 0) { $r.Output | ConvertFrom-Json } else { $null }
        $state = if ($j) { $j.state } else { "unreadable" }
        $col = if ($state -eq "MERGED") { "Green" } else { "Red" }
        Write-Host ("  {0,-14} #{1,-4} {2}" -f $p.Repo, $p.Number, $state) -ForegroundColor $col
    }

    # Follow-up, printed not run: ONE build bump per release - not one per
    # merged PR - on the default branch, and then a deploy. Both deliberately
    # by hand. This used to print one bump per PR, which is how a single
    # release came to be stamped as two builds.
    Write-Host ""
    Write-Host "Follow-up (not run):" -ForegroundColor Cyan
    foreach ($grp in ($merged | Group-Object Repo)) {
        $how = if ($BUMP.ContainsKey($grp.Name)) { $BUMP[$grp.Name] } else { "bump this repo's build stamp" }
        Write-Host ("  {0,-14} {1} merged -> 1 build bump for the release: {2}" -f $grp.Name, $grp.Count, $how)
    }
    Write-Host "  then deploy each project you want live (zdeploy, by hand)"
}

if ($failed.Count -gt 0) { Write-ZTrailer; exit 1 }

Write-ZTrailer
