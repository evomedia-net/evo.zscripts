# Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.0

# zdeploy.ps1 — deploy any project defined in zconfig.json to the server.
# Each project runs its own docker compose stack; the handler is picked by the
# project's "kind": python | vite | nextjs | edge | docker.
#
# Usage:
#   zdeploy <project> [<project> ...] [-Note "message"]
#   zdeploy all                       # every project (edge kinds first), stop at first failure
#
# Examples:
#   zdeploy viteapp
#   zdeploy pyapp -Note "fix billing banner"
#   zdeploy all -Note "weekly release"
#
# Flow (python/vite/nextjs): zip source -> free server disk space -> scp up ->
# unzip into remote.path (preserving server-side .env* files and anything in
# deploy.preserve) -> docker compose build + up -> verify the live site reports
# the new build version. Zips are always deleted.
#
# Compose service-name conventions (override with remote.appService):
#   python kind: app service "app", db service "db"
#   nextjs kind: app service "web", db service "db"
#
# Verification (python kind, when there is no scripts/build_version_tool.py):
#   Projects with a "verify" block are checked ON the server via
#   localhost:<port><path> — the only accurate way for stacks that are not
#   published through the edge proxy. Projects with only a "domain" fall back
#   to a Host-header request. Projects with neither are reported as NOT
#   verified rather than passing on the proxy's default vhost.
#
param(
    [Parameter(Position = 0, ValueFromRemainingArguments = $true)]
    [string[]]$Projects = @(),
    [string]$Note = "Build deployed"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

$cfg        = Get-ZConfig
$EC2_IP     = $cfg.ec2.ip
$PEM_KEY    = $cfg.ec2.pemKey
$STACK_ROOT = $cfg.ec2.stackRoot
$SSH_TARGET = Get-Ec2Target
$RemoteHome = Get-Ec2Home
$Ec2User    = $cfg.ec2.user

$TempRoot = $cfg.paths.temp
if (-not (Test-Path -LiteralPath $TempRoot)) {
    New-Item -ItemType Directory -Path $TempRoot -Force | Out-Null
}

if ($Projects.Count -eq 0) {
    $keys = (Get-ZProjectKeys) -join ', '
    Write-Host ""
    Write-Host "Usage: zdeploy <project> [<project> ...] | all  [-Note `"message`"]" -ForegroundColor Yellow
    Write-Host "  Projects in zconfig.json: $keys" -ForegroundColor Gray
    Write-Host "  'all' deploys everything (edge kinds first) and stops at the first failure." -ForegroundColor Gray
    Stop-ZTracking; exit 1
}

# Tolerate switch-style args (zdeploy -myproject) from muscle memory.
$Projects = @($Projects | ForEach-Object { $_.TrimStart('-') })

if ($Projects -contains 'all') {
    $allKeys  = Get-ZProjectKeys
    $edgeKeys = @($allKeys | Where-Object { $cfg.projects.$_.kind -eq 'edge' })
    $restKeys = @($allKeys | Where-Object { $cfg.projects.$_.kind -ne 'edge' })
    $Projects = @($edgeKeys + $restKeys)
    Write-Host "Deploying all projects: $($Projects -join ', ')" -ForegroundColor Cyan
}

function Get-DeployZipName {
    param([string]$Key, $Proj)
    if ($Proj.deploy -and $Proj.deploy.zipName) { return $Proj.deploy.zipName }
    return "${Key}Deploy.zip"
}

# Pre-upload cleanup: remove stale deploy zips, prune docker, truncate big logs,
# fail if under 1.5 GB free.
function Invoke-Ec2PreflightCleanup {
    param([string[]]$ExtraZipsToRemove = @())
    Write-Host "`n--- [Preflight] Freeing disk space on the server ---" -ForegroundColor Cyan
    $rmZipsClause = if ($ExtraZipsToRemove.Count -gt 0) { "rm -f $($ExtraZipsToRemove -join ' ')" } else { "true" }
    $preflightCmd = @(
        "echo '--- df / before cleanup ---'",
        "df -h /",
        "echo '--- removing stale deploy artifacts ---'",
        $rmZipsClause,
        "echo '--- pruning docker build cache + dangling images + stopped containers ---'",
        "sudo docker container prune -f >/dev/null 2>&1 || true",
        "sudo docker builder prune -f >/dev/null 2>&1 || true",
        "sudo docker image prune -af >/dev/null 2>&1 || true",
        "echo '--- truncating large container logs ---'",
        "sudo find /var/lib/docker/containers/ -name '*-json.log' -size +50M -exec truncate -s 0 {} + 2>/dev/null || true",
        "echo '--- df / after cleanup ---'",
        "df -h /",
        "avail_mb=`$(df --output=avail -BM / | tail -n 1 | tr -dc 0-9)",
        "[ -z `"`$avail_mb`" ] && avail_mb=0",
        "echo available_mb=`$avail_mb",
        "if [ `"`$avail_mb`" -lt 1500 ]; then echo 'ERROR: less than 1.5 GB free on /. Grow the root volume or run: sudo docker system prune -af' >&2; exit 11; fi"
    ) -join '; '
    ssh -o StrictHostKeyChecking=no -i $PEM_KEY $SSH_TARGET $preflightCmd
    if ($LASTEXITCODE -ne 0) {
        throw "Server pre-flight cleanup failed (exit $LASTEXITCODE). Root volume too full (need ~1.5 GB free, ideally 3+)."
    }
}

# Post-deploy cleanup: prune build cache and dangling images created during this deploy.
# Containers/volumes still in use by the running stack are NOT touched.
function Invoke-Ec2PostDeployCleanup {
    param([string]$Label = "post-deploy")
    Write-Host "`n--- [Post-deploy] Reclaiming disk space ($Label) ---" -ForegroundColor Cyan
    $cmd = @(
        "sudo docker container prune -f >/dev/null 2>&1 || true",
        "sudo docker builder prune -f >/dev/null 2>&1 || true",
        "sudo docker image prune -af >/dev/null 2>&1 || true",
        "sudo find /var/lib/docker/containers/ -name '*-json.log' -size +50M -exec truncate -s 0 {} + 2>/dev/null || true",
        "df -h /"
    ) -join '; '
    ssh -o StrictHostKeyChecking=no -i $PEM_KEY $SSH_TARGET $cmd
    if ($LASTEXITCODE -ne 0) {
        Write-Host "  Post-deploy cleanup returned non-zero exit ($LASTEXITCODE); continuing." -ForegroundColor DarkYellow
    }
}

function Send-DeployZip {
    param([string]$LocalZip, [string]$ZipName)
    scp -i $PEM_KEY $LocalZip "${SSH_TARGET}:$RemoteHome/"
    if ($LASTEXITCODE -ne 0) {
        throw "SCP upload failed (exit $LASTEXITCODE). Likely server disk space. Try: rm -f $RemoteHome/$ZipName"
    }
}

function Invoke-RemoteUnzip {
    param([string]$ZipName, [string]$DestPath)
    $bash = 'test -f {2}/{0} || {{ echo "missing {2}/{0}"; exit 2; }}; unzip -t {2}/{0} || exit 3; unzip -o {2}/{0} -d {1}; uc=$?; if [ $uc -gt 1 ]; then exit $uc; fi; exit 0' -f $ZipName, $DestPath, $RemoteHome
    Invoke-Ec2Step "unzip $ZipName" $bash
}

# ── Operator-file preservation (issue #2) ────────────────────────────────────
# Deploys replace the project directory wholesale, which used to destroy every
# operator-managed file except ./.env. These helpers preserve all .env* files
# at the project root PLUS any paths listed in deploy.preserve (files or
# directories), by tarring them to the home dir before the wipe and extracting
# them back after the unzip. Server-side copies win over anything shipped in
# the zip — the same semantics ./.env always had.
function Save-OperatorFiles {
    param([string]$Key, $Proj, [string]$RemotePath)
    $paths = @('.env*')
    if ($Proj.deploy -and $Proj.deploy.preserve) { $paths += @($Proj.deploy.preserve) }
    $spec = $paths -join ' '
    $tarball = "$RemoteHome/preserve_${Key}.tgz"
    # NOTE: no embedded quotes or $( ) here - PowerShell 5.1 strips embedded
    # double quotes when passing args to ssh.exe, silently corrupting the
    # remote command. Globs expand remotely; tar archives whatever exists
    # and its nonzero exit for missing paths is deliberately swallowed.
    Invoke-Ec2Step "preserve operator files ($spec)" "rm -f $tarball; cd $RemotePath && tar -czf $tarball $spec 2>/dev/null; true"
}

function Restore-OperatorFiles {
    param([string]$Key, [string]$RemotePath)
    $tarball = "$RemoteHome/preserve_${Key}.tgz"
    Invoke-Ec2Step "restore operator files" "test -f $tarball && tar -xzf $tarball -C $RemotePath; rm -f $tarball; true"
}

# ── Deploy verification (build-version match, not just HTTP 200 — a 200 can be
#    a stale cached build; the version match proves the new build is live) ─────

function Wait-VerifyStaticBuild {
    param([string]$Key, $Proj, [object]$PreZipBuildState)
    if (-not $PreZipBuildState) {
        Write-Host "`n--- [$Key version] SKIPPED (no local build-version.json - see 'Enabling deploy verification' in README) ---" -ForegroundColor DarkYellow
        return
    }
    # Expect the COMMITTED stamp, not +1: builds no longer self-bump (a
    # prebuild hook incremented inside the image, so the served version
    # matched no commit and every build dirtied the tree). The counter now
    # advances deliberately — one version bump per merged PR — so "is the
    # build I just packed live?" means an exact match.
    $expectedLabel = Get-LabelFromBuildJsonObj $PreZipBuildState
    Write-Host "`n--- [$Key] Live build verification (expect $expectedLabel) ---" -ForegroundColor Cyan
    $containerName = $Proj.remote.containerName
    $deadline = (Get-Date).AddSeconds(45)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = $null
            if ($containerName) {
                # build-version.json may be blocked from external requests by the edge
                # proxy; read it inside the running container instead.
                $raw = ssh -o StrictHostKeyChecking=no -i $PEM_KEY $SSH_TARGET `
                    "sudo docker exec $containerName cat /usr/share/nginx/html/build-version.json 2>/dev/null"
                if ($raw) { $r = $raw | ConvertFrom-Json -ErrorAction Stop }
            } else {
                $headers = @{}
                if ($Proj.domain) { $headers['Host'] = $Proj.domain }
                $r = Invoke-RestMethod -Uri "http://$EC2_IP/build-version.json" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            }
            if ($r) {
                $remoteLabel = Get-LabelFromBuildJsonObj $r
                if ($remoteLabel -eq $expectedLabel) {
                    Write-Host "  PASS - live build $remoteLabel matches expected." -ForegroundColor Green
                    return
                }
                Write-Host "  Live build is $remoteLabel, expected $expectedLabel - waiting..." -ForegroundColor DarkYellow
            }
        } catch {
            Write-Host "  Container not ready yet - waiting..." -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 3
    }
    Write-Host "  WARNING: live build did not match $expectedLabel within 45s (upload or Docker build may have failed, or a stale build is cached)." -ForegroundColor Yellow
}

function Wait-VerifyApiBuild {
    param([string]$Key, $Proj, [string]$ExpectedLabel, [int]$TimeoutSec = 60)
    Write-Host "`n--- [$Key] Live build verification (expect $ExpectedLabel) ---" -ForegroundColor Cyan
    $headers = @{}
    if ($Proj.domain) { $headers['Host'] = $Proj.domain }
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-RestMethod -Uri "http://$EC2_IP/api/build-version" -Headers $headers -TimeoutSec 10 -ErrorAction Stop
            if ($r -and $r.build_version) {
                if ([string]$r.build_version -eq $ExpectedLabel) {
                    Write-Host "  PASS - live build $($r.build_version) matches expected." -ForegroundColor Green
                    return $true
                }
                Write-Host "  Live build is $($r.build_version), expected $ExpectedLabel - waiting..." -ForegroundColor DarkYellow
            }
        } catch {
            Write-Host "  /api/build-version not ready yet - waiting..." -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 3
    }
    Write-Host "  WARNING: live build did not match $ExpectedLabel within ${TimeoutSec}s (a stale build may be cached)." -ForegroundColor Yellow
    return $false
}

# Verify a deploy by calling the app ON the server (localhost:<port>). Works
# for stacks that are not published through the edge proxy or whose host port
# is closed to the internet — hitting http://<ec2-ip>/ for those just answers
# from whatever vhost the proxy serves by default, which is a false PASS.
#
# Configure per project in zconfig.json:
#   "verify": { "port": 8005, "path": "/health", "expect": "\"status\":\"ok\"" }
# port is required; path defaults to "/", expect is an optional substring.
function Test-DeployHealth {
    param([string]$Key, $Proj, [int]$TimeoutSec = 60)

    $port   = [int]$Proj.verify.port
    $path   = if ($Proj.verify.path) { [string]$Proj.verify.path } else { "/" }
    $expect = [string]$Proj.verify.expect

    Write-Host "`n--- [$Key] Health check (on server: localhost:$port$path) ---" -ForegroundColor Cyan
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $raw = ssh -o StrictHostKeyChecking=no -i $PEM_KEY $SSH_TARGET "curl -s -m 8 http://localhost:$port$path"
        $body = ($raw | Out-String).Trim()
        if ($LASTEXITCODE -eq 0 -and $body) {
            if (-not $expect -or $body.Contains($expect)) {
                Write-Host "  PASS - $body" -ForegroundColor Green
                return $true
            }
            Write-Host "  Responding but '$expect' not found - waiting..." -ForegroundColor DarkYellow
        } else {
            Write-Host "  Not ready yet - waiting..." -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 3
    }
    Write-Host "  WARNING: no healthy response from localhost:$port$path within ${TimeoutSec}s." -ForegroundColor Yellow
    return $false
}

# Where the thing just deployed can be reached. A project published through the
# edge proxy has a domain; one that is not still has somewhere to point at, and
# saying nothing is the least useful option — an internal service is exactly the
# case where "where did that land?" is hardest to answer from memory. Falls back
# through what the project actually declares, and prints nothing if it declares
# none of it.
function Write-DeployLocation {
    param($Proj, [int]$Pad = 0)
    $label = "Site:".PadRight([Math]::Max(5, $Pad))
    if ($Proj.domain) {
        Write-Host "$label https://$($Proj.domain)" -ForegroundColor Yellow
        return
    }
    # No public route: give the server-local endpoint the deploy just verified.
    $port = if ($Proj.verify -and $Proj.verify.port) { [int]$Proj.verify.port }
            elseif ($Proj.ports -and $Proj.ports.prod) { [int]$Proj.ports.prod }
            else { 0 }
    if ($port -le 0) { return }
    $path = if ($Proj.verify -and $Proj.verify.path) { [string]$Proj.verify.path } else { "" }
    Write-Host "$label http://127.0.0.1:$port$path  (on the server; no public domain)" -ForegroundColor Yellow
}

# ── Kind handlers ────────────────────────────────────────────────────────────

function Invoke-PythonDeploy {
    param([string]$Key, $Proj, [string]$ChangeNote)

    $DeployStart = Get-Date
    $prevLoc     = Get-Location
    $root        = $Proj.localRoot
    $remotePath  = $Proj.remote.path
    $composeDir  = if ($Proj.remote.composeDir) { $Proj.remote.composeDir } else { $remotePath }
    $appSvc      = if ($Proj.remote.appService) { $Proj.remote.appService } else { "app" }
    $zipName     = Get-DeployZipName -Key $Key -Proj $Proj
    $zipLocal    = Join-Path $TempRoot $zipName
    $BuildVersion = $null
    $versionTool = Join-Path $root "scripts\build_version_tool.py"
    $hasVersionTool = Test-Path -LiteralPath $versionTool

    try {
        if (-not (Test-Path -LiteralPath $root)) { throw "Project root not found: $root" }
        Set-Location -LiteralPath $root

        Write-Host "`n=== $($Proj.label) deploy (python) ===" -ForegroundColor Cyan
        Write-Host "Local zip: $zipLocal" -ForegroundColor DarkGray

        Write-Host "`n--- [1] Zipping $($Proj.label) ---" -ForegroundColor Cyan
        Get-ChildItem -LiteralPath $root -Directory -Recurse -Filter "__pycache__" -ErrorAction SilentlyContinue |
            Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
        New-ProjectArchive -SourcePath $root -DestinationZip $zipLocal -TopLevelExclude (Get-ArchiveExcludes -Project $Proj)

        Invoke-Ec2PreflightCleanup -ExtraZipsToRemove @("$RemoteHome/$zipName")

        Write-Host "`n--- [2] Uploading zip ---" -ForegroundColor Cyan
        Send-DeployZip -LocalZip $zipLocal -ZipName $zipName

        Write-Host "`n--- [3] Unzipping and rebuilding on the server ---" -ForegroundColor Cyan
        Invoke-Ec2Step "apt-get install unzip" "sudo apt-get update -qq && sudo apt-get install -y unzip"
        Invoke-Ec2Step "ensure stack root" "sudo mkdir -p $STACK_ROOT && sudo chown ${Ec2User}:${Ec2User} $STACK_ROOT"
        Invoke-Ec2Step "ensure shared web network" "sudo docker network create web 2>/dev/null || true"
        Save-OperatorFiles -Key $Key -Proj $Proj -RemotePath $remotePath
        Invoke-Ec2Step "replace project directory" "sudo rm -rf $remotePath && sudo mkdir -p $remotePath && sudo chown ${Ec2User}:${Ec2User} $remotePath"
        Invoke-RemoteUnzip -ZipName $zipName -DestPath $remotePath
        Restore-OperatorFiles -Key $Key -RemotePath $remotePath
        Invoke-Ec2Step "require compose directory" "test -d $composeDir"
        Invoke-Ec2Step "docker compose build $appSvc" "cd $composeDir && sudo COMPOSE_BAKE=false docker compose build $appSvc"
        Invoke-Ec2Step "docker compose up -d" "cd $composeDir && sudo COMPOSE_BAKE=false docker compose up -d"
        Invoke-Ec2Step "record deploy time; remove remote zip" "date -u +'%Y-%m-%d %H:%M:%S UTC' | sudo tee $remotePath/.last_deploy_utc > /dev/null && rm -f $RemoteHome/$zipName"

        if ($hasVersionTool) {
            Write-Host "`n--- [4] Incrementing build version ---" -ForegroundColor Cyan
            $BumpCmd = "cd $composeDir && sudo docker compose exec -T $appSvc python scripts/build_version_tool.py bump"
            for ($attempt = 1; $attempt -le 5; $attempt++) {
                $output = ssh -o StrictHostKeyChecking=no -i $PEM_KEY $SSH_TARGET $BumpCmd
                if ($LASTEXITCODE -eq 0 -and $output) {
                    $BuildVersion = ($output | Select-Object -Last 1).ToString().Trim()
                    break
                }
                Write-Host "  Attempt $attempt failed, retrying in 3s..." -ForegroundColor DarkYellow
                Start-Sleep -Seconds 3
            }
            if (-not $BuildVersion) { throw "Build version bump failed after 5 attempts" }

            python $versionTool set $BuildVersion | Out-Null
            ssh -o StrictHostKeyChecking=no -i $PEM_KEY $SSH_TARGET "echo '$BuildVersion' | sudo tee $remotePath/.build_version > /dev/null"
            $changelogTool = Join-Path $root "scripts\build_changelog_tool.py"
            if (Test-Path -LiteralPath $changelogTool) {
                if ([string]::IsNullOrWhiteSpace($ChangeNote)) { $ChangeNote = "Build deployed" }
                python $changelogTool append --version $BuildVersion --note "$ChangeNote" | Out-Null
            }

            Write-Host "`n--- [5] Restarting app to pick up new version ---" -ForegroundColor Cyan
            ssh -o StrictHostKeyChecking=no -i $PEM_KEY $SSH_TARGET "cd $composeDir && sudo COMPOSE_BAKE=false docker compose restart $appSvc"
            if ($LASTEXITCODE -ne 0) { throw "App restart after build bump failed (exit $LASTEXITCODE)" }

            Wait-VerifyApiBuild -Key $Key -Proj $Proj -ExpectedLabel $BuildVersion -TimeoutSec 30 | Out-Null
        } elseif ($Proj.verify -and $Proj.verify.port) {
            Test-DeployHealth -Key $Key -Proj $Proj -TimeoutSec 60 | Out-Null
        } elseif ($Proj.domain) {
            Write-Host "`n--- [4] Basic reachability check (no build_version_tool - see 'Enabling deploy verification' in README) ---" -ForegroundColor Cyan
            $headers = @{ 'Host' = $Proj.domain }
            $deadline = (Get-Date).AddSeconds(30)
            $up = $false
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 3
                try {
                    $resp = Invoke-WebRequest -Uri "http://$EC2_IP/" -Headers $headers -UseBasicParsing -TimeoutSec 8 -ErrorAction Stop
                    if ($resp.StatusCode -lt 500) { $up = $true; break }
                } catch { Write-Host "  App not ready yet - waiting..." -ForegroundColor DarkGray }
            }
            if ($up) { Write-Host "  App is responding." -ForegroundColor Green }
            else { Write-Host "  WARNING: app did not respond within 30s." -ForegroundColor Yellow }
        } else {
            # No domain to send as a Host header and no "verify" block: a request
            # to http://<ec2-ip>/ would be answered by the proxy's default vhost,
            # so it proves nothing about THIS app. Say so instead of faking a PASS.
            Write-Host "`n--- [4] Deploy finished - NOT verified ---" -ForegroundColor Yellow
            Write-Host "  No 'domain' and no 'verify' block in zconfig.json for '$Key'," -ForegroundColor Yellow
            Write-Host "  so there is no way to confirm the new build is live." -ForegroundColor Yellow
            Write-Host '  Add to the project: "verify": { "port": <hostPort>, "path": "/health" }' -ForegroundColor Gray
        }

        Invoke-Ec2PostDeployCleanup -Label $Key

        $Elapsed    = (Get-Date) - $DeployStart
        $ElapsedStr = "{0:mm\:ss}" -f $Elapsed
        Write-Host "`n--- [Done] $($Proj.label) deployed! ---" -ForegroundColor Green
        Write-DeployLocation -Proj $Proj
        if ($BuildVersion) { Write-Host "Build Version: $BuildVersion" -ForegroundColor Magenta }
        Write-Host "Change Note: $ChangeNote" -ForegroundColor Cyan
        Write-Host "Deploy Time: $ElapsedStr ($([math]::Round($Elapsed.TotalSeconds))s)" -ForegroundColor DarkGray
    }
    finally {
        if (Test-Path -LiteralPath $zipLocal) {
            try { Remove-Item -LiteralPath $zipLocal -Force -ErrorAction Stop } catch { }
        }
        Set-Location -LiteralPath $prevLoc
    }
}

function Invoke-ViteDeploy {
    param([string]$Key, $Proj, [string]$ChangeNote)

    $DeployStart = Get-Date
    $prevLoc     = Get-Location
    $root        = $Proj.localRoot
    $remotePath  = $Proj.remote.path
    $zipName     = Get-DeployZipName -Key $Key -Proj $Proj
    $zipLocal    = Join-Path $TempRoot $zipName
    $preZipBuild = $null

    try {
        if (-not (Test-Path -LiteralPath $root)) { throw "Project root not found: $root" }
        Set-Location -LiteralPath $root

        Write-Host "`n=== $($Proj.label) deploy (vite/static) ===" -ForegroundColor Cyan
        Write-Host "Local zip: $zipLocal" -ForegroundColor DarkGray

        Write-Host "`n--- [1] Zipping site ---" -ForegroundColor Cyan
        $preZipBuild = Read-JsonBuildVersion -FilePath (Join-Path $root "build-version.json")
        if ($preZipBuild) {
            Write-Host "  Pre-zip build label: $(Get-LabelFromBuildJsonObj $preZipBuild) (server-side build will bump +1)" -ForegroundColor Gray
        }
        New-ProjectArchive -SourcePath $root -DestinationZip $zipLocal -TopLevelExclude (Get-ArchiveExcludes -Project $Proj)

        Invoke-Ec2PreflightCleanup -ExtraZipsToRemove @("$RemoteHome/$zipName")

        Write-Host "`n--- [2] Uploading zip ---" -ForegroundColor Cyan
        Send-DeployZip -LocalZip $zipLocal -ZipName $zipName

        Write-Host "`n--- [3] Unzipping and rebuilding on the server ---" -ForegroundColor Cyan
        Invoke-Ec2Step "apt-get install unzip" "sudo apt-get update -qq && sudo apt-get install -y unzip"
        Invoke-Ec2Step "ensure stack root" "sudo mkdir -p $STACK_ROOT && sudo chown ${Ec2User}:${Ec2User} $STACK_ROOT"
        Invoke-Ec2Step "ensure shared web network" "sudo docker network create web 2>/dev/null || true"
        Save-OperatorFiles -Key $Key -Proj $Proj -RemotePath $remotePath
        Invoke-Ec2Step "replace project directory" "sudo rm -rf $remotePath && sudo mkdir -p $remotePath && sudo chown ${Ec2User}:${Ec2User} $remotePath"
        Invoke-RemoteUnzip -ZipName $zipName -DestPath $remotePath
        Restore-OperatorFiles -Key $Key -RemotePath $remotePath
        Invoke-Ec2Step "require compose file" "test -f $remotePath/docker-compose.yml"
        Invoke-Ec2Step "docker compose build" "cd $remotePath && sudo COMPOSE_BAKE=false docker compose build"
        Invoke-Ec2Step "docker compose up -d" "cd $remotePath && sudo COMPOSE_BAKE=false docker compose up -d"

        $edgeProj = Get-ZEdgeProject
        if ($edgeProj -and $edgeProj.Config.proxyContainer) {
            Invoke-Ec2Step "reload edge nginx (flush DNS cache for new container IP)" "sudo docker exec $($edgeProj.Config.proxyContainer) nginx -s reload"
        }
        Invoke-Ec2Step "record deploy time; remove remote zip" "date -u +'%Y-%m-%d %H:%M:%S UTC' | sudo tee $remotePath/.last_deploy_utc > /dev/null && rm -f $RemoteHome/$zipName"

        Wait-VerifyStaticBuild -Key $Key -Proj $Proj -PreZipBuildState $preZipBuild
        Invoke-Ec2PostDeployCleanup -Label $Key

        $Elapsed    = (Get-Date) - $DeployStart
        $ElapsedStr = "{0:mm\:ss}" -f $Elapsed
        Write-Host "`n--- [Done] $($Proj.label) deployed! ---" -ForegroundColor Green
        Write-DeployLocation -Proj $Proj
        Write-Host "Change Note: $ChangeNote" -ForegroundColor Cyan
        Write-Host "Deploy Time: $ElapsedStr ($([math]::Round($Elapsed.TotalSeconds))s)" -ForegroundColor DarkGray
    }
    finally {
        if (Test-Path -LiteralPath $zipLocal) {
            try { Remove-Item -LiteralPath $zipLocal -Force -ErrorAction Stop } catch { }
        }
        Set-Location -LiteralPath $prevLoc
    }
}

function Invoke-NextDeploy {
    param([string]$Key, $Proj, [string]$ChangeNote)

    $DeployStart = Get-Date
    $prevLoc     = Get-Location
    $root        = $Proj.localRoot
    $remotePath  = $Proj.remote.path
    $appSvc      = if ($Proj.remote.appService) { $Proj.remote.appService } else { "web" }
    $zipName     = Get-DeployZipName -Key $Key -Proj $Proj
    $zipLocal    = Join-Path $TempRoot $zipName
    $preZipBuild = $null

    try {
        if (-not (Test-Path -LiteralPath $root)) { throw "Project root not found: $root" }
        Set-Location -LiteralPath $root

        Write-Host "`n=== $($Proj.label) deploy (nextjs) ===" -ForegroundColor Cyan
        Write-Host "Local zip: $zipLocal" -ForegroundColor DarkGray

        $preZipBuild = Read-JsonBuildVersion -FilePath (Join-Path $root "public\build-version.json")
        if ($preZipBuild) {
            Write-Host "  Pre-zip build label: $(Get-LabelFromBuildJsonObj $preZipBuild) (server-side build will bump +1)" -ForegroundColor Gray
        }

        Write-Host "`n--- [1] Zipping project files ---" -ForegroundColor Cyan
        New-ProjectArchive -SourcePath $root -DestinationZip $zipLocal -TopLevelExclude (Get-ArchiveExcludes -Project $Proj)

        Invoke-Ec2PreflightCleanup -ExtraZipsToRemove @("$RemoteHome/$zipName")

        Write-Host "`n--- [2] Uploading zip ---" -ForegroundColor Cyan
        Send-DeployZip -LocalZip $zipLocal -ZipName $zipName

        Write-Host "`n--- [3] Unzipping and rebuilding on the server ---" -ForegroundColor Cyan
        Invoke-Ec2Step "ensure unzip installed" "sudo apt-get update -qq && sudo apt-get install -y unzip"
        Invoke-Ec2Step "ensure stack root" "sudo mkdir -p $STACK_ROOT && sudo chown ${Ec2User}:${Ec2User} $STACK_ROOT"
        Invoke-Ec2Step "ensure shared web network" "sudo docker network create web 2>/dev/null || true"
        Save-OperatorFiles -Key $Key -Proj $Proj -RemotePath $remotePath
        Invoke-Ec2Step "replace project directory" "sudo rm -rf $remotePath && sudo mkdir -p $remotePath && sudo chown ${Ec2User}:${Ec2User} $remotePath"
        Invoke-RemoteUnzip -ZipName $zipName -DestPath $remotePath
        Restore-OperatorFiles -Key $Key -RemotePath $remotePath

        Write-Host "`n--- [4] Docker compose rebuild ---" -ForegroundColor Cyan
        Invoke-Ec2Step "docker compose down" "cd $remotePath && sudo COMPOSE_BAKE=false docker compose down"
        Invoke-Ec2Step "docker compose build" "cd $remotePath && sudo COMPOSE_BAKE=false docker compose build"
        Invoke-Ec2Step "docker compose up -d" "cd $remotePath && sudo COMPOSE_BAKE=false docker compose up -d"

        if ($Proj.db -and $Proj.db.user -and $Proj.db.name) {
            $waitDb = "cd $remotePath && for i in `$(seq 1 30); do sudo docker compose exec -T db pg_isready -U $($Proj.db.user) -d $($Proj.db.name) >/dev/null 2>&1 && break; sleep 2; done"
            Invoke-Ec2Step "wait for postgres ready" $waitDb
        }
        if ($Proj.migrations -eq "prisma") {
            Invoke-Ec2Step "apply prisma migrations" "cd $remotePath && sudo docker compose exec -T $appSvc npx prisma migrate deploy"
        }
        Invoke-Ec2Step "record deploy timestamp; remove remote zip" "date -u +'%Y-%m-%d %H:%M:%S UTC' | sudo tee $remotePath/.last_deploy_utc > /dev/null && rm -f $RemoteHome/$zipName"

        Write-Host "`n--- [5] Verifying deployment ---" -ForegroundColor Cyan
        if ($Proj.ports -and $Proj.ports.prod) {
            $directUrl = "http://${EC2_IP}:$([int]$Proj.ports.prod)/"
            $deadline = (Get-Date).AddSeconds(60)
            $verified = $false
            while ((Get-Date) -lt $deadline) {
                Start-Sleep -Seconds 4
                try {
                    $resp = Invoke-WebRequest -Uri $directUrl -TimeoutSec 8 -ErrorAction Stop -UseBasicParsing
                    if ($resp.StatusCode -eq 200) {
                        Write-Host "  PASS - app is responding at $directUrl" -ForegroundColor Green
                        $verified = $true
                        break
                    }
                } catch {
                    Write-Host "  App not ready yet - waiting..." -ForegroundColor DarkGray
                }
            }
            if (-not $verified) {
                Write-Host "  WARNING: no response at $directUrl within 60s (is the port open in the security group?)." -ForegroundColor Yellow
            }
        }
        if ($preZipBuild) {
            # Committed stamp, not +1 — see the note in Wait-VerifyStaticBuild.
            $expectedLabel = Get-LabelFromBuildJsonObj $preZipBuild
            Wait-VerifyApiBuild -Key $Key -Proj $Proj -ExpectedLabel $expectedLabel -TimeoutSec 60 | Out-Null
        } else {
            Write-Host "  (No public/build-version.json - version verification skipped. See 'Enabling deploy verification' in README.)" -ForegroundColor DarkYellow
        }

        Invoke-Ec2PostDeployCleanup -Label $Key

        $Elapsed    = (Get-Date) - $DeployStart
        $ElapsedStr = "{0:mm\:ss}" -f $Elapsed
        Write-Host "`n--- [Done] $($Proj.label) deployed! ---" -ForegroundColor Green
        Write-DeployLocation -Proj $Proj -Pad 12
        Write-Host "Change Note: $ChangeNote" -ForegroundColor Cyan
        Write-Host "Deploy Time: $ElapsedStr ($([math]::Round($Elapsed.TotalSeconds))s)" -ForegroundColor DarkGray
    }
    finally {
        if (Test-Path -LiteralPath $zipLocal) {
            try { Remove-Item -LiteralPath $zipLocal -Force -ErrorAction Stop } catch { }
        }
        Set-Location -LiteralPath $prevLoc
    }
}

function Invoke-EdgeDeploy {
    param([string]$Key, $Proj)

    $root       = $Proj.localRoot
    $remotePath = $Proj.remote.path
    $pc         = $Proj.proxyContainer

    Write-Host "`n=== $($Proj.label) deploy (edge nginx ingress) ===" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $root)) { throw "Edge root not found: $root" }
    foreach ($required in @('docker-compose.yml', 'nginx.conf')) {
        if (-not (Test-Path -LiteralPath (Join-Path $root $required))) { throw "Missing $root\$required" }
    }

    Invoke-Ec2Step "ensure shared web network" "sudo docker network create web 2>/dev/null || true"
    Invoke-Ec2Step "ensure edge dir" "sudo mkdir -p $remotePath && sudo chown ${Ec2User}:${Ec2User} $remotePath"

    # Ship every top-level file in the edge folder — nginx.conf, compose, css,
    # htpasswd, whatever the proxy serves. Subdirectories (logs, certs) stay put.
    $files = @(Get-ChildItem -LiteralPath $root -File | Where-Object { $_.Name -ne 'nul' })
    foreach ($f in $files) {
        Write-Host "  >> uploading $($f.Name)" -ForegroundColor DarkCyan
        scp -i $PEM_KEY $f.FullName "${SSH_TARGET}:$remotePath/"
        if ($LASTEXITCODE -ne 0) { throw "SCP failed for $($f.Name) (exit $LASTEXITCODE)" }
    }

    $certMount = if ($Proj.certsSource) { "-v $($Proj.certsSource):/etc/letsencrypt/:ro " } else { "" }
    Invoke-Ec2Step "validate new nginx.conf" "sudo docker run --rm -v $remotePath/nginx.conf:/etc/nginx/nginx.conf:ro ${certMount}nginx:1.27-alpine nginx -t -c /etc/nginx/nginx.conf"

    # A container from an older compose project may still hold the proxy name;
    # docker refuses a second create with the same name, so remove it first.
    $rmStale = if ($pc) { "; sudo docker rm -f $pc 2>/dev/null || true" } else { "" }
    Invoke-Ec2Step "edge: compose down + remove stale proxy" "cd $remotePath && sudo docker compose down 2>/dev/null || true$rmStale"
    Invoke-Ec2Step "edge compose up -d" "cd $remotePath && sudo docker compose up -d"
    if ($pc) {
        Invoke-Ec2Step "edge nginx reload" "sudo docker exec $pc nginx -s reload || true"
    }
    Invoke-Ec2Step "fix nginx-logs permissions (if present)" "if [ -d $remotePath/nginx-logs ]; then sudo chmod 777 $remotePath/nginx-logs; sudo chmod 666 $remotePath/nginx-logs/*.log 2>/dev/null || true; fi"
    Write-Host "--- [Done] Edge proxy deploy finished ---" -ForegroundColor Green
}

function Invoke-DockerDeploy {
    param([string]$Key, $Proj)

    $root       = $Proj.localRoot
    $remotePath = $Proj.remote.path

    Write-Host "`n=== $($Proj.label) deploy (docker compose) ===" -ForegroundColor Cyan
    if (-not (Test-Path -LiteralPath $root)) { throw "Project root not found: $root" }
    if (-not (Test-Path -LiteralPath (Join-Path $root "docker-compose.yml"))) { throw "Missing $root\docker-compose.yml" }

    Invoke-Ec2Step "ensure shared web network" "sudo docker network create web 2>/dev/null || true"
    Invoke-Ec2Step "ensure project dir" "sudo mkdir -p $remotePath && sudo chown ${Ec2User}:${Ec2User} $remotePath"

    $files = @(Get-ChildItem -LiteralPath $root -File -Force | Where-Object { $_.Name -ne 'nul' })
    foreach ($f in $files) {
        Write-Host "  >> uploading $($f.Name)" -ForegroundColor DarkCyan
        scp -i $PEM_KEY $f.FullName "${SSH_TARGET}:$remotePath/"
        if ($LASTEXITCODE -ne 0) { throw "SCP failed for $($f.Name) (exit $LASTEXITCODE)" }
    }

    Invoke-Ec2Step "docker compose pull" "cd $remotePath && sudo docker compose pull"
    Invoke-Ec2Step "docker compose up -d" "cd $remotePath && sudo docker compose up -d"

    Invoke-Ec2PostDeployCleanup -Label $Key
    Write-Host "`n--- [Done] $($Proj.label) deploy finished ---" -ForegroundColor Green
    Write-DeployLocation -Proj $Proj
}

# ── Dispatch ─────────────────────────────────────────────────────────────────

foreach ($key in $Projects) {
    $proj = Get-ZProject -Key $key
    Invoke-DeployGitPull -Proj $proj   # no-op unless deploy.gitPull is set
    switch ([string]$proj.kind) {
        "python" { Invoke-PythonDeploy -Key $key -Proj $proj -ChangeNote $Note }
        "vite"   { Invoke-ViteDeploy   -Key $key -Proj $proj -ChangeNote $Note }
        "nextjs" { Invoke-NextDeploy   -Key $key -Proj $proj -ChangeNote $Note }
        "edge"   { Invoke-EdgeDeploy   -Key $key -Proj $proj }
        "docker" { Invoke-DockerDeploy -Key $key -Proj $proj }
        default  { throw "No deploy handler for kind '$($proj.kind)' (project '$key'). Add an Invoke-<Kind>Deploy function in zdeploy.ps1." }
    }
}
Stop-ZTracking

# Last line of the run, after the tracking footer: scroll to the bottom and you
# can see how long ago this deployed. Only reached on success - a failed deploy
# throws out of the loop above, so this never claims a deploy that didn't happen.
Write-Host ""
Write-Host ("Last deployed at {0}" -f (Get-Date -Format "MM/dd/yyyy hh:mm:ss tt")) -ForegroundColor Cyan
# Two blank lines below, so the timestamp isn't crowded by the next prompt.
Write-Host ""
Write-Host ""
