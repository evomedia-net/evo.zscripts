# Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# ZHelpers.ps1 — shared library dot-sourced by every z script. Not run directly.

# File extensions to skip recursively when building any deploy/backup zip.
$script:ArchiveExtensions = @(
    '.zip', '.dmg', '.arj', '.gz', '.tgz', '.tar', '.rar', '.7z', '.iso',
    '.bz2', '.xz', '.lz', '.lzma', '.cab', '.jar', '.war', '.ear', '.z',
    '.zst', '.zstd'
)
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

function Get-ZConfig {
    if ($null -ne $script:ZConfigCache) { return $script:ZConfigCache }
    $configPath = Join-Path $PSScriptRoot "zconfig.json"
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Host "ERROR: zconfig.json not found at $configPath" -ForegroundColor Red
        Write-Host "       Copy zconfig.example.json to zconfig.json and fill in your values." -ForegroundColor DarkGray
        exit 1
    }
    try {
        $script:ZConfigCache = Get-Content -LiteralPath $configPath -Raw -Encoding UTF8 | ConvertFrom-Json
    } catch {
        Write-Host "ERROR: Failed to parse zconfig.json - $($_.Exception.Message)" -ForegroundColor Red
        exit 1
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
        exit 1
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
    ssh -o StrictHostKeyChecking=no -i $cfg.ec2.pemKey (Get-Ec2Target) $Bash 2>&1 |
        ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        $msg = "Remote step failed: '$Label' (exit $LASTEXITCODE)."
        if ($FailHint) { $msg += " $FailHint" }
        throw $msg
    }
}

# ── Deploy git pull ──────────────────────────────────────────────────────────

# Fast-forward the project's checkout before a deploy when deploy.gitPull is set.
# zdeploy zips the working tree and does NOT otherwise pull, so after a merged
# PR the checkout can sit behind origin and the deploy would ship stale code
# while still bumping the build number (looks successful, changes nothing).
# Aborts the deploy on a failed pull rather than shipping uncertain code. Runs
# git bare (no 2>&1) and checks $LASTEXITCODE, matching Invoke-Ec2Step under
# $ErrorActionPreference='Stop'.
function Invoke-DeployGitPull {
    param([Parameter(Mandatory)]$Proj)
    if (-not ($Proj.deploy -and $Proj.deploy.gitPull)) { return }
    $root = $Proj.localRoot
    if (-not (Test-Path -LiteralPath (Join-Path $root ".git"))) {
        Write-Host "  gitPull set but '$root' is not a git repo - skipping pull." -ForegroundColor Yellow
        return
    }
    Write-Host "`n--- [0] git pull --ff-only ---" -ForegroundColor Cyan
    Push-Location -LiteralPath $root
    try {
        $branch = (git rev-parse --abbrev-ref HEAD)
        Write-Host "  Branch: $branch" -ForegroundColor DarkGray
        git pull --ff-only
        if ($LASTEXITCODE -ne 0) {
            throw "git pull --ff-only failed in '$root' (branch '$branch'). Resolve it (commit / stash / reconcile), then re-run - refusing to deploy possibly-stale code."
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

function Get-LabelFromBuildJsonObj {
    param($obj)
    if (-not $obj) { return $null }
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
        if ($script:ArchiveExtensions -contains $ext) { $archivesSkipped++; continue }
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
    $tp = Join-Path ([System.IO.Path]::GetTempPath()) ("_ztrack_" + [System.Guid]::NewGuid().ToString("N") + ".txt")
    $global:_ZTrackPath = $tp
    try { Start-Transcript -Path $tp -NoClobber | Out-Null } catch { $global:_ZTrackPath = $null }
}

function Stop-ZTracking {
    if (-not $global:_ZTrackPath) { return }
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
    } catch {}
    Remove-Item -LiteralPath $tp -Force -ErrorAction SilentlyContinue
}
