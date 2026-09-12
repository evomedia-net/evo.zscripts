# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.24

# zpull.ps1 - merge the fleet's ready PRs, then bring the local checkouts current.
#
# Usage:
#   zpull                     dry run: what would merge, what would pull
#   zpull -Execute            merge ready PRs, then pull every affected checkout
#   zpull -e                  the same; -e is an alias, as -s is for -Scan
#   zpull -Repo <name>        limit to one repo
#   zpull -Only 65            merge just these PR numbers
#   zpull -PullOnly           skip merging; only bring checkouts up to date
#   zpull -Execute -Yes       skip zmerge's confirmation prompt
#
# WHY THIS EXISTS
# ---------------
# zmerge stops at the merge, deliberately - deploys are run by hand. But the
# tooling repos are not deployed anywhere at all: they run
# from the local checkout. For those, "deployed" just means "pulled". Merging a
# zdeploy.ps1 fix and then forgetting the pull leaves you running the old file
# while GitHub says the bug is fixed - which is its own kind of lie.
#
# So: merge (via zmerge, which owns all the mergeability safety), then pull.
#
# WHAT IT WILL NOT DO
# -------------------
#   * pull over uncommitted work. It reports and skips. Twice this month a
#     checkout sat on a feature branch or held unstaged edits, and anything that
#     "helpfully" resolved that would have destroyed real work.
#   * pull anything but a fast-forward. A diverged local main is a decision,
#     not something a sync script should guess at.
#   * deploy to a server. Still by hand. This only touches local checkouts.
#
# HOW CHECKOUTS ARE FOUND
# -----------------------
# By reading each candidate directory's `origin` remote and matching the repo
# name, not from a hardcoded table - a table drifts the moment a directory is
# renamed, and this fleet renames directories.

[CmdletBinding(PositionalBinding = $false)]
param(
    [Alias('e')][switch]$Execute,
    [switch]$Yes,
    [switch]$PullOnly,
    # Sweep only the repos with no zdeploy target - the ones where a pull is
    # the whole job. Tooling, archives, libraries.
    [switch]$ReposOnly,
    [string]$Repo,
    [int[]]$Only = @(),
    [int[]]$Exclude = @(),
    # PowerShell binds --help to -Help on its own (it tolerates the extra
    # dash), so this one switch answers --help, -help and -h. The bare words
    # land in $Rest below and are handled there.
    [Alias('h')][switch]$Help,
    # Catches anything unmatched. Without it, PositionalBinding=$false makes an
    # unknown argument a raw PowerShell binding error - a wall of red that does
    # not say what the valid arguments are. Owning the message means a typo
    # gets the usage block instead.
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Rest = @()
)

$ErrorActionPreference = "Stop"

# Two blank lines at the end of a run, matching every other z-script, so output
# is separated from the next prompt. Local copy rather than ZHelpers: this
# script does not dot-source it.
function Write-ZTrailer { Write-Host ""; Write-Host "" }

$FLEET_ROOT = Split-Path -Parent $PSScriptRoot
$ORG = "evomedia-net"

function Show-ZPullUsage {
    Write-Host ""
    Write-Host "zpull - merge the fleet's ready PRs, then bring local checkouts current." -ForegroundColor Cyan
    Write-Host ""
    Write-Host "Usage: zpull [-Execute|-e] [-Yes] [-PullOnly] [-ReposOnly] [-Repo <name>] [-Only <n,n>] [-Exclude <n,n>]" -ForegroundColor Yellow
    Write-Host ""
    Write-Host "  (no args)          dry run - what would merge, what would pull. Changes nothing." -ForegroundColor Gray
    Write-Host "  -Execute, -e       actually merge ready PRs, then pull every affected checkout" -ForegroundColor Gray
    Write-Host "  -PullOnly          skip merging entirely; only bring checkouts up to date" -ForegroundColor Gray
    Write-Host "  -Repo <name>       limit to one repo, by its GitHub name" -ForegroundColor Gray
    Write-Host "  -Only <n,n>        merge just these PR numbers" -ForegroundColor Gray
    Write-Host "  -Exclude <n,n>     merge everything ready except these PR numbers" -ForegroundColor Gray
    Write-Host "  -ReposOnly         only repos with no deploy target (pull = done)" -ForegroundColor Gray
    Write-Host "  -Yes               skip zmerge's confirmation prompt (needs -Execute)" -ForegroundColor Gray
    Write-Host "  --help, -h         this text" -ForegroundColor Gray
    Write-Host ""
    Write-Host "What each result line means:" -ForegroundColor Yellow
    Write-Host "  ok      already current - nothing to do" -ForegroundColor Gray
    Write-Host "  PULLED  fast-forwarded to the new tip" -ForegroundColor Gray
    Write-Host "  SKIP    deliberately left alone: uncommitted work, not on the default" -ForegroundColor Gray
    Write-Host "          branch, or diverged. Never resolved automatically." -ForegroundColor Gray
    Write-Host "  FAIL    the repo could not be read or fetched. The sweep continues;" -ForegroundColor Gray
    Write-Host "          that one repo is simply not current." -ForegroundColor Gray
    Write-Host ""
    Write-Host "Each line is marked with what the repo still owes:" -ForegroundColor Yellow
    Write-Host "  [repo]             nothing runs from a server - the pull is the whole job" -ForegroundColor Gray
    Write-Host "  [zdeploy <key>]    a pull leaves the server on the old build" -ForegroundColor Gray
    Write-Host ""
    Write-Host "It will not pull over uncommitted work, will not do anything but a" -ForegroundColor DarkGray
    Write-Host "fast-forward, and will not deploy. Deploys stay manual." -ForegroundColor DarkGray
    Write-Host ""
    Write-Host "Checkouts are found by reading each directory's origin remote under" -ForegroundColor DarkGray
    Write-Host "$FLEET_ROOT, not from a hardcoded list." -ForegroundColor DarkGray
}

# Bare-word help too, matching the rest of the toolkit (zdeploy myapp, zkill all).
$helpWords = @('help', '?', '/?', '--help', '-help')
if ($Help -or @($Rest | Where-Object { $helpWords -contains $_.ToLowerInvariant() }).Count -gt 0) {
    Show-ZPullUsage
    Write-ZTrailer
    exit 0
}
if ($Rest.Count -gt 0) {
    Write-Host ""
    Write-Host "ERROR: unrecognised argument(s): $($Rest -join ', ')" -ForegroundColor Red
    Show-ZPullUsage
    Write-ZTrailer
    exit 1
}

function Get-DeployTargetsByPath {
    # Checkout path -> the zdeploy keys that ship from it.
    #
    # Read from zconfig rather than listed here: a second table would drift the
    # first time a target is added, and drift in THIS table is the failure it
    # exists to prevent - a repo quietly reported as "done at the pull" while a
    # server runs the old build.
    #
    # Matched by containment, not equality, because a target's localRoot is
    # often a subdirectory of its checkout (a service may ship from
    # <checkout>\<subdir>), and one checkout can carry several targets
    # (vidplayer ships cardiff, opensesame and kelly).
    $map = @{}
    # Read here rather than via ZHelpers' Get-ZConfig: this script is
    # standalone by design, and that helper exits the process when the config
    # is missing - which would turn "no zconfig" into a dead sweep instead of
    # a sweep that simply knows of no deploy targets.
    $configPath = if ($env:ZCONFIG) { $env:ZCONFIG } else { Join-Path $PSScriptRoot "zconfig.json" }
    if (-not (Test-Path -LiteralPath $configPath)) { return $map }
    try {
        $cfg = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
    } catch {
        Write-Host "  (zconfig.json unreadable - every repo will report as [repo])" -ForegroundColor Yellow
        return $map
    }
    if (-not $cfg.projects) { return $map }
    foreach ($key in $cfg.projects.PSObject.Properties.Name) {
        if ($key -like '_*') { continue }   # underscore keys are comments
        $root = $cfg.projects.$key.localRoot
        if (-not $root) { continue }
        try { $map[$key] = [System.IO.Path]::GetFullPath($root).TrimEnd('\') } catch { }
    }
    return $map
}

function Get-DeployKeysFor {
    param([string]$Path, [hashtable]$Targets)
    $full = [System.IO.Path]::GetFullPath($Path).TrimEnd('\')
    $hits = @()
    foreach ($key in $Targets.Keys) {
        $t = $Targets[$key]
        if ($t -eq $full -or $t.StartsWith($full + '\', [StringComparison]::OrdinalIgnoreCase)) {
            $hits += $key
        }
    }
    return @($hits | Sort-Object)
}

function Get-LocalCheckouts {
    # repo name -> local path, discovered from origin remotes.
    $map = @{}
    $candidates = @(Get-ChildItem -LiteralPath $FLEET_ROOT -Directory -ErrorAction SilentlyContinue)
    # One level deeper too: some projects keep theirs nested.
    foreach ($d in @($candidates)) {
        $candidates += @(Get-ChildItem -LiteralPath $d.FullName -Directory -ErrorAction SilentlyContinue)
    }
    foreach ($d in $candidates) {
        if (-not (Test-Path (Join-Path $d.FullName ".git"))) { continue }
        # A pruned worktree leaves a .git FILE pointing at an admin dir that no
        # longer exists, so Test-Path above passes and git then fails. Same
        # redirect trap as everywhere else, so keep this on Continue and judge
        # by exit code.
        $prev = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $url = (git -C $d.FullName remote get-url origin 2>$null)
        $ok = ($LASTEXITCODE -eq 0)
        $ErrorActionPreference = $prev
        if (-not $ok -or -not $url) { continue }
        if ($url -match "[:/]$ORG/([^/]+?)(\.git)?$") {
            $name = $Matches[1]
            if (-not $map.ContainsKey($name)) { $map[$name] = $d.FullName }
        }
    }
    return $map
}

function Get-DefaultBranch {
    # origin/HEAD is a LOCAL cache of the remote's default branch. It is written
    # at clone time, and repos created some other way (git init + remote add,
    # which is how the *-stack and hostops checkouts here were made) simply do
    # not have it. `git symbolic-ref` then fails with
    #   fatal: ref refs/remotes/origin/HEAD is not a symbolic ref
    # and - because this script runs under ErrorActionPreference='Stop' - PS 5.1
    # turns that redirected stderr into a TERMINATING NativeCommandError. The
    # 2>$null does not prevent it; it is the redirect itself that wraps each
    # stderr line in an ErrorRecord. So drop to Continue for the native calls.
    param([string]$Path)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $d = (git -C $Path symbolic-ref --short refs/remotes/origin/HEAD 2>$null) -replace '^origin/', ''
        if (-not $d) {
            # Repair the cache from the remote, then re-ask. Costs one network
            # round-trip on first run per repo and is permanent afterwards.
            git -C $Path remote set-head origin --auto 2>$null | Out-Null
            $d = (git -C $Path symbolic-ref --short refs/remotes/origin/HEAD 2>$null) -replace '^origin/', ''
        }
        if (-not $d) {
            # Offline, or no such remote. Believe the remote-tracking refs that
            # exist rather than assuming "main" - zscripts is on master, and
            # guessing wrong makes this script skip the repo with a misleading
            # "on 'master', not 'main'".
            foreach ($c in @('main', 'master')) {
                git -C $Path rev-parse --verify --quiet "refs/remotes/origin/$c" 2>$null | Out-Null
                if ($LASTEXITCODE -eq 0) { $d = $c; break }
            }
        }
        if (-not $d) { $d = (git -C $Path rev-parse --abbrev-ref HEAD 2>$null) }
        if (-not $d) { $d = "main" }
        return $d
    }
    finally { $ErrorActionPreference = $prev }
}

function Sync-Checkout {
    param([string]$Name, [string]$Path, [bool]$DoIt, [string[]]$DeployKeys = @())

    # Everything below judges git by $LASTEXITCODE, so drop to Continue for the
    # whole function (scoped, auto-reverts on exit).
    #
    # This is not tidiness. Under the script's ErrorActionPreference='Stop', a
    # stderr REDIRECT on a native command makes PS 5.1 wrap each stderr line in
    # a terminating ErrorRecord - so `git fetch origin 2>$null` against one
    # repo with an unreachable remote killed the ENTIRE sweep mid-list, leaving
    # every repo after it unvisited and unreported. A fleet sweep must survive
    # one bad repo; that repo gets a FAIL row and the run continues.
    $prev = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        Sync-CheckoutCore -Name $Name -Path $Path -DoIt $DoIt -DeployKeys $DeployKeys
    }
    catch {
        Write-Host ("  {0,-18} FAIL  {1}" -f $Name, $_.Exception.Message) -ForegroundColor Red
    }
    finally { $ErrorActionPreference = $prev }
}

function Sync-CheckoutCore {
    param([string]$Name, [string]$Path, [bool]$DoIt, [string[]]$DeployKeys = @())

    # Appended to every line: the point is that you never have to remember
    # which kind of repo you are looking at.
    $mark = if ($DeployKeys.Count -gt 0) { "  [zdeploy $($DeployKeys -join ', ')]" } else { "  [repo]" }

    $branch = (git -C $Path rev-parse --abbrev-ref HEAD 2>$null)
    if ($LASTEXITCODE -ne 0 -or -not $branch) {
        Write-Host ("  {0,-18} FAIL  not a usable git checkout: {1}{2}" -f $Name, $Path, $mark) -ForegroundColor Red
        return
    }
    $dirty  = @(git -C $Path status --porcelain --untracked-files=no 2>$null)
    $default = Get-DefaultBranch -Path $Path

    if ($dirty) {
        Write-Host ("  {0,-18} SKIP  uncommitted changes ({1} file(s)) - commit or stash first{2}" -f $Name, $dirty.Count, $mark) -ForegroundColor Yellow
        return
    }
    if ($branch -ne $default) {
        Write-Host ("  {0,-18} SKIP  on '{1}', not '{2}'{3}" -f $Name, $branch, $default, $mark) -ForegroundColor Yellow
        return
    }

    git -C $Path fetch origin --quiet 2>$null
    if ($LASTEXITCODE -ne 0) {
        # Unreachable remote, renamed repo, dead credential. Say so and move on
        # - continuing would compare against stale remote-tracking refs and
        # report "already current" about a repo we could not actually reach.
        Write-Host ("  {0,-18} FAIL  cannot fetch origin - check the remote{1}" -f $Name, $mark) -ForegroundColor Red
        return
    }
    $behind = (git -C $Path rev-list --count "HEAD..origin/$default" 2>$null)
    $ahead  = (git -C $Path rev-list --count "origin/$default..HEAD" 2>$null)

    if ([int]$ahead -gt 0) {
        Write-Host ("  {0,-18} SKIP  local '{1}' is {2} commit(s) ahead - diverged, resolve by hand{3}" -f $Name, $default, $ahead, $mark) -ForegroundColor Yellow
        return
    }
    if ([int]$behind -eq 0) {
        Write-Host ("  {0,-18} ok    already current{1}" -f $Name, $mark) -ForegroundColor DarkGray
        return
    }
    if (-not $DoIt) {
        Write-Host ("  {0,-18} would pull {1} commit(s){2}" -f $Name, $behind, $mark) -ForegroundColor Cyan
        return
    }
    git -C $Path merge --ff-only "origin/$default" --quiet 2>$null
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  {0,-18} PULLED {1} commit(s) -> {2}{3}" -f $Name, $behind, (git -C $Path rev-parse --short HEAD), $mark) -ForegroundColor Green
        # The whole reason the marker exists. A tooling repo is finished here;
        # a deployable one now has a checkout ahead of its own server, which is
        # the state that gets forgotten.
        foreach ($k in $DeployKeys) {
            Write-Host ("  {0,-18}        still on the old build - run: zdeploy {1}" -f "", $k) -ForegroundColor Yellow
        }
    } else {
        Write-Host ("  {0,-18} FAILED to fast-forward{1}" -f $Name, $mark) -ForegroundColor Red
    }
}

# ── 1. Merge ─────────────────────────────────────────────────────
if (-not $PullOnly) {
    Write-Host "`n=== Merging ready PRs (via zmerge) ===" -ForegroundColor Cyan
    # Hashtable splatting, not an array. Array splatting passes elements
    # positionally, so @("-Repo","<name>") fed "-Repo" into zmerge's
    # [int[]]$Exclude and died on the type conversion.
    $zm = @{}
    if ($Execute) { $zm.Execute = $true }
    if ($Yes)     { $zm.Yes     = $true }
    if ($Repo)    { $zm.Repo    = $Repo }
    if ($Only)    { $zm.Only    = $Only }
    if ($Exclude) { $zm.Exclude = $Exclude }
    & (Join-Path $PSScriptRoot "zmerge.ps1") @zm
}

# ── 2. Pull ──────────────────────────────────────────────────────
Write-Host "`n=== Bringing local checkouts current ===" -ForegroundColor Cyan
if (-not $Execute) {
    Write-Host "  (dry run - nothing will be pulled; add -Execute or -e)" -ForegroundColor DarkGray
}
$checkouts = Get-LocalCheckouts
if ($Repo) {
    if ($checkouts.ContainsKey($Repo)) { $checkouts = @{ $Repo = $checkouts[$Repo] } }
    else { Write-Host "  no local checkout found for '$Repo'" -ForegroundColor Yellow; $checkouts = @{} }
}
$targets = Get-DeployTargetsByPath
if ($ReposOnly) {
    Write-Host "  (-ReposOnly: repos with a zdeploy target are not listed)" -ForegroundColor DarkGray
}
$shown = 0
foreach ($name in ($checkouts.Keys | Sort-Object)) {
    $keys = Get-DeployKeysFor -Path $checkouts[$name] -Targets $targets
    if ($ReposOnly -and $keys.Count -gt 0) { continue }
    $shown++
    Sync-Checkout -Name $name -Path $checkouts[$name] -DoIt:$Execute -DeployKeys $keys
}
if ($shown -eq 0) { Write-Host "  nothing matched" -ForegroundColor DarkGray }
Write-ZTrailer
