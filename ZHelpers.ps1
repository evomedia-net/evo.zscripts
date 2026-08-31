# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.23

# ZHelpers.ps1 — shared library dot-sourced by every z script. Not run directly.

# File extensions to skip recursively when building any deploy/backup zip.
$script:ArchiveExtensions = @(
    '.zip', '.dmg', '.arj', '.gz', '.tgz', '.tar', '.rar', '.7z', '.iso',
    '.bz2', '.xz', '.lz', '.lzma', '.cab', '.jar', '.war', '.ear', '.z',
    '.zst', '.zstd'
)
# Directories whose archives are BUILD INPUTS, not incidental bloat, and so are
# exempt from ArchiveExtensions. A project that vendors a dependency as
# vendor/*.tgz (common when a bundler cannot resolve `file:` links outside the
# project root) needs that tarball in the deploy zip - dropping it makes a
# Dockerfile's `COPY vendor ./vendor` fail at image build, which is a
# confusing way to discover the archive filter ate a required build input.
$script:ArchiveKeepDirNames = @('vendor')
$script:ScriptExtensions = @('.ps1', '.cmd', '.bat')
$script:JunkExtensions = @(
    '.swp', '.swo', '.swn', '.tmp', '.orig', '.rej', '.bak',
    '.backup', '.old',
    '.pyc', '.pyo', '.pyd',
    '.tsbuildinfo',
    '.log',
    '.db', '.sqlite', '.sqlite3'
)
$script:JunkFileNames = @('.DS_Store', 'Thumbs.db', 'desktop.ini')
$script:JunkDirNames = @(
    '.git', '.svn', '.hg',
    '__pycache__', '.pytest_cache', '.mypy_cache', '.ruff_cache', '.tox',
    'node_modules', '.npm', '.yarn', '.pnpm-store',
    '.next', '.nuxt', '.svelte-kit', '.turbo', '.parcel-cache', '.cache',
    '.idea', '.vscode',
    'coverage', 'htmlcov', '.nyc_output'
)

# ── Config loading ───────────────────────────────────────────────────────────

$script:ZConfigCache = $null

# Where zconfig.json lives. Defaults to next to the scripts; override with the
# ZCONFIG environment variable, matching the bash port (zhelpers.sh does the
# same). Useful for pointing a run at an alternate config, and it is the seam
# the test suite uses to inject a fixture.
function Get-ZConfigPath {
    if ($env:ZCONFIG) { return $env:ZCONFIG }
    return (Join-Path $PSScriptRoot "zconfig.json")
}

# Drop the memoised config so the next Get-ZConfig re-reads from disk. Only
# needed when the config changes mid-process (tests switching fixtures).
function Reset-ZConfigCache {
    $script:ZConfigCache = $null
}

function Get-ZConfig {
    if ($null -ne $script:ZConfigCache) { return $script:ZConfigCache }
    $configPath = Get-ZConfigPath
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Host "ERROR: zconfig.json not found at $configPath" -ForegroundColor Red
        Write-Host "       Copy zconfig.example.json to zconfig.json and fill in your values." -ForegroundColor DarkGray
        Stop-ZTracking; exit 1
    }
    try {
        $script:ZConfigCache = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host "ERROR: Failed to parse zconfig.json - $($_.Exception.Message)" -ForegroundColor Red
        Stop-ZTracking; exit 1
    }
    return $script:ZConfigCache
}

# All project keys, in config order. Keys starting with "_" are comments, not projects.
function Get-ZProjectKeys {
    $cfg = Get-ZConfig
    return @($cfg.projects.PSObject.Properties.Name | Where-Object { $_ -notmatch '^_' })
}

function Get-ZProject {
    param([Parameter(Mandatory)][string]$Key)
    $cfg = Get-ZConfig
    # Tolerate switch-style keys (zdeploy -myproject) from muscle memory.
    $Key = $Key.TrimStart('-')
    $proj = if ($Key -notmatch '^_') { $cfg.projects.$Key } else { $null }
    if (-not $proj) {
        $available = (Get-ZProjectKeys) -join ', '
        Write-Host "ERROR: Unknown project key '$Key'. Available: $available" -ForegroundColor Red
        Stop-ZTracking; exit 1
    }
    return $proj
}

# The first project of kind 'edge', or $null. Returns @{ Key; Config }.
function Get-ZEdgeProject {
    $cfg = Get-ZConfig
    foreach ($k in (Get-ZProjectKeys)) {
        if ($cfg.projects.$k.kind -eq 'edge') {
            return [pscustomobject]@{ Key = $k; Config = $cfg.projects.$k }
        }
    }
    return $null
}

# Remote compose directory for a project: remote.composeDir if set, else remote.path.
function Get-RemoteComposeDir {
    param([Parameter(Mandatory)][string]$Key)
    $proj = Get-ZProject -Key $Key
    if ($proj.remote.composeDir) { return $proj.remote.composeDir }
    return $proj.remote.path
}

# ── SSH helpers ──────────────────────────────────────────────────────────────

function Get-Ec2Target {
    $c = (Get-ZConfig).ec2
    return "$($c.user)@$($c.ip)"
}

function Get-Ec2Home {
    return "/home/$((Get-ZConfig).ec2.user)"
}

# Options every deploy-path ssh/scp carries. Splat with @sshOpts, matching the
# idiom in zsetup_mail.ps1 and zec2_rotatekeys.ps1.
#
# BatchMode=yes is the one that matters. Without it ssh PROMPTS - for a
# passphrase, a password, a sudo password - and waits forever. The deploy pipes
# stderr into the pipeline (2>&1 | ForEach-Object) so the prompt is swallowed
# on its way to the screen: the run simply stops under whatever step label was
# printed last, with nothing to explain it and no obvious reason why that
# particular step would be slow. `zdeploy umami` appeared to hang on "ensure
# shared web network", a step whose entire body is `docker network create web
# 2>/dev/null || true` against a network that already existed.
#
# There is no prompt here we would ever want to answer - the deploy key is
# unencrypted and sudo on the box is passwordless - so failing immediately is
# strictly better than waiting on input that is never coming.
#
# ConnectTimeout bounds the TCP connect. ServerAlive* bound everything after
# it, so a session that dies mid-command (dropped VPN, laptop asleep, host
# rebooting) errors out in about a minute instead of hanging indefinitely.
# zec2online.ps1 and zsetup_mail.ps1 already set ConnectTimeout; the deploy
# path, the one place a hang costs the most, set none of them.
#
# -n is the one that fixes the hang these options did NOT catch. Without it ssh
# reads its stdin and forwards it to the remote command, and under PowerShell it
# inherits the console handle - so it can block forever waiting on input nobody
# is going to type. The timeouts above cannot help: they bound a connection that
# is dying, and this one was never established. A deploy on 2026-08-19 stopped
# under "ensure unzip installed", a step whose body short-circuits on an already
# installed unzip; the server showed no ssh session at all (`who` empty, no
# docker build running), which is what a client-side stdin block looks like from
# the other end. The zip had uploaded and prod stayed a PR behind.
#
# Safe here because nothing that pipes stdin INTO ssh uses these options:
# zdeploy passes only command strings, and the scripts that do pipe
# (one-off registration and key-rotation scripts) build their own
# option arrays. Adding -n to those would break them - do not hoist it.
function Get-Ec2SshOpts {
    return @(
        '-n',
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'BatchMode=yes',
        '-o', 'ConnectTimeout=15',
        '-o', 'ServerAliveInterval=15',
        '-o', 'ServerAliveCountMax=4'
    )
}

# The same options for scp, which does NOT accept -n: OpenSSH's scp exits 1 with
# "unknown option -- n" and prints its usage block. That failure is easy to
# misread, because the caller's own error text is what the operator sees and the
# usage text scrolls past above it - a deploy on 2026-08-19 reported "Likely
# server disk space" while the box sat at 79% with 8.1 GB free.
#
# Derived from Get-Ec2SshOpts rather than duplicated, so the timeouts can never
# drift apart between the two transports.
function Get-Ec2ScpOpts {
    return @(Get-Ec2SshOpts | Where-Object { $_ -ne '-n' })
}

# Run one bash command on the server; throw on non-zero exit.
function Invoke-Ec2Step {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Bash,
        [string]$FailHint = ""
    )
    $cfg = Get-ZConfig
    Write-Host "  >> $Label" -ForegroundColor DarkCyan
    # ssh can emit warnings on stderr (e.g. Docker's "COMPOSE_BAKE is
    # deprecated" notice during a compose build). The deploy runs under
    # ErrorActionPreference='Stop', and PowerShell 5.1 turns any native stderr
    # line into a terminating NativeCommandError — aborting the deploy before we
    # ever read the real exit code, even though the remote step succeeded. Drop
    # to Continue locally (function-scoped, auto-reverts) and flatten stderr
    # into normal output, so only the actual exit status decides success.
    $ErrorActionPreference = 'Continue'
    $sshOpts = Get-Ec2SshOpts
    ssh @sshOpts -i $cfg.ec2.pemKey (Get-Ec2Target) $Bash 2>&1 |
        ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        $msg = "Remote step failed: '$Label' (exit $LASTEXITCODE)."
        if ($FailHint) { $msg += " $FailHint" }
        throw $msg
    }
}

# ── Deploy git pull ──────────────────────────────────────────────────────────

# Put the project's checkout ON the default branch and fast-forward it before
# a deploy, when deploy.gitPull is set. zdeploy zips the working tree and does
# NOT otherwise pull, so after a merged PR the checkout can sit behind origin
# and the deploy would ship stale code while still bumping the build number
# (looks successful, changes nothing).
#
# Deploys ship the default branch, so this SWITCHES to it rather than pulling
# whatever branch happens to be checked out. The old behaviour pulled the
# current branch, which broke the day delete_branch_on_merge went on
# fleet-wide (2026-08-07): a repo still sitting on its just-merged PR branch
# pulls a ref the merge deleted, and the deploy dies on "no such ref was
# fetched". Worse, when the ref DID still exist, pulling the feature branch
# meant a deploy could ship a branch, not main.
#
# The switch refuses to run over local changes: a dirty tree aborts the deploy
# with the file list rather than risk tangling uncommitted work. The stale
# branch is left in place for the operator to delete - under squash merges
# only a content diff can prove it safe, and a deploy is not the place to
# make that call.
#
# Runs git bare (no 2>&1) and checks $LASTEXITCODE, matching Invoke-Ec2Step
# under $ErrorActionPreference='Stop'.
function Invoke-DeployGitPull {
    param([Parameter(Mandatory)]$Proj)
    if (-not ($Proj.deploy -and $Proj.deploy.gitPull)) { return }
    $root = $Proj.localRoot
    if (-not (Test-Path -LiteralPath (Join-Path $root ".git"))) {
        Write-Host "  gitPull set but '$root' is not a git repo - skipping pull." -ForegroundColor Yellow
        return
    }
    Write-Host "`n--- [0] git sync default branch ---" -ForegroundColor Cyan
    Push-Location -LiteralPath $root
    try {
        # Same PS 5.1 trap Invoke-Ec2Step documents: under the deploy's
        # ErrorActionPreference='Stop', a stderr REDIRECT on a native command
        # (the 2>$null on symbolic-ref below) wraps stderr lines in
        # terminating ErrorRecords. Success is judged by $LASTEXITCODE
        # throughout, so drop to Continue (function-scoped, auto-reverts).
        $ErrorActionPreference = 'Continue'
        git fetch origin --prune
        if ($LASTEXITCODE -ne 0) {
            throw "git fetch failed in '$root'. Check the remote, then re-run - refusing to deploy possibly-stale code."
        }

        # Ask the remote which branch is the default rather than assuming
        # "main" - older repos or mirrors may differ.
        $default = (git symbolic-ref --short refs/remotes/origin/HEAD 2>$null) -replace '^origin/', ''
        if (-not $default) {
            git remote set-head origin --auto | Out-Null
            $default = (git symbolic-ref --short refs/remotes/origin/HEAD 2>$null) -replace '^origin/', ''
        }
        if (-not $default) { $default = 'main' }

        $branch = (git rev-parse --abbrev-ref HEAD)
        if ($branch -ne $default) {
            # Tracked modifications only. Untracked files cannot be tangled
            # by a branch switch, and zdeploy has always shipped them (the
            # zip takes the working tree) - blocking on them would abort
            # every deploy over stray local files.
            $dirty = git status --porcelain --untracked-files=no
            # Files the DEPLOY itself writes are excluded. zdeploy stamps the
            # bumped build version (and appends the changelog) into the working
            # tree after every successful run, so leaving them in scope made
            # each deploy block the next one - the operator had to commit or
            # stash a change they never made. The guard exists to stop
            # unreviewed SOURCE shipping; a stamp the script just wrote is not
            # that. It is still committed separately, one bump per release,
            # per the versioning rule - this only stops it being a gate.
            $deployWritten = @('build-version.json', 'CHANGELOG.md')
            $dirty = $dirty | Where-Object {
                $path = ($_ -replace '^..\s+', '') -replace '^.*/', ''
                $deployWritten -notcontains $path
            }
            if ($dirty) {
                $files = ($dirty | ForEach-Object { "    $_" }) -join "`n"
                throw "Checkout is on '$branch' with local changes:`n$files`n  Deploys ship '$default'. Commit or stash, then re-run."
            }
            Write-Host "  On '$branch'; deploys ship '$default' - switching." -ForegroundColor Yellow
            git checkout $default
            if ($LASTEXITCODE -ne 0) {
                throw "git checkout $default failed in '$root'. Resolve it, then re-run."
            }
            Write-Host "  Stale branch '$branch' left in place - delete it once you've confirmed it merged." -ForegroundColor DarkGray
        }

        # Fast-forward against the remote-tracking ref, not `git pull`. The
        # fetch at the top of this function already brought origin up to date,
        # so pull's own fetch was redundant - and it was also the failure
        # point: pull merges whatever FETCH_HEAD marks "for merge", and a
        # concurrent fetch in the same repo (an editor's background auto-fetch
        # racing the deploy) can leave duplicate for-merge lines, killing the
        # run with "Cannot fast-forward to multiple branches" even when both
        # lines name the same commit. origin/$default has no such ambiguity.
        git merge --ff-only "origin/$default"
        if ($LASTEXITCODE -ne 0) {
            throw "git merge --ff-only origin/$default failed in '$root'. Resolve it (commit / stash / reconcile), then re-run - refusing to deploy possibly-stale code."
        }
        Write-Host "  Now at: $(git log -1 --oneline)" -ForegroundColor DarkGray
    }
    finally {
        Pop-Location
    }
}

# ── Build-version helpers ────────────────────────────────────────────────────

function Read-JsonBuildVersion {
    param([string]$FilePath)
    if (-not (Test-Path -LiteralPath $FilePath)) { return $null }
    try { return Get-Content -LiteralPath $FilePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return $null }
}

function Get-ServerSideVersionCommand {
    <#
    .SYNOPSIS
        Shell command that reads a project's live build ON the server, or
        $null when the project has not configured one.

    .DESCRIPTION
        Four tools read a live build number, and all four did it by asking
        the public edge: zdeploy's post-deploy check, zec2, zec2online, and
        bash/zhelpers.sh. That works only for as long as the endpoint is
        public, and it should not be: www's /build-version.json has been
        blocked at the edge since the 2026-05-29 security pass, and evo.ehs
        answering /api/build-version to anyone is the inconsistency this
        closes.

        Going through the edge is also how a check reads the WRONG product.
        The proxy answers from whichever vhost matches the Host header, so a
        service with no public route gets somebody else's version back --
        evo-ai's deploy check compared evo.ehs's build against its own and
        reported a failure on a deploy that had worked (evo.scripts#101).

        A project reached only on the shared docker network cannot be curled
        from the host: evoehs_app publishes no port. It IS reachable by name
        from another container on that network, which also exercises the real
        HTTP path -- so this proves the app is serving, not merely that its
        database knows a version.

        Config, on the project's `verify` block:

            "verify": {
              "path":     "/api/build-version",
              "viaProxy": "evo_edge_proxy",
              "upstream": "evoehs_app:80"
            }

        Returns $null when either key is missing, so every project without
        this config keeps exactly the behaviour it has today.
    #>
    param($Proj)

    $v = $Proj.verify
    if (-not $v) { return $null }
    if (-not $v.viaProxy -or -not $v.upstream) { return $null }
    $path = if ($v.path) { [string]$v.path } else { '/api/build-version' }
    return "sudo docker exec $([string]$v.viaProxy) curl -s -m 8 http://$([string]$v.upstream)$path"
}

function Get-LabelFromVersionJson {
    <#
    .SYNOPSIS
        The build label out of a version endpoint's JSON text, or $null.

    .DESCRIPTION
        Two field names in the fleet: evo.ehs answers `build_version` on
        /api/build-version, evo-ai answers `version` on /health. Both mean
        "the build that is live", so both are accepted rather than making an
        app rename its own field.
    #>
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return $null }
    try { $obj = $Text.Trim() | ConvertFrom-Json -ErrorAction Stop } catch { return $null }
    if ($obj.build_version) { return [string]$obj.build_version }
    if ($obj.version) { return [string]$obj.version }
    return $null
}

function Get-LabelFromBuildJsonObj {
    param($obj)
    if (-not $obj) { return $null }
    # Five-segment scheme: v{major}.{rc}.{beta}.{alpha}.{build}
    if ($null -ne $obj.build -or $null -ne $obj.alpha) {
        $alpha = if ($null -ne $obj.alpha) { [int]$obj.alpha } else { 1 }
        return "v$([int]$obj.major).$([int]$obj.rc).$([int]$obj.beta).$alpha.$([int]$obj.build)"
    }
    # Legacy two-part stamp (projects not yet migrated): v{productVersion}.{buildNumber}
    return "v$([string]$obj.productVersion).$([int]$obj.buildNumber)"
}

# ── Deploy/backup exclude lists ──────────────────────────────────────────────

# Top-level excludes for a project archive: common junk + kind-specific dirs +
# anything the user lists in the project's deploy.exclude array.
function Get-ArchiveExcludes {
    param(
        [Parameter(Mandatory)]$Project,
        [switch]$ForBackup
    )
    $common = @(".git", ".idea", ".vscode", ".claude", "tmp", "nul", ".DS_Store", "backups")
    $byKind = switch ([string]$Project.kind) {
        "python" {
            $list = @(".venv", "venv", "__pycache__", ".pytest_cache", ".nicegui", "archive", "dist", "build", "htmlcov")
            # Deploys exclude user uploads + local .env secrets (server keeps its
            # own, preserved across deploys); backups keep both for completeness.
            if (-not $ForBackup) { $list += @("uploads", ".env", ".env.local", ".env.production") }
            $list
        }
        "vite"   {
            $list = @("node_modules", "dist")
            if (-not $ForBackup) { $list += @(".env", ".env.local", ".env.production") }
            $list
        }
        "nextjs" { @("node_modules", ".next", ".env", ".env.local", ".env.production", ".vercel", "coverage", "out", "build", "next-env.d.ts") }
        default  { @() }
    }
    $extra = @()
    if ($Project.deploy -and $Project.deploy.exclude) { $extra = @($Project.deploy.exclude) }
    return @($common + $byKind + $extra | Select-Object -Unique)
}

# ── Archive builder ──────────────────────────────────────────────────────────

# True when a file sits inside a directory named in $ArchiveKeepDirNames, i.e.
# its archive extension is a build input and must survive the archive filter.
function Test-InArchiveKeepDir {
    param([Parameter(Mandatory)][System.IO.FileInfo] $File)
    $dir = $File.DirectoryName
    if (-not $dir) { return $false }
    foreach ($segment in ($dir -split '[\\/]')) {
        if ($script:ArchiveKeepDirNames -contains $segment) { return $true }
    }
    return $false
}

# Build a zip from a source directory (deploy/backup).
# - $TopLevelExclude: skip these entries at the source root
# - Archive/script/junk filters and $JunkDirNames pruning apply recursively
# - $IncludeScriptFiles: keep .ps1/.cmd/.bat (needed when backing up this repo itself)
function New-ProjectArchive {
    param(
        [Parameter(Mandatory)] [string] $SourcePath,
        [Parameter(Mandatory)] [string] $DestinationZip,
        [string[]] $TopLevelExclude = @(),
        [string[]] $ExtraFiles = @(),
        [switch] $IncludeScriptFiles
    )

    $sourceItem = Get-Item -LiteralPath $SourcePath -Force -ErrorAction Stop
    if (-not $sourceItem.PSIsContainer) {
        throw "Source path is not a directory: $($sourceItem.FullName)"
    }
    $sourceFull = $sourceItem.FullName.TrimEnd('\')

    if (Test-Path -LiteralPath $DestinationZip) { Remove-Item -LiteralPath $DestinationZip -Force }
    $destDir = Split-Path -Parent $DestinationZip
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) {
        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
    }

    Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

    $topEntries = Get-ChildItem -LiteralPath $sourceItem.FullName -Force | Where-Object { $_.Name -notin $TopLevelExclude }
    if ($topEntries.Count -eq 0 -and $ExtraFiles.Count -eq 0) {
        throw "Nothing to archive in $sourceFull (after top-level excludes)."
    }

    $junkDirSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $script:JunkDirNames) { [void]$junkDirSet.Add($n) }
    $junkNameSet = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($n in $script:JunkFileNames) { [void]$junkNameSet.Add($n) }

    $allFiles = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    $junkDirsPruned = 0
    $stack = New-Object System.Collections.Generic.Stack[string]

    foreach ($entry in $topEntries) {
        if ($entry.PSIsContainer) {
            if ($junkDirSet.Contains($entry.Name)) {
                $junkDirsPruned++
                continue
            }
            $stack.Push($entry.FullName)
            while ($stack.Count -gt 0) {
                $dir = $stack.Pop()
                $children = @(Get-ChildItem -LiteralPath $dir -Force -ErrorAction SilentlyContinue)
                foreach ($child in $children) {
                    if ($child.PSIsContainer) {
                        if ($junkDirSet.Contains($child.Name)) {
                            $junkDirsPruned++
                        } else {
                            $stack.Push($child.FullName)
                        }
                    } else {
                        [void]$allFiles.Add([System.IO.FileInfo]$child.FullName)
                    }
                }
            }
        } else {
            [void]$allFiles.Add([System.IO.FileInfo]$entry.FullName)
        }
    }

    foreach ($extra in $ExtraFiles) {
        if (Test-Path -LiteralPath $extra) {
            $extraItem = Get-Item -LiteralPath $extra -Force
            if (-not $extraItem.PSIsContainer) {
                [void]$allFiles.Add([System.IO.FileInfo]$extraItem.FullName)
            }
        }
    }

    $archivesSkipped = 0
    $scriptsSkipped = 0
    $junkExtSkipped = 0
    $junkNameSkipped = 0
    $kept = New-Object System.Collections.Generic.List[System.IO.FileInfo]
    foreach ($f in $allFiles) {
        $ext = $f.Extension
        if ($ext) { $ext = $ext.ToLowerInvariant() }
        if ($script:ArchiveExtensions -contains $ext -and -not (Test-InArchiveKeepDir $f)) {
            $archivesSkipped++; continue
        }
        if (-not $IncludeScriptFiles -and $script:ScriptExtensions -contains $ext) { $scriptsSkipped++; continue }
        if ($script:JunkExtensions -contains $ext) { $junkExtSkipped++; continue }
        if ($junkNameSet.Contains($f.Name)) { $junkNameSkipped++; continue }
        [void]$kept.Add($f)
    }
    # "Including:" reflects what actually lands in the zip — top-level names
    # derived from the kept files, not the pre-filter directory listing.
    $srcPrefix = $sourceFull + '\'
    $topSeen  = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $topNames = New-Object System.Collections.Generic.List[string]
    foreach ($f in $kept) {
        $topName = if ($f.FullName.StartsWith($srcPrefix, [System.StringComparison]::OrdinalIgnoreCase)) {
            ($f.FullName.Substring($srcPrefix.Length) -split '\\')[0]
        } else { $f.Name }
        if ($topSeen.Add($topName)) { [void]$topNames.Add($topName) }
    }
    if ($topNames.Count -gt 0) {
        Write-Host ("  Including: " + ($topNames -join ", ")) -ForegroundColor Gray
    }
    if ($archivesSkipped -gt 0) {
        Write-Host ("  Skipped {0} nested archive file(s)" -f $archivesSkipped) -ForegroundColor DarkGray
    }
    if ($scriptsSkipped -gt 0) {
        Write-Host ("  Skipped {0} local script file(s)" -f $scriptsSkipped) -ForegroundColor DarkGray
    }
    if ($junkExtSkipped -gt 0) {
        Write-Host ("  Skipped {0} junk file(s) by extension" -f $junkExtSkipped) -ForegroundColor DarkGray
    }
    if ($junkNameSkipped -gt 0) {
        Write-Host ("  Skipped {0} OS junk file(s)" -f $junkNameSkipped) -ForegroundColor DarkGray
    }
    if ($junkDirsPruned -gt 0) {
        Write-Host ("  Pruned {0} dev directory subtree(s)" -f $junkDirsPruned) -ForegroundColor DarkGray
    }
    if ($kept.Count -eq 0) {
        throw "Nothing to archive after filters."
    }

    $prefix = $sourceFull + '\'
    $zip = [System.IO.Compression.ZipFile]::Open($DestinationZip, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($f in $kept) {
            if ($f.FullName.StartsWith($prefix, [System.StringComparison]::OrdinalIgnoreCase)) {
                $rel = $f.FullName.Substring($prefix.Length).Replace('\', '/')
            } else {
                $rel = $f.Name
            }
            [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $zip, $f.FullName, $rel, [System.IO.Compression.CompressionLevel]::Optimal)
        }
    }
    finally {
        $zip.Dispose()
    }

    $info = Get-Item -LiteralPath $DestinationZip
    $sizeMb = [math]::Round($info.Length / 1MB, 1)
    Write-Host ("  Archive: $($info.FullName) ($sizeMb MB, $($kept.Count) files)") -ForegroundColor Gray
}

# ── Process killers ──────────────────────────────────────────────────────────

# Kill a process and all of its descendants (children first). Needed for
# reloading servers (uvicorn/watchfiles, nodemon): workers inherit the
# listening socket and would keep serving stale code if orphaned.
function Stop-ProcessTree {
    param([int]$TargetPid)
    $killed = 0
    $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$TargetPid" -ErrorAction SilentlyContinue)
    foreach ($child in $children) {
        $killed += Stop-ProcessTree -TargetPid $child.ProcessId
    }
    $proc = Get-Process -Id $TargetPid -ErrorAction SilentlyContinue
    if ($proc) {
        Write-Host "  Killing PID $TargetPid ($($proc.ProcessName))" -ForegroundColor Red
        Stop-Process -Id $TargetPid -Force -ErrorAction SilentlyContinue
        $killed++
    }
    return $killed
}

function Stop-ListenersOnPort {
    param([int]$Port)
    $killed = 0
    $listeners = netstat -ano | Select-String ":$Port\s+.*LISTENING"
    if ($listeners) {
        $seen = @{}
        foreach ($line in $listeners) {
            if ($line -match '\s(\d+)\s*$') {
                $targetPid = $Matches[1]
                if ($seen.ContainsKey($targetPid)) { continue }
                $seen[$targetPid] = $true
                $proc = Get-Process -Id $targetPid -ErrorAction SilentlyContinue
                if ($proc) {
                    Write-Host "  Killing PID $targetPid ($($proc.ProcessName)) on port $Port (and children)" -ForegroundColor Red
                    $killed += Stop-ProcessTree -TargetPid $targetPid
                }
            }
        }
    } else {
        Write-Host "  No LISTENING process on port $Port" -ForegroundColor DarkGray
    }
    return $killed
}

# Kill stray runtime processes (node, python, next-server) whose command line
# references the given project root. Safer than killing every node/python on the box.
function Stop-ProjectProcesses {
    param([Parameter(Mandatory)][string]$ProjectRoot)
    $killed = 0
    foreach ($name in @("node", "python", "next-server")) {
        $found = Get-Process -Name $name -ErrorAction SilentlyContinue
        foreach ($p in $found) {
            try {
                $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" -ErrorAction SilentlyContinue).CommandLine
                if ($cmd -and $cmd -like "*$ProjectRoot*") {
                    Write-Host "  Killing $name PID $($p.Id) (references $ProjectRoot)" -ForegroundColor Red
                    Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
                    $killed++
                }
            } catch {}
        }
    }
    return $killed
}

# ── MOTD (message of the day) ────────────────────────────────────────────────

# If the project root has a motd/ folder of .txt files, print one on start,
# rotating through them in shuffled order. {{build_version}} is substituted.
function Show-ProjectMotd {
    param(
        [Parameter(Mandatory)][string]$Root,
        [string]$BuildVersion = ""
    )
    $motdDir = Join-Path $Root "motd"
    if (-not (Test-Path -LiteralPath $motdDir -PathType Container)) { return }
    $motdFiles = @(Get-ChildItem -LiteralPath $motdDir -Filter "*.txt" -File -ErrorAction SilentlyContinue)
    if ($motdFiles.Count -eq 0) { return }

    $namesMatch = {
        param([string[]]$Order, [object[]]$Files)
        $a = @($Order | Sort-Object)
        $b = @($Files | ForEach-Object { $_.Name } | Sort-Object)
        return -not (Compare-Object -ReferenceObject $a -DifferenceObject $b)
    }
    $newShuffle = {
        param([object[]]$Files)
        return @($Files | Sort-Object { Get-Random } | ForEach-Object { $_.Name })
    }

    $statePath = Join-Path $motdDir ".motd_rotation.json"
    $order = @()
    $nextIdx = 0
    $loaded = $false
    if (Test-Path -LiteralPath $statePath) {
        try {
            $raw = Get-Content -LiteralPath $statePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $order = @($raw.order)
            $nextIdx = [int]$raw.next_index
            if ($order.Count -eq 0) { throw "empty order" }
            if (-not (& $namesMatch $order $motdFiles)) { throw "file set changed" }
            if ($nextIdx -lt 0 -or $nextIdx -ge $order.Count) { throw "bad index" }
            $loaded = $true
        }
        catch { $loaded = $false }
    }
    if (-not $loaded) {
        $order = & $newShuffle $motdFiles
        $nextIdx = 0
    }

    $pickName = $order[$nextIdx]
    $pick = $motdFiles | Where-Object { $_.Name -eq $pickName } | Select-Object -First 1
    if (-not $pick) {
        $order = & $newShuffle $motdFiles
        $nextIdx = 0
        $pickName = $order[$nextIdx]
        $pick = $motdFiles | Where-Object { $_.Name -eq $pickName } | Select-Object -First 1
    }

    $following = $nextIdx + 1
    if ($following -ge $order.Count) {
        $followingOrder = & $newShuffle $motdFiles
        $followingIdx = 0
    } else {
        $followingOrder = $order
        $followingIdx = $following
    }

    if ($pick) {
        try {
            $motd = Get-Content -LiteralPath $pick.FullName -Raw -Encoding UTF8
            if (-not [string]::IsNullOrWhiteSpace($BuildVersion)) {
                $motd = $motd -replace "\{\{build_version\}\}", $BuildVersion
            }
            if (-not [string]::IsNullOrWhiteSpace($motd)) {
                Write-Host ""
                Write-Host $motd
                Write-Host ""
            }
            @{
                order      = @($followingOrder)
                next_index = $followingIdx
            } | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
        }
        catch { }
    }
}

# ── Output tracking ───────────────────────────────────────────────────────────
$global:_ZTrackPath = $null
# Set by token-count.ps1's Invoke-Measured while a script is being timed.
# Start-ZTracking checks this so inner scripts don't replace the outer transcript.
if ($null -eq $global:_ZMeasuring) { $global:_ZMeasuring = $false }

function Start-ZTracking {
    if ($global:_ZMeasuring) { return }
    # Remember who is being tracked so Stop-ZTracking can log the run (ztokens).
    try { $global:_ZTrackScript = [System.IO.Path]::GetFileNameWithoutExtension((Get-PSCallStack)[1].ScriptName) } catch { $global:_ZTrackScript = "" }
    try {
        $bp = (Get-PSCallStack)[1].InvocationInfo.BoundParameters
        $global:_ZTrackProjects = (@($bp['Projects']) -join ',')
    } catch { $global:_ZTrackProjects = "" }
    $tp = Join-Path ([System.IO.Path]::GetTempPath()) ("_ztrack_" + [System.Guid]::NewGuid().ToString("N") + ".txt")
    $global:_ZTrackPath = $tp
    try { Start-Transcript -Path $tp -NoClobber | Out-Null } catch { $global:_ZTrackPath = $null }
}

# Append this run to the ztokens data store (passive usage stats). Uses
# $env:ZTOKENS_DATA, else the sibling ..\ztokens\data directory. Silently
# no-ops when neither exists, so setups without ztokens are unaffected.
function Add-ZTokensRecord {
    param([int]$Lines, [int]$Chars, [int]$Est)
    try {
        $dir = $env:ZTOKENS_DATA
        if (-not $dir) { $dir = Join-Path (Split-Path -Parent $PSScriptRoot) "ztokens\data" }
        if (-not (Test-Path -LiteralPath $dir)) { return }
        $model = $env:ZTOKENS_MODEL
        if (-not $model) { $model = "est. chars/3.5" }
        $rec = @{
            ts       = (Get-Date).ToString("o")
            script   = [string]$global:_ZTrackScript
            projects = [string]$global:_ZTrackProjects
            lines    = $Lines
            chars    = $Chars
            est      = $Est
            model    = $model
        }
        Add-Content -LiteralPath (Join-Path $dir "tokens.jsonl") -Value (ConvertTo-Json -InputObject $rec -Compress) -Encoding UTF8
    } catch { }
}

# Two blank lines below every z-script's output, so a run is visually separated
# from the next prompt instead of butting up against it. Emitted here because
# every script ends by calling Stop-ZTracking - including the usage and guard
# paths that `Stop-ZTracking; exit 1` - so one place covers every exit.
#
# -FinalNote prints one last line AFTER the tracking footer but BEFORE the blank
# lines, for a script that wants the bottom of the screen to say something more
# useful than a token count (zdeploy's "Last deployed at ...").
function Write-ZTrailer {
    param([string]$FinalNote)
    if ($FinalNote) {
        Write-Host ""
        Write-Host $FinalNote -ForegroundColor Cyan
    }
    Write-Host ""
    Write-Host ""
}

function Stop-ZTracking {
    param([string]$FinalNote)
    # The trailer is owed whether or not tracking ever started - a script that
    # printed output still deserves the separation.
    if (-not $global:_ZTrackPath) { Write-ZTrailer -FinalNote $FinalNote; return }
    try { Stop-Transcript | Out-Null } catch {}
    $tp = $global:_ZTrackPath
    $global:_ZTrackPath = $null
    if (-not (Test-Path -LiteralPath $tp)) { return }
    try {
        $raw   = Get-Content -LiteralPath $tp -Raw -Encoding UTF8
        $lines = @($raw -split "`n")
        $si = 0
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^Transcript started') { $si = $i + 1; break }
        }
        $ei = $lines.Count
        for ($i = $lines.Count - 1; $i -ge 0; $i--) {
            if ($lines[$i] -match '^\*{4}') { $ei = $i; break }
        }
        $body = if ($ei -gt $si) { @($lines[$si..($ei - 1)]) } else { @() }
        $text = $body -join "`n"
        $lc   = ($body | Where-Object { $_.Trim() -ne "" }).Count
        $cc   = $text.Length
        $tok  = [math]::Round($cc / 3.5)
        Write-Host ""
        Write-Host ("--- {0:N0} lines / {1:N0} chars / ~{2:N0} tokens est. (Claude Code) ---" -f $lc, $cc, $tok) -ForegroundColor DarkGray
        Add-ZTokensRecord -Lines $lc -Chars $cc -Est $tok
    } catch {}
    Remove-Item -LiteralPath $tp -Force -ErrorAction SilentlyContinue
    Write-ZTrailer -FinalNote $FinalNote
}

# ── Deploy-verification planning (pure; unit-tested in tests/) ──────────────

function Get-VerifyTimeout {
    <#
    .SYNOPSIS
        Seconds the live-build verification may wait, per project.

    .DESCRIPTION
        verify.timeoutSeconds in zconfig.json lets a project that is slow to
        BOOT say so, instead of every deploy of it warning on a success. An
        app that runs database migrations in its entrypoint exceeds a 30s
        window on every deploy that ships one - and a warning that fires on
        routine success trains people to ignore the one that matters
        (evo.scripts#101).
    #>
    param($Proj, [int]$DefaultSec)
    if ($Proj.verify -and $Proj.verify.timeoutSeconds) {
        return [int]$Proj.verify.timeoutSeconds
    }
    return $DefaultSec
}

function Get-VerifyAttempts {
    <#
    .SYNOPSIS
        The ordered ways to read this project's live build, most-trustworthy
        first. Pure: config in, plan out - so the ordering rules are testable
        without ssh.

    .DESCRIPTION
        Three channels exist, and their order is the whole point (#101):

          exec  - docker-network read via verify.viaProxy/upstream. Cannot
                  answer from the wrong product, works for apps with no
                  published port.
          port  - localhost:<verify.port> on the server. Same-box, still
                  unambiguous; used only if the body carries a version.
          edge  - http://<ip> with a Host header. The proxy answers from
                  whichever vhost MATCHES that header, so without one this
                  channel can only reach the default vhost - which is a
                  different product (that is how evo-ai's check once read
                  evo.ehs's build number). It is therefore included ONLY
                  when the project has a host to route by, and never
                  otherwise: no answer at all beats somebody else's answer.

        The caller must walk this list EVERY retry, not once up front: the
        verification runs while the app is restarting, which is exactly when
        the good channels are briefly down. Deciding the channel before the
        wait loop is how the whole window got spent on the worst one.
    #>
    param($Proj, [string]$ExecCmd)
    $attempts = @()
    if ($ExecCmd) {
        $attempts += [pscustomobject]@{
            Kind  = 'exec'
            Label = "docker network: $($Proj.verify.upstream) (via $($Proj.verify.viaProxy))"
        }
    }
    if ($Proj.verify -and $Proj.verify.port) {
        $vPath = "/api/build-version"
        if ($Proj.verify.path) { $vPath = [string]$Proj.verify.path }
        $attempts += [pscustomobject]@{
            Kind  = 'port'
            Port  = [int]$Proj.verify.port
            Path  = $vPath
            Label = "server localhost:$($Proj.verify.port)$vPath"
        }
    }
    $verifyHost = $null
    if ($Proj.deploy -and $Proj.deploy.verifyHost) { $verifyHost = [string]$Proj.deploy.verifyHost }
    elseif ($Proj.domain) { $verifyHost = [string]$Proj.domain }
    if ($verifyHost) {
        $attempts += [pscustomobject]@{
            Kind       = 'edge'
            HostHeader = $verifyHost
            Label      = "edge with Host: $verifyHost"
        }
    }
    # The comma stops PS 5.1 unrolling a one-element array into a bare
    # object - the same pipeline trap that deadlocked ztests day 2.
    return ,$attempts
}
