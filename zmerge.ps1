# evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.30

# zmerge.ps1 - merge the fleet's ready pull requests in one pass.
#
# Usage:
#   zmerge                        dry run: list every open PR and its verdict
#   zmerge -Execute               merge everything that is genuinely ready
#   zmerge -e                     the same; -e is an alias, as -s is for -Scan
#   zmerge -Exclude 431           skip PRs by number (repeatable)
#   zmerge -Repo <name>           limit to one repo
#   zmerge -Only 68,67            merge just these
#   zmerge -Yes                   merge everything ready without asking
#   zmerge -y                     the same; -y is an alias. -Yes implies -Execute:
#                                 answering yes to a prompt is asking it to run
#   zmerge -Pull                  merge as -Execute does, then fast-forward every
#                                 local deploy checkout (zconfig.json projects)
#   zmerge -p                     the same; -p is an alias
#   zmerge -p -y                  merge and pull, no prompt
#   zmerge -p -Repo <name>        merge and pull one repo only
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
#   * merge a PR that names an open PR this run is not merging too - see
#     PAIRED PULL REQUESTS
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
#
# A FEW QUESTIONS, NOT FORTY
# --------------------------
# Every open PR in the org, with its draft flag, comes back from ONE GraphQL
# query (Get-FleetOpenPrs); merge status follows ten PRs to a request
# (Add-FleetMergeStates). This used to be one `gh pr list` per repository, one
# after another, then one `gh pr view` per PR: a dry run across 36
# repositories took 30 s on 2026-10-05, nearly all of it waiting on those
# calls one at a time. Only a PR GitHub is still computing (UNKNOWN) is polled
# on its own, and every PR is still re-checked on its own right before it is
# merged.
#
# Merge status is not in the fleet query because GitHub works it out on
# request, PR by PR. With 39 PRs open on 2026-10-28, asking for every one in
# that query went over GitHub's per-request budget on every run (#238). The
# list alone takes about 3 s, and each batch of ten about 3 s.
#
# PAIRED PULL REQUESTS
# --------------------
# A docs PR and the code PR it documents are one change in two repositories,
# and they must land together. On 2026-10-31 a product's docs PR merged on
# its own, its paired code PR still open, and the nightly test that holds the
# docs page and the code to each other went red. That test checks both ways,
# so whichever of the two lands first, a nightly run in between fails.
#
# So a PR waits for every open PR it names. "Names" means what GitHub would
# link in its title or description:
#   * a link to a pull request or issue in this org,
#   * org/repo#123,
#   * repo#123, for a repository in the org (the fleet's shorthand),
#   * a bare #123, meaning the PR's own repository.
# Code spans, fenced blocks and HTML comments are skipped, as GitHub skips them.
# A named number that is not an open PR (an issue, or a PR already merged)
# holds nothing, so "Closes #12" and "shipped in api#275" are free.
#
# A PR that names one this run will not merge is held, with the reason:
#   * not ready: a conflict, a draft, a failing check,
#   * held in turn, for a PR it names,
#   * left out of the run by -Repo, -Only or -Exclude.
# The PRs it names merge first. Two PRs that name each other, the usual pair,
# have both of their readiness re-checked right before the first one merges, so
# one cannot land alone because the other changed while the prompt waited.
# Naming is one way only: a PR waits for what it names, never for a PR that
# names it, so a draft follow-up cannot hold up the PR it follows. For a pair
# that must land together, name each PR in the other.
#
# -PULL: THE LOCAL CHECKOUTS, AFTERWARDS
# --------------------------------------
# A merge lands on GitHub; the checkouts on this machine stay where they were
# until something pulls them. zdeploy fast-forwards the one checkout it is
# deploying, but every other one - and the editor open on it - keeps showing
# the code from before the merge. -Pull closes that gap for every project in
# zconfig.json: after the merge step (whatever it merged, even nothing, and
# even when the prompt was declined) each checkout is fetched, all of them at
# once, then fast-forwarded to its default branch. Projects that share a
# repository (two apps in one monorepo, say) are pulled once.
#
# It only ever fast-forwards, so it cannot lose work:
#   * on the default branch: `merge --ff-only`. Local changes that the
#     incoming commits would overwrite make git refuse, and the row says so.
#   * on any other branch: the working tree is NOT touched and the branch is
#     NOT switched - another session may be working there. Only the local
#     default branch is moved, and only if that is a fast-forward and it is
#     not checked out in another worktree (git refuses both on its own).
#   * on chore/release-*: skipped entirely. That is zdeploy's release branch,
#     and it means a release is running in that checkout.
#   * local commits the remote does not have: skipped and reported, never
#     rebased or merged.
#
# ZCONFIG.JSON: THE zmerge SECTION
# --------------------------------
# Optional. Read whenever the run will merge (-Execute, -Pull, zdeploy -m/-p):
#
#   "zmerge": {
#     "pullAlso":     [ "<workspace>\\notes", "<workspace>\\scripts" ],
#     "preCommands":  [ "<a command to run before merging>" ],
#     "postCommands": [ "<a command to run after merging, and after -Pull>" ]
#   }
#
#   pullAlso      checkouts with no deploy target that -Pull keeps current
#                 too, under exactly the rules above. This is the way to
#                 include a repository, rather than a `git pull` in a
#                 post-command, which would bypass every one of them.
#   preCommands   run before the pull requests are read. Any that exits
#                 non-zero stops the run: nothing is merged, and the rest are
#                 not run.
#   postCommands  run at the end, whatever the merge step did (merged,
#                 nothing ready, declined). They all run; any failure makes
#                 the run exit 1. ZMERGE_MERGED holds the PRs merged this run
#                 as "repo#number", comma-separated.
#
# Each value may be one string or a list. A dry run (no -Execute) runs none of
# them.

param(
    [Alias('e')][switch]$Execute,
    # -Pull / -p: merge as -Execute does, then fast-forward every local deploy
    # checkout. Implies -Execute; the confirmation prompt still asks unless
    # -Yes is given.
    [Alias('p')][switch]$Pull,
    # -Yes / -y: skip the confirmation prompt and merge. Implies -Execute -
    # without it, -Yes alone would quietly fall back to the dry run, which is
    # the opposite of what typing "yes" asks for.
    [Alias('y')][switch]$Yes,
    [int[]]$Exclude = @(),
    [int[]]$Only = @(),
    [string]$Repo,
    [int]$PollTries = 6,
    [int]$PollDelaySeconds = 4
)

$ErrorActionPreference = "Stop"
if ($Pull -or $Yes) { $Execute = [switch]$true }

# Two blank lines at the end of a run, matching every other z-script, so output
# is separated from the next prompt. Local copy rather than ZHelpers: this
# script does not dot-source it.
function Write-ZTrailer { Write-Host ""; Write-Host "" }

# ── -Pull ───────────────────────────────────────────────────────────────────

# One git call in one directory. Never throws: the caller judges the exit code
# and reports it on that checkout's row, so one bad checkout cannot stop the
# rest. Continue, because git writes ordinary progress to stderr and under Stop
# Windows PowerShell 5.1 turns that into a terminating error.
function Invoke-PullGit {
    param([Parameter(Mandatory)][string]$Dir, [Parameter(Mandatory)][string[]]$GitArgs)
    $ErrorActionPreference = 'Continue'
    $out = & git -C $Dir @GitArgs 2>&1 | ForEach-Object { "$_" }
    return [pscustomobject]@{ Code = $LASTEXITCODE; Output = @($out) }
}

# A zconfig.json value that may be one string or a list of them, as a list.
# Absent, null or empty is an empty list, so an unconfigured hook is a no-op.
function Get-ZMergeList {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @(@($Value) | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
}

# Every checkout -Pull covers, once each, with what it is there for: each
# project's localRoot (keys starting with "_" are comments, not projects - the
# same rule as Get-ZProjectKeys), then zmerge.pullAlso, the checkouts that
# have no deploy target but should still be kept current (a notes repository,
# the scripts themselves). A pullAlso path that is also a deploy root is listed
# once.
function Get-DeployCheckoutRoots {
    param([Parameter(Mandatory)]$Config)
    $roots = [ordered]@{}
    $add = {
        param([string]$Root, [string]$Label)
        $Root = $Root.TrimEnd('\', '/')
        $key = $Root.ToLowerInvariant()
        if (-not $roots.Contains($key)) {
            $roots[$key] = [pscustomobject]@{ Root = $Root; Projects = @() }
        }
        $roots[$key].Projects += $Label
    }
    if ($Config.projects) {
        foreach ($prop in $Config.projects.PSObject.Properties) {
            if ($prop.Name.StartsWith('_')) { continue }
            if ($prop.Value.localRoot) { & $add $prop.Value.localRoot $prop.Name }
        }
    }
    if ($Config.zmerge) {
        foreach ($p in (Get-ZMergeList $Config.zmerge.pullAlso)) { & $add $p 'pullAlso' }
    }
    return @($roots.Values)
}

# zmerge.preCommands / zmerge.postCommands: commands run before the merge step
# and after it (after -Pull, when that is given). Each runs in its own
# PowerShell, attached to this console, so its output and colours appear as
# they would by hand. The command goes in base64 (-EncodedCommand): Windows
# PowerShell 5.1 mangles embedded double quotes on a native command line, and
# a hook is exactly where someone writes a quoted path.
#
# A pre-command that fails stops the run before anything is merged - it is a
# gate - and the rest are not run. Post-commands all run; each failure counts.
# They see ZMERGE_PHASE (pre or post) and, after the merge, ZMERGE_MERGED: the
# PRs merged this run as "repo#number", comma-separated, empty if none.
# Returns the number that failed.
function Invoke-ZMergeHooks {
    param(
        [Parameter(Mandatory)][ValidateSet('pre', 'post')][string]$Phase,
        [string[]]$Commands = @(),
        [string[]]$Merged = @(),
        [string]$HostExe = ([System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName)
    )
    $failed = 0
    $env:ZMERGE_PHASE = $Phase
    $env:ZMERGE_MERGED = ($Merged -join ',')
    foreach ($cmd in $Commands) {
        Write-Host ""
        Write-Host "--- $Phase-merge command: $cmd" -ForegroundColor Cyan
        # Progress off: a child whose output is captured (CI, a log) would
        # otherwise write its progress records as CLIXML noise.
        $encoded = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes("`$ProgressPreference = 'SilentlyContinue'; $cmd"))
        # Waits for the hook itself, not with -Wait, which also waits for
        # every process the hook leaves running (#228): a hook that starts a
        # server, or runs git in a repo with core.fsmonitor=true, would hang
        # zmerge for as long as that process lives. .Handle keeps ExitCode
        # readable after the process has gone.
        $proc = Start-Process -FilePath $HostExe -ArgumentList "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encoded" -NoNewWindow -PassThru
        $null = $proc.Handle
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            Write-Host "    exited $($proc.ExitCode)" -ForegroundColor Red
            $failed++
            if ($Phase -eq 'pre') { break }
        }
    }
    return $failed
}

# localRoots are folded onto the repository that holds them: a localRoot that
# is a subfolder of another project's repository, or three projects that share
# one checkout, are pulled as one. A root that is missing, or not inside a repository, is
# returned separately so it can be reported rather than silently dropped.
function Resolve-PullCheckouts {
    param([object[]]$Roots)
    $tops = [ordered]@{}
    $unusable = @()
    foreach ($r in $Roots) {
        if (-not (Test-Path -LiteralPath $r.Root)) {
            $unusable += [pscustomobject]@{ Root = $r.Root; Projects = $r.Projects; Why = 'folder not found' }
            continue
        }
        $g = Invoke-PullGit -Dir $r.Root -GitArgs @('rev-parse', '--show-toplevel')
        if ($g.Code -ne 0) {
            $unusable += [pscustomobject]@{ Root = $r.Root; Projects = $r.Projects; Why = 'not inside a git repository' }
            continue
        }
        $top = (($g.Output | Select-Object -First 1) -replace '/', '\').Trim()
        $key = $top.ToLowerInvariant()
        if (-not $tops.Contains($key)) {
            $tops[$key] = [pscustomobject]@{ Top = $top; Projects = @() }
        }
        $tops[$key].Projects += $r.Projects
    }
    return [pscustomobject]@{ Checkouts = @($tops.Values); Unusable = @($unusable) }
}

# Fetch every checkout at once. One fetch is a network round trip of a second
# or two; thirty of them one after another was most of a minute spent waiting.
# Prompts are switched off so a credential problem fails the row instead of
# waiting forever for an answer nobody is there to give. Returns a table of
# directory -> @{ Code; Error }.
function Invoke-ParallelFetch {
    param([string[]]$Dirs, [int]$Throttle = 8, [int]$TimeoutSeconds = 120)
    $git = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $results = @{}
    $queue = New-Object System.Collections.Queue
    foreach ($d in $Dirs) { $queue.Enqueue($d) }
    $running = @()
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    while ($queue.Count -gt 0 -or $running.Count -gt 0) {
        while ($queue.Count -gt 0 -and $running.Count -lt $Throttle) {
            $dir = $queue.Dequeue()
            $psi = New-Object System.Diagnostics.ProcessStartInfo
            $psi.FileName = $git
            $psi.Arguments = '-C "' + $dir + '" fetch origin --prune --quiet'
            $psi.UseShellExecute = $false
            $psi.CreateNoWindow = $true
            $psi.RedirectStandardError = $true
            $psi.RedirectStandardOutput = $true
            $psi.EnvironmentVariables['GIT_TERMINAL_PROMPT'] = '0'
            $psi.EnvironmentVariables['GCM_INTERACTIVE'] = 'never'
            $proc = [System.Diagnostics.Process]::Start($psi)
            # Read both streams as they come, so a chatty fetch cannot fill a
            # pipe and stall waiting for a reader.
            $running += [pscustomobject]@{
                Dir = $dir; Proc = $proc
                Err = $proc.StandardError.ReadToEndAsync()
                Out = $proc.StandardOutput.ReadToEndAsync()
            }
        }
        $still = @()
        foreach ($r in $running) {
            if ($r.Proc.HasExited) {
                $r.Proc.WaitForExit()
                $msg = (($r.Err.Result + $r.Out.Result) -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
                $results[$r.Dir] = [pscustomobject]@{ Code = $r.Proc.ExitCode; Error = "$msg".Trim() }
            } elseif ((Get-Date) -gt $deadline) {
                try { $r.Proc.Kill() } catch { }
                $results[$r.Dir] = [pscustomobject]@{ Code = -1; Error = "fetch still running after $TimeoutSeconds s - stopped" }
            } else {
                $still += $r
            }
        }
        $running = $still
        if ($running.Count -gt 0) { Start-Sleep -Milliseconds 100 }
    }
    return $results
}

# What to do with one checkout, from facts git has already answered. Pure, so
# every rule in the header is held by a test without a repository.
#   ff         on the default branch and behind: fast-forward it
#   ff-ref     on another branch, default behind: move only the default ref
#   current    nothing new on origin
#   ahead      local commits origin lacks, nothing new: nothing to pull
#   diverged   both: never reconciled automatically
#   release    chore/release-*: a zdeploy release is running here
#   detached   no branch to fast-forward
#   no-default no local default branch to move
function Get-PullAction {
    param([string]$Branch, [string]$Default, [int]$Ahead, [int]$Behind, [bool]$HasDefault = $true)
    if ($Branch -like 'chore/release-*') { return 'release' }
    if ($Branch -eq 'HEAD') { return 'detached' }
    if (-not $HasDefault) { return 'no-default' }
    if ($Behind -eq 0) { if ($Ahead -gt 0) { return 'ahead' } else { return 'current' } }
    if ($Ahead -gt 0) { return 'diverged' }
    if ($Branch -eq $Default) { return 'ff' }
    return 'ff-ref'
}

# Fetch and fast-forward every deploy checkout; print one row each. Returns the
# number of rows that FAILED (a fetch or a fast-forward git refused), which is
# what makes the run exit non-zero. Skips are reported but are not failures:
# they are the cases this deliberately leaves alone.
function Sync-DeployCheckouts {
    param([Parameter(Mandatory)]$Config, [string]$RepoFilter)
    $resolved = Resolve-PullCheckouts -Roots (Get-DeployCheckoutRoots -Config $Config)
    $checkouts = @($resolved.Checkouts)
    foreach ($c in $checkouts) {
        $u = Invoke-PullGit -Dir $c.Top -GitArgs @('remote', 'get-url', 'origin')
        $name = if ($u.Code -eq 0) { ((($u.Output | Select-Object -First 1).Trim()) -replace '\.git$', '') -replace '^.*[/:]', '' } else { Split-Path -Leaf $c.Top }
        $c | Add-Member -NotePropertyName Repo -NotePropertyValue $name -Force
    }
    if ($RepoFilter) { $checkouts = @($checkouts | Where-Object { $_.Repo -eq $RepoFilter }) }

    Write-Host ""
    Write-Host "Pulling $($checkouts.Count) local deploy checkout(s), fetching all at once..." -ForegroundColor Cyan
    $fetched = Invoke-ParallelFetch -Dirs @($checkouts | ForEach-Object { $_.Top })

    $failures = 0
    foreach ($c in $checkouts) {
        $label = '{0} ({1})' -f $c.Repo, (Split-Path -Leaf $c.Top)
        $f = $fetched[$c.Top]
        if (-not $f -or $f.Code -ne 0) {
            $why = if ($f) { $f.Error } else { 'not fetched' }
            Write-Host ("  FAILED  {0,-34} fetch: {1}" -f $label, $why) -ForegroundColor Red
            $failures++
            continue
        }

        # The default branch is the remote's answer, not an assumption; a
        # clone that never recorded origin/HEAD falls back to main, then master.
        $d = Invoke-PullGit -Dir $c.Top -GitArgs @('symbolic-ref', '--short', 'refs/remotes/origin/HEAD')
        $default = if ($d.Code -eq 0) { (($d.Output | Select-Object -First 1).Trim()) -replace '^origin/', '' } else { $null }
        if (-not $default) {
            foreach ($cand in @('main', 'master')) {
                $v = Invoke-PullGit -Dir $c.Top -GitArgs @('rev-parse', '--verify', '--quiet', "refs/remotes/origin/$cand")
                if ($v.Code -eq 0) { $default = $cand; break }
            }
        }
        if (-not $default) {
            Write-Host ("  SKIP    {0,-34} no origin/main or origin/master" -f $label) -ForegroundColor Yellow
            continue
        }

        $branch = ((Invoke-PullGit -Dir $c.Top -GitArgs @('rev-parse', '--abbrev-ref', 'HEAD')).Output | Select-Object -First 1).Trim()
        $hasDefault = (Invoke-PullGit -Dir $c.Top -GitArgs @('rev-parse', '--verify', '--quiet', "refs/heads/$default")).Code -eq 0
        $ahead = 0; $behind = 0
        if ($hasDefault) {
            $counts = Invoke-PullGit -Dir $c.Top -GitArgs @('rev-list', '--left-right', '--count', "refs/heads/$default...refs/remotes/origin/$default")
            $parts = (($counts.Output | Select-Object -First 1).Trim()) -split '\s+'
            if ($counts.Code -eq 0 -and $parts.Count -eq 2) { $ahead = [int]$parts[0]; $behind = [int]$parts[1] }
        }
        $action = Get-PullAction -Branch $branch -Default $default -Ahead $ahead -Behind $behind -HasDefault $hasDefault
        $plural = if ($behind -eq 1) { '' } else { 's' }

        switch ($action) {
            'ff' {
                $m = Invoke-PullGit -Dir $c.Top -GitArgs @('merge', '--ff-only', '--quiet', "refs/remotes/origin/$default")
                if ($m.Code -eq 0) {
                    $now = ((Invoke-PullGit -Dir $c.Top -GitArgs @('log', '-1', '--format=%h %s')).Output | Select-Object -First 1)
                    Write-Host ("  PULLED  {0,-34} {1} +{2} commit{3} -> {4}" -f $label, $default, $behind, $plural, $now) -ForegroundColor Green
                } else {
                    $why = ($m.Output | Where-Object { $_.Trim() } | Select-Object -First 1)
                    Write-Host ("  FAILED  {0,-34} {1} is {2} behind; git refused the fast-forward: {3}" -f $label, $default, $behind, $why) -ForegroundColor Red
                    $failures++
                }
            }
            'ff-ref' {
                # A local fetch: git itself refuses a non-fast-forward, and a
                # branch checked out in another worktree. The working tree is
                # never touched.
                $m = Invoke-PullGit -Dir $c.Top -GitArgs @('fetch', '--quiet', '.', "refs/remotes/origin/${default}:refs/heads/$default")
                if ($m.Code -eq 0) {
                    Write-Host ("  BRANCH  {0,-34} on {1}, left as it is; {2} moved +{3} commit{4}" -f $label, $branch, $default, $behind, $plural) -ForegroundColor Cyan
                } else {
                    Write-Host ("  SKIP    {0,-34} on {1}; {2} is {3} behind but is checked out elsewhere" -f $label, $branch, $default, $behind) -ForegroundColor Yellow
                }
            }
            'current' {
                $where = if ($branch -ne $default) { " (on $branch)" } else { '' }
                Write-Host ("  CURRENT {0,-34} {1}{2}" -f $label, $default, $where) -ForegroundColor DarkGray
            }
            'ahead' {
                Write-Host ("  AHEAD   {0,-34} {1} has {2} local commit(s) origin does not - nothing to pull" -f $label, $default, $ahead) -ForegroundColor Yellow
            }
            'diverged' {
                Write-Host ("  SKIP    {0,-34} {1} has diverged: {2} local, {3} on origin - reconcile by hand" -f $label, $default, $ahead, $behind) -ForegroundColor Yellow
            }
            'release' {
                Write-Host ("  SKIP    {0,-34} on {1}: a zdeploy release is running here" -f $label, $branch) -ForegroundColor Yellow
            }
            'detached' {
                Write-Host ("  SKIP    {0,-34} detached HEAD - no branch to fast-forward" -f $label) -ForegroundColor Yellow
            }
            'no-default' {
                Write-Host ("  SKIP    {0,-34} no local {1} branch" -f $label, $default) -ForegroundColor Yellow
            }
        }
    }
    foreach ($u in $resolved.Unusable) {
        Write-Host ("  SKIP    {0,-34} {1} ({2})" -f ($u.Projects -join ', '), $u.Why, $u.Root) -ForegroundColor Yellow
    }
    return $failures
}

# The end of every run that got as far as the merge step, whatever it did:
# merged, found nothing ready, or was declined at the prompt. With -Pull the
# checkouts are pulled, then the post-merge commands run. A pull or
# post-command failure makes an otherwise clean run exit 1, as a failed merge
# does.
function Complete-Run {
    param([int]$Code)
    if ($Pull) {
        $pullFailed = Sync-DeployCheckouts -Config $ZCFG -RepoFilter $Repo
        if ($pullFailed -gt 0 -and $Code -eq 0) { $Code = 1 }
    }
    if ($ZCFG -and $ZCFG.zmerge) {
        $post = Get-ZMergeList $ZCFG.zmerge.postCommands
        if ($post.Count -gt 0) {
            $done = @($merged | ForEach-Object { "$($_.Repo)#$($_.Number)" })
            $postFailed = Invoke-ZMergeHooks -Phase post -Commands $post -Merged $done
            if ($postFailed -gt 0 -and $Code -eq 0) { $Code = 1 }
        }
    }
    Write-ZTrailer
    exit $Code
}

# zconfig.json is read before anything is merged, when this run will merge:
# for -Pull's checkouts and for zmerge.preCommands / postCommands. A plain
# `zmerge -e` with no config still merges, as it always has; -Pull without one
# stops here, before the merge rather than after it. A config that exists but
# does not parse stops the run too: carrying on would skip its hooks silently.
# ZCONFIG overrides the path, as it does for every z-script.
$ZCFG = $null
$merged = @()
if ($Execute) {
    $cfgPath = if ($env:ZCONFIG) { $env:ZCONFIG } else { Join-Path $PSScriptRoot 'zconfig.json' }
    if (Test-Path -LiteralPath $cfgPath) {
        try {
            $ZCFG = Get-Content -LiteralPath $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch {
            Write-Host "zconfig.json at $cfgPath does not parse: $($_.Exception.Message)" -ForegroundColor Red
            Write-ZTrailer
            exit 1
        }
    } elseif ($Pull) {
        Write-Host "-Pull reads the deploy checkouts from zconfig.json, and there is none at $cfgPath." -ForegroundColor Red
        Write-ZTrailer
        exit 1
    }
    if ($ZCFG -and $ZCFG.zmerge) {
        $pre = Get-ZMergeList $ZCFG.zmerge.preCommands
        if ($pre.Count -gt 0 -and (Invoke-ZMergeHooks -Phase pre -Commands $pre) -gt 0) {
            Write-Host "A pre-merge command failed - nothing merged." -ForegroundColor Red
            Write-ZTrailer
            exit 1
        }
    }
}

# Every non-archived repository in the org and every open pull request in it,
# asked of GitHub in one query rather than remembered here or asked repository
# by repository. Merge status is NOT in it: see $MERGE_STATE_QUERY.
#
# Local to this script for the same reason Write-ZTrailer is: zmerge needs gh
# and nothing else, and dot-sourcing 1,200 lines of deploy helpers for one
# function would trade that away.
#
# THROWS rather than returning an empty list when gh fails. A merge tool that
# quietly scans nothing prints exactly the same reassuring line as one that
# scanned everything and found nothing, and those two must never be
# confusable - which is precisely how the list this replaced hid its own rot.
# The per-repository `gh pr list` it replaced was worse still: a repository
# whose call failed simply contributed no PRs.
#
# No double quotes anywhere in the query: Windows PowerShell 5.1 mangles
# embedded quotes when it builds a native command line, so every value goes in
# as a GraphQL variable instead of a literal.
$FLEET_QUERY = @'
query($org: String!, $after: String) {
  organization(login: $org) {
    repositories(first: 100, after: $after, isArchived: false, orderBy: {field: NAME, direction: ASC}) {
      pageInfo { hasNextPage endCursor }
      nodes {
        name
        pullRequests(states: OPEN, first: 100, orderBy: {field: CREATED_AT, direction: DESC}) {
          pageInfo { hasNextPage }
          nodes { id number title isDraft state body }
        }
      }
    }
  }
}
'@

# Merge status for a few PRs at a time, by id. GitHub works mergeable and
# mergeStateStatus out on request, PR by PR, and mergeStateStatus is the
# expensive half: asked for all 39 open PRs in the fleet query on 2026-10-28 it
# took 11 s and went over GitHub's per-request budget ("Resource limits for
# this query exceeded", or a 502 when GitHub gave up before answering), on
# every run (#238). Ten PRs a request answer in about 3 s.
$MERGE_STATE_QUERY = @'
query($ids: [ID!]!) {
  nodes(ids: $ids) {
    ... on PullRequest { id mergeable mergeStateStatus }
  }
}
'@

# The query's pages, flattened: repository names A-Z, and each repository's
# PRs newest first, as `gh pr list` listed them. Throws on anything that would
# otherwise read as "fewer PRs than there are" - an errors field, a page with
# no repository list, a repository with more open PRs than one page holds.
function ConvertFrom-FleetPrPages {
    param([Parameter(Mandatory)][object[]]$Pages, [string]$Org = $ORG)
    $names = @()
    $prs = @()
    foreach ($page in $Pages) {
        if ($page.errors) {
            throw "GitHub answered the fleet query with errors: $((@($page.errors) | ForEach-Object { $_.message }) -join '; ')"
        }
        $repos = $page.data.organization.repositories
        if (-not $repos) { throw "GitHub returned no repository list for $Org" }
        foreach ($node in @($repos.nodes)) {
            if (-not $node) { continue }
            $names += $node.name
            if ($node.pullRequests.pageInfo.hasNextPage) {
                throw "$($node.name) has more open pull requests than one page of the fleet query holds (100) - zmerge would miss some; raise the page size"
            }
            foreach ($pr in @($node.pullRequests.nodes)) {
                if (-not $pr) { continue }
                # Mergeable and MergeState are filled in by Add-FleetMergeStates;
                # until then a verdict reads them as "not answered yet".
                $prs += [pscustomobject]@{
                    Repo       = $node.name
                    Number     = [int]$pr.number
                    Id         = $pr.id
                    Title      = $pr.title
                    # Read for the PRs it names: see PAIRED PULL REQUESTS.
                    Body       = "$($pr.body)"
                    Draft      = [bool]$pr.isDraft
                    State      = $pr.state
                    Mergeable  = $null
                    MergeState = $null
                }
            }
        }
    }
    if ($names.Count -eq 0) { throw "no repositories came back for $Org - every one archived, or none visible to this token?" }
    return [pscustomobject]@{
        Repos = @($names | Sort-Object)
        Prs   = @($prs | Sort-Object Repo, @{ Expression = 'Number'; Descending = $true })
    }
}

# True when gh failed because GitHub had a bad moment, not because the request
# was wrong: the 5xx answers, and the "Unicorn!" page github.com serves in
# place of JSON when a request fails or times out on its side (#236). A local
# copy of zbump's, which this script does not dot-source; a test holds the two
# to one pattern.
function Test-TransientGhError([string]$Text) {
    return [bool]($Text -match '(?i)HTTP 5\d\d|\b50[0234]\b|Internal Server Error|Bad Gateway|Service Unavailable|Gateway Time-?out|Something went wrong while executing your query|connection reset|i/o timeout|Unicorn!|<!DOCTYPE html|<html')
}

# What gh answered, in one line. GitHub's error pages are a screen of HTML,
# CSS and a base64 image, of which only the title says anything; a plain
# error keeps its first line (#236).
function Get-GhFailureSummary([string]$Text) {
    # A signed-out gh is named as that, not as the rate limit GitHub's words
    # suggest (#282).
    $auth = Get-GhAuthProblem -Code 1 -Text $Text
    if ($auth) { return $auth }
    if ($Text -match '(?is)<title>\s*(.*?)\s*</title>') {
        $title = [System.Net.WebUtility]::HtmlDecode($Matches[1]) -replace '\s+', ' '
        return "GitHub answered with its '$title' page instead of JSON (a failure on GitHub's side)"
    }
    if ($Text -match '(?i)<!DOCTYPE html|<html') {
        return "GitHub answered with an HTML page instead of JSON (a failure on GitHub's side)"
    }
    $line = @($Text -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
    if ($line.Count -eq 0) { return '(no output)' }
    $line = $line[0].Trim()
    if ($line.Length -gt 200) { $line = $line.Substring(0, 200) + '...' }
    return $line
}

# What is wrong with gh's login, or $null if nothing is (#282). zbump keeps a
# copy; a test holds the two to one text.
#
# After the 2026-11-18 reboot, gh's stored token was empty but gh still
# believed it was signed in, so it sent requests with no login at all. GitHub
# allows no GraphQL requests without a login, and refuses them in its
# rate-limit wording: "API rate limit exceeded for <IP>. (But here's the good
# news: Authenticated requests get a higher rate limit...)". zmerge passed that
# straight on, and a deploy stopped over a rate limit that did not exist.
#
# $Text is what gh printed. $Code is its exit code. When $Code is 0, $Text is
# the core limit from `gh api rate_limit`: 60 means the request carried no
# login, against 5000 for a signed-in one. Anything this does not recognise
# (a network failure, a 5xx) gives $null and is left to the caller's own
# handling, so a bad moment at GitHub is never reported as a sign-out.
function Get-GhAuthProblem {
    param([int]$Code, [string]$Text)
    $fix = 'Run: gh auth login -h github.com -w'
    if ($Text -match '(?i)Authenticated requests get a higher rate limit') {
        return "gh is not signed in: it sent the request with no login, and GitHub refused it with a rate-limit message. $fix"
    }
    if ($Text -match '(?i)Bad credentials|HTTP 401') {
        return "gh's login no longer works: GitHub answered 401 Bad credentials. $fix"
    }
    # gh exits 4 when it has no login to send, and words it by where it runs:
    # "To get started with GitHub CLI" on a workstation, "To use GitHub CLI in
    # a GitHub Actions workflow" on a GitHub runner. The code decides.
    if ($Code -eq 4 -or $Text -match '(?i)To get started with GitHub CLI|To use GitHub CLI in a GitHub Actions workflow') {
        return "gh is not signed in. $fix"
    }
    if ($Code -eq 0 -and $Text -match '^\s*(\d+)\s*$' -and [int]$Matches[1] -le 60) {
        return "gh is not signed in: GitHub gave it the $($Matches[1])-an-hour allowance for requests with no login. $fix"
    }
    return $null
}

# Stop before any GitHub work if gh has no working login (#282). It asks
# /rate_limit, which costs no quota, because that shows whether a request
# actually carried a login. `gh auth status` would only say what is stored.
function Assert-GhSignedIn {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return }   # the caller says gh is missing
    $ErrorActionPreference = 'Continue'
    $raw = & gh api rate_limit --jq .resources.core.limit 2>&1 | ForEach-Object { "$_" }
    $problem = Get-GhAuthProblem -Code $LASTEXITCODE -Text ($raw -join "`n")
    if ($problem) { throw $problem }
}

# One GraphQL request, parsed. A transient failure gets up to $Attempts tries,
# $RetryDelaySeconds apart, as zbump gives a merge: one bad second at GitHub
# should not end a fleet merge and the deploy waiting behind it (#236).
# Anything else throws at once, in one line.
function Invoke-GhGraphql {
    param(
        [Parameter(Mandatory)][string[]]$GhArgs,
        [int]$Attempts = 3,
        [int]$RetryDelaySeconds = 5
    )
    # zmerge runs with Stop; in Windows PowerShell 5.1 a native command's
    # stderr under 2>&1 is then a terminating error, before the exit code can
    # be read and reported properly.
    $ErrorActionPreference = 'Continue'
    for ($attempt = 1; ; $attempt++) {
        $raw = & gh @GhArgs 2>&1 | ForEach-Object { "$_" }
        $text = $raw -join "`n"
        $code = $LASTEXITCODE
        if ($code -eq 0) { break }
        $why = Get-GhFailureSummary $text
        if ($attempt -ge $Attempts -or -not (Test-TransientGhError $text)) {
            throw "gh api graphql failed ($code): $why"
        }
        Write-Host "  $why; trying again in $RetryDelaySeconds s ($attempt of $Attempts)..." -ForegroundColor Yellow
        Start-Sleep -Seconds $RetryDelaySeconds
    }
    try { return ($text | ConvertFrom-Json) } catch {
        throw "gh api graphql did not return JSON: $(Get-GhFailureSummary $text)"
    }
}

# Ask GitHub, following the repository pages until there are no more.
function Get-FleetOpenPrs {
    param(
        [Parameter(Mandatory)][string]$Org,
        [int]$Attempts = 3,
        [int]$RetryDelaySeconds = 5
    )
    $query = ($FLEET_QUERY -replace '\s+', ' ').Trim()
    $pages = @()
    $after = $null
    do {
        $ghArgs = @('api', 'graphql', '-f', "query=$query", '-f', "org=$Org")
        if ($after) { $ghArgs += @('-f', "after=$after") }
        $page = Invoke-GhGraphql -GhArgs $ghArgs -Attempts $Attempts -RetryDelaySeconds $RetryDelaySeconds
        $pages += $page
        $repos = $page.data.organization.repositories
        $after = $null
        if ($repos -and $repos.pageInfo.hasNextPage) { $after = $repos.pageInfo.endCursor }
    } while ($after)
    return ConvertFrom-FleetPrPages -Pages $pages -Org $Org
}

# Fill in Mergeable and MergeState on each open, non-draft PR, $BatchSize PRs
# to a request (#238). Drafts and closed PRs are never asked about: their
# verdict does not depend on it. A PR GitHub does not answer for keeps no merge
# status, which Get-PrVerdict reads as "not answered yet", so it is polled on
# its own with `gh pr view` - a gap here can cost a call, never read as ready.
# A batch that keeps failing throws, as the fleet query does.
function Add-FleetMergeStates {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Prs,
        [int]$BatchSize = 10,
        [int]$Attempts = 3,
        [int]$RetryDelaySeconds = 5
    )
    $want = @($Prs | Where-Object { $_ -and $_.State -eq 'OPEN' -and -not $_.Draft -and $_.Id })
    if ($want.Count -eq 0) { return }
    $query = ($MERGE_STATE_QUERY -replace '\s+', ' ').Trim()
    for ($i = 0; $i -lt $want.Count; $i += $BatchSize) {
        $batch = @($want[$i..([Math]::Min($i + $BatchSize, $want.Count) - 1)])
        $ghArgs = @('api', 'graphql', '-f', "query=$query")
        foreach ($p in $batch) { $ghArgs += @('-f', "ids[]=$($p.Id)") }
        $page = Invoke-GhGraphql -GhArgs $ghArgs -Attempts $Attempts -RetryDelaySeconds $RetryDelaySeconds
        if ($page.errors) {
            throw "GitHub answered the merge-status query with errors: $((@($page.errors) | ForEach-Object { $_.message }) -join '; ')"
        }
        $byId = @{}
        foreach ($n in @($page.data.nodes)) { if ($n -and $n.id) { $byId[$n.id] = $n } }
        foreach ($p in $batch) {
            $n = $byId[$p.Id]
            if (-not $n) { continue }
            $p.Mergeable = $n.mergeable
            $p.MergeState = $n.mergeStateStatus
        }
    }
}

# ── Paired pull requests ────────────────────────────────────────────────────

# The PRs a PR's text names, as "repo#number" with the repository spelt as
# $Repos spells it, so a name compares equal to a PR's "$Repo#$Number". The
# forms are those in PAIRED PULL REQUESTS. Only repositories in $Repos count,
# and the PR never names itself. Pure: whether a name is an OPEN PR is the
# caller's question, since an issue number and a merged PR hold nothing.
function Get-NamedPr {
    param(
        [AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Repo,
        [int]$Number = 0,
        [string[]]$Repos = @(),
        [string]$Org = $ORG
    )
    if (-not $Text) { return @() }
    $canon = @{}
    foreach ($r in (@($Repos) + $Repo)) { if ($r) { $canon[$r.ToLowerInvariant()] = $r } }

    # What GitHub does not turn into a link is not a reference: fenced blocks
    # (an unclosed one runs to the end, as GitHub renders it), HTML comments
    # and code spans.
    $t = $Text -replace '(?ms)^[ \t]*(`{3,}|~{3,}).*?(?:^[ \t]*\1|\z)', ' '
    $t = $t -replace '(?s)<!--.*?-->', ' '
    $t = $t -replace '`[^`\r\n]*`', ' '
    # A markdown link names what it points at, not what its text says:
    # [#1183](https://github.com/<org>/app/pull/1183) is app#1183,
    # whichever repository the PR carrying it is in.
    $t = $t -replace '\[[^\]\r\n]*\]\(\s*<?([^)\s>]+)>?[^)]*\)', ' $1 '

    # Each name with where it stands in the text, so they come back in the
    # order they were written whatever form each took.
    $hits = @()
    $orgRx = [regex]::Escape($Org)
    foreach ($m in [regex]::Matches($t, "(?i)https?://github\.com/$orgRx/([\w.-]+)/(?:pull|issues)/(\d+)")) {
        $hits += [pscustomobject]@{ At = $m.Index; Repo = $m.Groups[1].Value; Num = $m.Groups[2].Value }
    }
    # Every URL blanked out, ours or not, so no part of one reads as a
    # reference below. Blanked to its own length, so positions still compare.
    $t = [regex]::Replace($t, 'https?://\S+', { param($m) ' ' * $m.Length })
    foreach ($m in [regex]::Matches($t, "(?i)(?<![\w.\-/])$orgRx/([\w.-]+)#(\d+)\b")) {
        $hits += [pscustomobject]@{ At = $m.Index; Repo = $m.Groups[1].Value; Num = $m.Groups[2].Value }
    }
    # Not after a slash, so another org's org/repo#123 is not taken for ours.
    foreach ($m in [regex]::Matches($t, '(?<![\w.\-/])([\w.-]+)#(\d+)\b')) {
        $hits += [pscustomobject]@{ At = $m.Index; Repo = $m.Groups[1].Value; Num = $m.Groups[2].Value }
    }
    # Not after & (an HTML entity such as &#39;) or a word (repo#123, above).
    foreach ($m in [regex]::Matches($t, '(?<![\w.\-/&#])#(\d+)\b')) {
        $hits += [pscustomobject]@{ At = $m.Index; Repo = $Repo; Num = $m.Groups[1].Value }
    }
    $self = "$Repo#$Number"
    $found = [ordered]@{}
    foreach ($h in @($hits | Sort-Object At)) {
        $name = $canon[$h.Repo.ToLowerInvariant()]
        if (-not $name) { continue }
        $key = "$name#$([int]$h.Num)"
        if ($key -ne $self -and -not $found.Contains($key)) { $found[$key] = $true }
    }
    return @($found.Keys)
}

# Hold each ready PR that names an open PR this run will not merge, until no
# hold causes another: a PR held for one it names can in turn hold a PR that
# names it. $Queue is this run's PRs, already judged (Ready, Why); $Open is
# every open PR in the fleet, so a named PR that -Repo, -Only or -Exclude left
# out is still known to be open. Sets Names on every PR in $Queue - the open
# PRs it names - and on each one held: Ready false, a Why naming the PR it
# waits for and that PR's reason, and HeldFor.
function Add-PairHold {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Queue,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Open,
        [string[]]$Repos = @()
    )
    $isOpen = @{}
    foreach ($o in $Open) { if ($o) { $isOpen["$($o.Repo)#$($o.Number)"] = $true } }
    $inRun = @{}
    foreach ($p in $Queue) { $inRun["$($p.Repo)#$($p.Number)"] = $p }
    foreach ($p in $Queue) {
        $names = @(Get-NamedPr -Text "$($p.Title)`n$($p.Body)" -Repo $p.Repo -Number $p.Number -Repos $Repos |
            Where-Object { $_ -and $isOpen.ContainsKey($_) })
        $p | Add-Member -NotePropertyName Names -NotePropertyValue $names -Force
        $p | Add-Member -NotePropertyName HeldFor -NotePropertyValue $null -Force
    }
    do {
        $changed = $false
        foreach ($p in $Queue) {
            if (-not $p.Ready) { continue }
            foreach ($n in $p.Names) {
                $q = $inRun[$n]
                if ($q -and $q.Ready) { continue }
                $why = if (-not $q) { 'this run leaves it out (-Repo, -Only or -Exclude)' }
                       elseif ($q.HeldFor) { "it waits for $($q.HeldFor)" }
                       else { $q.Why }
                $p.Ready = $false
                $p.Why = "waits for $n, which it names: $why"
                $p.HeldFor = $n
                $changed = $true
                break
            }
        }
    } while ($changed)
}

# The ready PRs in merge order: each one after the PRs it names, otherwise in
# the order given. Two that name each other cannot both go after the other, so
# they wait until nothing else is free, then go in the order given; the merge
# step checks the second before the first lands (Get-PairBlock).
function Get-PairMergeOrder {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Prs)
    $inSet = @{}
    foreach ($p in $Prs) { $inSet["$($p.Repo)#$($p.Number)"] = $true }
    $placed = @{}
    $left = New-Object System.Collections.Generic.List[object]
    foreach ($p in $Prs) { $left.Add($p) }
    $order = @()
    while ($left.Count -gt 0) {
        $next = $null
        foreach ($p in $left) {
            $waiting = @(@($p.Names) | Where-Object { $_ -and $inSet.ContainsKey($_) -and -not $placed.ContainsKey($_) })
            if ($waiting.Count -eq 0) { $next = $p; break }
        }
        # Only PRs that name each other leave none free: take the first.
        if (-not $next) { $next = $left[0] }
        $order += $next
        $placed["$($next.Repo)#$($next.Number)"] = $true
        [void]$left.Remove($next)
    }
    return $order
}

# At the moment a PR is reached in the merge step: $null to go ahead, or why
# it must wait. Each PR it names has landed this run (go on), missed (so must
# this one), or - when the two name each other - not been tried yet; that one
# is checked now, so neither lands alone. One found already merged counts as
# landed. $Check is asked about a PR as (repo, number) and answers as
# Get-Readiness does.
function Get-PairBlock {
    param(
        [Parameter(Mandatory)]$Pr,
        [hashtable]$Landed = @{},
        [hashtable]$Missed = @{},
        [Parameter(Mandatory)][scriptblock]$Check
    )
    foreach ($n in @($Pr.Names)) {
        if (-not $n -or $Landed.ContainsKey($n)) { continue }
        if ($Missed.ContainsKey($n)) { return "waits for $n, which it names and which did not merge" }
        $i = $n.LastIndexOf('#')
        $v = & $Check $n.Substring(0, $i) ([int]$n.Substring($i + 1))
        if ($v.Ready -or $v.Why -eq 'state is MERGED') { continue }
        return "waits for $n, which it names and which is no longer ready: $($v.Why)"
    }
    return $null
}



$ORG = "evomedia-net"
# Discovered, never listed. The list this replaced had fallen fourteen
# repositories behind: a scan covered sixteen of thirty and said "Nothing open
# to merge" while a ready PR sat in one of the fourteen it could not see.
Write-Host ""
Write-Host "Reading every open pull request in $ORG..." -ForegroundColor Cyan
try { Assert-GhSignedIn } catch {
    Write-Host ""
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Nothing was read or merged." -ForegroundColor DarkGray
    Write-ZTrailer
    exit 1
}
$FLEET = Get-FleetOpenPrs -Org $ORG
$REPOS = $FLEET.Repos

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

# One answer from GitHub, judged. The same rules whether the answer came from
# the fleet query or a fresh `gh pr view`. $null means GitHub has not decided
# yet (UNKNOWN): the caller asks again rather than calling it either way.
function Get-PrVerdict {
    param($State, $Draft, $Mergeable, $MergeState)
    if ($State -ne "OPEN") { return [pscustomobject]@{ Ready = $false; Why = "state is $State" } }
    if ($Draft)            { return [pscustomobject]@{ Ready = $false; Why = "draft" } }
    # No merge status at all - a batch GitHub did not answer for - is no
    # answer either (#238).
    if (-not $Mergeable -or -not $MergeState) { return $null }
    if ($Mergeable -eq "MERGEABLE" -and $MergeState -eq "CLEAN") {
        return [pscustomobject]@{ Ready = $true; Why = "MERGEABLE/CLEAN" }
    }
    if ($Mergeable -eq "CONFLICTING") {
        return [pscustomobject]@{ Ready = $false; Why = "CONFLICTING - rebase it" }
    }
    # A non-CLEAN state such as BLOCKED/BEHIND is an answer; UNKNOWN is not.
    if ($Mergeable -ne "UNKNOWN" -and $MergeState -ne "UNKNOWN") {
        return [pscustomobject]@{ Ready = $false; Why = "$Mergeable/$MergeState" }
    }
    return $null
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
        $v = Get-PrVerdict -State $j.state -Draft $j.isDraft -Mergeable $j.mergeable -MergeState $j.mergeStateStatus
        if ($v) { return $v }
        # UNKNOWN: give GitHub a moment, since it computes mergeability
        # asynchronously.
        Start-Sleep -Seconds $PollDelaySeconds
    }
    return [pscustomobject]@{ Ready = $false; Why = "still UNKNOWN after $PollTries tries" }
}

if ($Repo -and ($REPOS -notcontains $Repo)) {
    # The per-repository call this replaced answered a misspelt name with an
    # empty list, which read as "nothing open there".
    Write-Host "No non-archived repository named '$Repo' in $ORG." -ForegroundColor Red
    Write-ZTrailer
    exit 1
}
$targets = if ($Repo) { @($Repo) } else { $REPOS }
Write-Host "$(@($FLEET.Prs).Count) open PR(s) across $($REPOS.Count) repo(s)." -ForegroundColor Cyan

$queue = @()
foreach ($pr in $FLEET.Prs) {
    if ($targets -notcontains $pr.Repo) { continue }
    if ($Exclude -contains $pr.Number) { continue }
    if ($Only.Count -gt 0 -and $Only -notcontains $pr.Number) { continue }
    $queue += $pr
}

if ($queue.Count -eq 0) { Write-Host "Nothing open to merge." -ForegroundColor Yellow; Complete-Run 0 }

# Only for the PRs this run can merge, so -Repo and -Only ask about fewer.
$asked = @($queue | Where-Object { -not $_.Draft }).Count
if ($asked -gt 0) {
    Write-Host "Reading merge status for $asked PR(s), 10 to a request..." -ForegroundColor Cyan
    Add-FleetMergeStates -Prs $queue
}

Write-Host ""
foreach ($p in $queue) {
    # The batches already carried the answer; only a PR GitHub was still
    # computing (UNKNOWN), or did not answer for, costs a call of its own,
    # polled until it settles.
    $v = Get-PrVerdict -State $p.State -Draft $p.Draft -Mergeable $p.Mergeable -MergeState $p.MergeState
    if (-not $v) { $v = Get-Readiness -RepoName $p.Repo -Number $p.Number }
    $p | Add-Member -NotePropertyName Ready -NotePropertyValue $v.Ready -Force
    $p | Add-Member -NotePropertyName Why   -NotePropertyValue $v.Why   -Force
}
# Every verdict first, then the holds: a PR waits for the open PRs it names,
# and whether those are ready is only known once all are judged.
Add-PairHold -Queue $queue -Open $FLEET.Prs -Repos $REPOS
foreach ($p in $queue) {
    $mark = if ($p.Ready) { "OK  " } else { "SKIP" }
    $col  = if ($p.Ready) { "Green" } else { "Yellow" }
    Write-Host ("  {0} {1,-14} #{2,-4} {3}" -f $mark, $p.Repo, $p.Number, $p.Title) -ForegroundColor $col
    if (-not $p.Ready) {
        Write-Host ("       -> {0}" -f $p.Why) -ForegroundColor DarkYellow
    } elseif (@($p.Names).Count -gt 0) {
        Write-Host ("       -> merges with {0}, which it names" -f (@($p.Names) -join ', ')) -ForegroundColor DarkGray
    }
}

$ready = @(Get-PairMergeOrder -Prs @($queue | Where-Object { $_.Ready }))
Write-Host ""
Write-Host "$($ready.Count) of $($queue.Count) ready to merge." -ForegroundColor Cyan

if (-not $Execute) {
    Write-Host ""
    Write-Host "Dry run. Re-run with -Execute (or -e) to merge." -ForegroundColor Yellow
    Write-ZTrailer
    exit 0
}
if ($ready.Count -eq 0) { Complete-Run 1 }

if (-not $Yes) {
    Write-Host ""
    $answer = Read-Host "Squash-merge these $($ready.Count) PRs and delete their branches? (y/N)"
    if ($answer -notmatch '^(y|yes)$') { Write-Host "Aborted - nothing merged." -ForegroundColor Yellow; Complete-Run 1 }
}

$merged = @(); $failed = @()
# "repo#number" of each PR that landed this run, or was found already merged,
# and of each that did not: what Get-PairBlock judges the PRs naming them by.
$landed = @{}; $missed = @{}
foreach ($p in $ready) {
    $key = "$($p.Repo)#$($p.Number)"
    # The PRs it names first: a pair lands together or not at all.
    $why = Get-PairBlock -Pr $p -Landed $landed -Missed $missed -Check { param($r, $n) Get-Readiness -RepoName $r -Number $n }
    if (-not $why) {
        # Re-check: an earlier merge in this same repo may have conflicted this one.
        $v = Get-Readiness -RepoName $p.Repo -Number $p.Number
        if (-not $v.Ready) { $why = $v.Why }
        if ($v.Why -eq 'state is MERGED') { $landed[$key] = $true }
    }
    if ($why) {
        Write-Host ("  SKIP {0} #{1} - {2}" -f $p.Repo, $p.Number, $why) -ForegroundColor Yellow
        $failed += [pscustomobject]@{ Repo = $p.Repo; Number = $p.Number; Why = $why }
        if (-not $landed.ContainsKey($key)) { $missed[$key] = $true }
        continue
    }
    $r = Invoke-Gh @("pr", "merge", "$($p.Number)", "-R", "$ORG/$($p.Repo)",
        "--squash", "--delete-branch") -AllowFail
    if ($r.Code -eq 0) {
        Write-Host ("  MERGED {0} #{1}" -f $p.Repo, $p.Number) -ForegroundColor Green
        $merged += $p
        $landed[$key] = $true
    } else {
        Write-Host ("  FAILED {0} #{1}" -f $p.Repo, $p.Number) -ForegroundColor Red
        Write-Host ("         {0}" -f $r.Output) -ForegroundColor DarkRed
        $failed += [pscustomobject]@{ Repo = $p.Repo; Number = $p.Number; Why = $r.Output }
        $missed[$key] = $true
    }
}

Write-Host ""
Write-Host "merged $($merged.Count), failed/skipped $($failed.Count)" -ForegroundColor Cyan

# Two PRs that name each other were both checked before the first one landed,
# so the second missing takes a change in the seconds between two merges, or
# a merge that failed outright. Rare, and it is exactly the split this guards
# against, so it is said in red rather than left in the skip list.
foreach ($p in $merged) {
    foreach ($n in @(@($p.Names) | Where-Object { $_ -and $missed.ContainsKey($_) })) {
        Write-Host ("  {0}#{1} merged, but {2}, which it names, did not. Merge {2} by hand so the two land together." -f $p.Repo, $p.Number, $n) -ForegroundColor Red
    }
}

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

if ($failed.Count -gt 0) { Complete-Run 1 }

Complete-Run 0
