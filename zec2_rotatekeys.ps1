# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
# Version: v1.0.0.0.11

# zec2_rotatekeys.ps1 - rotate / reset secret keys in a project's SERVER-SIDE
# .env, in place, without the values ever passing through this machine's shell
# history, command args, or the operator's screen.
#
# Why this exists: if a deploy ever ships a dev .env over a project's production
# .env (or a secret leaks), you need to (1) regenerate the machine secrets and
# (2) restore the correct operator-known values on the server - safely.
#
# How it stays safe:
#   * -Rotate keys are regenerated ON THE SERVER (openssl rand -hex 32). The new
#     value is created on the box and written straight into the .env there; it is
#     never sent from here, never printed.
#   * -Set keys are typed into a masked prompt and streamed to the server over
#     SSH stdin (the encrypted channel) - never placed in a command argument
#     (where `ps`/history would capture it) and never echoed back.
#   * The current server .env is copied to a timestamped .bak before any change.
#   * -WhatIf prints the exact plan and touches nothing. High-impact, so it
#     confirms before writing unless you pass -Confirm:$false.
#   * It does NOT touch the running app unless you pass -Restart, which
#     recreates the container (up -d --force-recreate) so it reloads the new
#     .env - a plain `restart` reuses the old environment. Prod restarts are a
#     deliberate, separate decision.
#
# Usage:
#   zec2_rotatekeys <project> [-Rotate K1,K2] [-Set K1,K2] [-EnvFile rel/path]
#                             [-Restart] [-HostName ip] [-WhatIf] [-Confirm:$false]
#
# Examples:
#   # Preview only - see exactly what would change, change nothing:
#   zec2_rotatekeys pyapp -Rotate JWT_SECRET -Set DATABASE_URL,ADMIN_EMAIL -WhatIf
#
#   # Regenerate the JWT secret and restore the operator-known values, then
#   # restart the app so it picks them up:
#   zec2_rotatekeys pyapp -Rotate JWT_SECRET -Set DATABASE_URL,ADMIN_EMAIL,ADMIN_PASSWORD -Restart
#
# The env file is auto-detected from the project's deploy.preserve (first *.env
# entry) or defaults to ".env"; override with -EnvFile (relative to remote.path,
# e.g. -EnvFile backend/.env).

[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = 'High')]
param(
    [Parameter(Position = 0)][string]$Project,
    [string[]]$Rotate = @(),
    [string[]]$Set = @(),
    [string]$EnvFile,
    [switch]$Restart,
    [string]$HostName
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "ZHelpers.ps1")
Start-ZTracking

function Show-Usage {
    Write-Host ""
    Write-Host "Usage: zec2_rotatekeys <project> [-Rotate K1,K2] [-Set K1,K2] [-EnvFile rel/path] [-Restart] [-WhatIf]" -ForegroundColor Yellow
    Write-Host "  -Rotate  keys regenerated on the server with a fresh random secret (openssl rand -hex 32)" -ForegroundColor Gray
    Write-Host "  -Set     keys set from a masked prompt, streamed over SSH stdin (for operator-known values)" -ForegroundColor Gray
    try { $keys = (Get-ZProjectKeys) -join ', '; Write-Host "  Projects: $keys" -ForegroundColor Gray } catch { }
    Write-Host ""
    Write-Host "  Example: zec2_rotatekeys pyapp -Rotate JWT_SECRET -Set DATABASE_URL,ADMIN_EMAIL,ADMIN_PASSWORD -Restart" -ForegroundColor DarkGray
}

# Server-side worker. Static (no secrets): -Rotate generates its value here on
# the box; -Set reads it from stdin. Uploaded base64-encoded so line endings and
# quoting survive the trip intact. Updates the KEY line atomically via python.
$rkHelper = @'
#!/usr/bin/env bash
set -uo pipefail
env_file="${1:-}"; key="${2:-}"; mode="${3:-}"
if [ -z "$env_file" ] || [ -z "$key" ] || [ -z "$mode" ]; then echo "BAD_ARGS"; exit 5; fi
if [ ! -f "$env_file" ]; then echo "ENV_MISSING:$env_file"; exit 2; fi
case "$mode" in
  rotate)
    command -v openssl >/dev/null 2>&1 || { echo "NO_OPENSSL"; exit 6; }
    val="$(openssl rand -hex 32)"
    ;;
  set)
    IFS= read -r val || true
    val="${val%$'\r'}"
    if [ -z "$val" ]; then echo "EMPTY_VALUE:$key"; exit 4; fi
    ;;
  *) echo "BAD_MODE:$mode"; exit 3 ;;
esac
KEY="$key" VAL="$val" python3 - "$env_file" <<'PY'
import os, sys, tempfile
path = sys.argv[1]
k = os.environ['KEY']; v = os.environ['VAL']
with open(path, 'r') as fh:
    lines = fh.read().splitlines()
out = []
found = False
for ln in lines:
    s = ln.lstrip()
    if (not s.startswith('#')) and ('=' in ln) and (ln.split('=', 1)[0].strip() == k):
        out.append(k + '=' + v)
        found = True
    else:
        out.append(ln)
if not found:
    out.append(k + '=' + v)
d = os.path.dirname(path) or '.'
fd, tmp = tempfile.mkstemp(dir=d)
try:
    with os.fdopen(fd, 'w') as fh:
        fh.write('\n'.join(out) + '\n')
    os.chmod(tmp, 0o600)
    os.replace(tmp, path)
except Exception:
    try:
        os.unlink(tmp)
    except OSError:
        pass
    raise
print('OK:' + k)
PY
'@

try {
    if (-not $Project) { Show-Usage; Stop-ZTracking; exit 1 }

    $Rotate = @($Rotate | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })
    $Set = @($Set | Where-Object { $_ -and $_.Trim() } | ForEach-Object { $_.Trim() })

    if ($Rotate.Count -eq 0 -and $Set.Count -eq 0) {
        Write-Host "ERROR: nothing to do - pass -Rotate and/or -Set with at least one key." -ForegroundColor Red
        Show-Usage; Stop-ZTracking; exit 1
    }

    # A key can't be both regenerated and set - -Set (explicit value) wins.
    $overlap = @($Rotate | Where-Object { $Set -contains $_ })
    if ($overlap.Count -gt 0) {
        Write-Host "NOTE: $($overlap -join ', ') given to both -Rotate and -Set; using -Set (explicit value)." -ForegroundColor Yellow
        $Rotate = @($Rotate | Where-Object { $Set -notcontains $_ })
    }

    $cfg = Get-ZConfig
    $proj = Get-ZProject -Key $Project     # exits with a clear error on a bad key
    $remotePath = $proj.remote.path
    if (-not $remotePath) {
        Write-Host "ERROR: project '$Project' has no remote.path in zconfig.json - nothing to rotate on the server." -ForegroundColor Red
        Stop-ZTracking; exit 1
    }

    # Env file location: -EnvFile wins; else first *.env in deploy.preserve; else ".env".
    if (-not $EnvFile) {
        $EnvFile = ".env"
        if ($proj.deploy -and $proj.deploy.preserve) {
            $cand = @($proj.deploy.preserve | Where-Object { $_ -match '\.env$' }) | Select-Object -First 1
            if ($cand) { $EnvFile = $cand }
        }
    }
    $EnvFile = $EnvFile -replace '\\', '/'
    $remoteEnv = "$remotePath/$EnvFile"

    $ip = if ($HostName) { $HostName } else { $cfg.ec2.ip }
    $pem = $cfg.ec2.pemKey
    $target = "$($cfg.ec2.user)@$ip"
    $sshOpts = @('-o', 'StrictHostKeyChecking=no', '-o', 'ConnectTimeout=15', '-i', $pem)
    $remoteHelper = "/tmp/zrk_$PID.sh"

    Write-Host ""
    Write-Host "=== zec2_rotatekeys ($($proj.label)) ===" -ForegroundColor Cyan
    Write-Host "  Server:   $target" -ForegroundColor DarkGray
    Write-Host "  Env file: $remoteEnv" -ForegroundColor DarkGray
    if ($Rotate.Count) { Write-Host "  Rotate (fresh random, server-side): $($Rotate -join ', ')" -ForegroundColor Gray }
    if ($Set.Count) { Write-Host "  Set (masked prompt, streamed):      $($Set -join ', ')" -ForegroundColor Gray }
    if ($Restart) { Write-Host "  Then: recreate the app container (reloads the new .env)" -ForegroundColor Gray }
    Write-Host ""

    $action = @()
    if ($Rotate.Count) { $action += "rotate [$($Rotate -join ',')]" }
    if ($Set.Count) { $action += "set [$($Set -join ',')]" }
    if ($Restart) { $action += "recreate" }
    if (-not $PSCmdlet.ShouldProcess("${target}:$remoteEnv", ($action -join ' + '))) {
        Write-Host "Preview only - no changes made." -ForegroundColor Yellow
        Stop-ZTracking; exit 0
    }

    # --- confirm the env file actually exists before we touch anything --------
    $exists = (ssh @sshOpts $target "test -f $remoteEnv && echo EXISTS || echo MISSING") | Select-Object -Last 1
    if ($LASTEXITCODE -ne 0) { throw "Could not reach $target over SSH (exit $LASTEXITCODE)." }
    if ($exists -ne "EXISTS") {
        throw "Env file not found on the server: $remoteEnv. Check remote.path / -EnvFile."
    }

    # --- back up the current server .env --------------------------------------
    $ts = Get-Date -Format "yyyyMMdd-HHmmss"
    $backup = "$remoteEnv.bak.$ts"
    ssh @sshOpts $target "cp -p $remoteEnv $backup"
    if ($LASTEXITCODE -ne 0) { throw "Backup of $remoteEnv failed (exit $LASTEXITCODE) - aborting before any change." }
    Write-Host "  Backed up server .env -> $backup" -ForegroundColor DarkGray

    # --- upload the worker (base64: no CR / quoting surprises) -----------------
    $helperLf = $rkHelper -replace "`r`n", "`n"
    $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($helperLf))
    ssh @sshOpts $target "echo $b64 | base64 -d > $remoteHelper && chmod 700 $remoteHelper"
    if ($LASTEXITCODE -ne 0) { throw "Failed to stage the rotation helper on the server (exit $LASTEXITCODE)." }

    $done = @()
    $failed = @()
    try {
        # --- rotate: value generated on the server, never seen here -----------
        foreach ($key in $Rotate) {
            $r = (ssh @sshOpts $target "bash $remoteHelper $remoteEnv $key rotate") | Select-Object -Last 1
            if ($LASTEXITCODE -eq 0 -and $r -like "OK:*") {
                Write-Host "  rotated  $key" -ForegroundColor Green
                $done += "$key (rotated)"
            } else {
                Write-Host "  FAILED   $key  ($r)" -ForegroundColor Red
                $failed += "$key ($r)"
            }
        }

        # --- set: masked prompt -> SSH stdin, never in args or on screen ------
        foreach ($key in $Set) {
            $secure = Read-Host -Prompt "  New value for $key" -AsSecureString
            $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
            try {
                $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
            } finally {
                [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr)
            }
            if ([string]::IsNullOrEmpty($plain)) {
                Write-Host "  skipped  $key  (no value entered)" -ForegroundColor Yellow
                $failed += "$key (empty - skipped)"
                $plain = $null
                continue
            }
            $r = ($plain | ssh @sshOpts $target "bash $remoteHelper $remoteEnv $key set") | Select-Object -Last 1
            $rc = $LASTEXITCODE
            $plain = $null   # drop the plaintext from memory promptly
            if ($rc -eq 0 -and $r -like "OK:*") {
                Write-Host "  set      $key" -ForegroundColor Green
                $done += "$key (set)"
            } else {
                Write-Host "  FAILED   $key  ($r)" -ForegroundColor Red
                $failed += "$key ($r)"
            }
        }
    } finally {
        ssh @sshOpts $target "rm -f $remoteHelper" | Out-Null
    }

    # --- optional app recreate ------------------------------------------------
    # A plain `docker compose restart` reuses the container's existing
    # environment, so it would NOT pick up the .env we just edited. `up -d
    # --force-recreate` rebuilds the container from current config, reloading
    # env_file / environment - the reliable way to apply the new secrets.
    $restarted = $false
    if ($Restart -and $done.Count -gt 0) {
        $composeDir = if ($proj.remote.composeDir) { $proj.remote.composeDir } else { $remotePath }
        $svc = if ($proj.remote.appService) { $proj.remote.appService } else { "app" }
        Write-Host ""
        Write-Host "  Recreating service '$svc' in $composeDir (to load the new .env) ..." -ForegroundColor Cyan
        ssh @sshOpts $target "cd $composeDir && sudo COMPOSE_BAKE=false docker compose up -d --force-recreate $svc"
        if ($LASTEXITCODE -eq 0) { Write-Host "  Recreated $svc." -ForegroundColor Green; $restarted = $true }
        else { Write-Host "  WARNING: recreate of '$svc' failed (exit $LASTEXITCODE) - apply it manually: docker compose up -d --force-recreate $svc" -ForegroundColor Red }
    } elseif ($Restart) {
        Write-Host "  Skipping recreate - no keys were changed." -ForegroundColor Yellow
    }

    # --- summary --------------------------------------------------------------
    Write-Host ""
    Write-Host "=== Summary ===" -ForegroundColor Cyan
    Write-Host "  Changed: $(if ($done.Count) { $done -join ', ' } else { 'none' })" -ForegroundColor $(if ($done.Count) { 'Green' } else { 'Yellow' })
    if ($failed.Count) { Write-Host "  Failed:  $($failed -join ', ')" -ForegroundColor Red }
    Write-Host "  Backup:  $backup  (delete once verified)" -ForegroundColor DarkGray
    if ($Restart -and -not $restarted -and $done.Count -gt 0) {
        Write-Host "  Recreate: NOT done - apply the new values with: docker compose up -d --force-recreate <svc>" -ForegroundColor Yellow
    } elseif (-not $Restart -and $done.Count -gt 0) {
        Write-Host "  Note:    the app is still running with the OLD values - re-run with -Restart, or 'docker compose up -d --force-recreate <svc>' on the server." -ForegroundColor Yellow
    }
    Write-Host ""

    Stop-ZTracking
    if ($failed.Count) { exit 2 }
    exit 0
}
catch {
    Write-Host "ERROR: $($_.Exception.Message)" -ForegroundColor Red
    Stop-ZTracking
    exit 1
}
