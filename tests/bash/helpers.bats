#!/usr/bin/env bats
# Evomedia.net Token Savers - https://github.com/kellymichels/zscripts-token-savers
# Created by Kelly Michels - dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
#
# helpers.bats - coverage for the pure/config functions in bash/zhelpers.sh.
#
#   bats tests/bash
#
# The bash port has its own implementation of the exclude lists and config
# accessors, so it can drift from the PowerShell side independently. These
# mirror tests/ZHelpers.Tests.ps1 assertion-for-assertion where the two are
# meant to agree.
#
# A fixture config is injected through ZCONFIG (zhelpers.sh has always honored
# it), so no real zconfig.json is read.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  export ZCONFIG="$BATS_TEST_TMPDIR/zconfig.json"
  cat > "$ZCONFIG" <<'JSON'
{
  "ec2": { "ip": "203.0.113.10", "user": "testuser", "pemKey": "/fixtures/test.pem", "stackRoot": "/home/testuser/stack" },
  "paths": { "temp": "/fixtures/temp", "backupsLocal": "/fixtures/backups", "backupsEc2": "/fixtures/backups-ec2", "scriptsRoot": "/fixtures/zscripts", "oneDriveBackups": "" },
  "projects": {
    "_note": "comment key - must never be treated as a project",
    "pyapp": {
      "label": "Fixture Python App", "kind": "python", "localRoot": "/fixtures/pyapp",
      "startModule": "pyapp.main", "ports": { "dev": 59990 }, "domain": "pyapp.example.com",
      "remote": { "path": "/home/testuser/stack/pyapp", "composeDir": "/home/testuser/stack/pyapp/docker", "appService": "app" },
      "deploy": { "zipName": "PyAppDeploy.zip", "exclude": ["docs", "fixtures-extra"] }
    },
    "viteapp": {
      "label": "Fixture Vite Site", "kind": "vite", "localRoot": "/fixtures/viteapp",
      "ports": { "dev": 59991 }, "domain": "www.example.com",
      "remote": { "path": "/home/testuser/stack/viteapp" }
    },
    "nextapp": {
      "label": "Fixture Next App", "kind": "nextjs", "localRoot": "/fixtures/nextapp",
      "ports": { "dev": 59992 }, "remote": { "path": "/home/testuser/stack/nextapp" }
    },
    "edgeproxy": {
      "label": "Fixture Edge", "kind": "edge", "localRoot": "/fixtures/edge",
      "proxyContainer": "edge_proxy", "remote": { "path": "/home/testuser/stack/edge" }
    },
    "noports": {
      "label": "Fixture No Dev Port", "kind": "python", "localRoot": "/fixtures/noports",
      "remote": { "path": "/home/testuser/stack/noports" }
    }
  }
}
JSON
  # shellcheck disable=SC1090
  source "$REPO/bash/zhelpers.sh"
}

# Emit the exclude list for a project; $2=1 means "for backup".
excludes() { z_archive_excludes "$1" "${2:-0}"; }

# Fixed-string, whole-line match. -F matters: without it grep treats the needle
# as a regex, and '.env' would match 'venv' (leading '.' = any char) - which
# silently turns every ".env is excluded" assertion into a false pass.
has() { printf '%s\n' "$1" | grep -qxF "$2"; }

# ---- config accessors -------------------------------------------------------

@test "zproj_keys returns every project in config order" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; zproj_keys | paste -sd, -"
  [ "$status" -eq 0 ]
  [ "$output" = "pyapp,viteapp,nextapp,edgeproxy,noports" ]
}

@test "zproj_keys omits underscore comment keys" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; zproj_keys"
  [ "$status" -eq 0 ]
  ! has "$output" "_note"
}

@test "zproj reads a project field" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; zproj pyapp .label"
  [ "$output" = "Fixture Python App" ]
}

@test "zproj returns empty for a missing field rather than the string null" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; zproj viteapp .startModule"
  [ "$output" = "" ]
}

@test "zec2_target composes user@ip" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; zec2_target"
  [ "$output" = "testuser@203.0.113.10" ]
}

@test "zremote_compose_dir prefers composeDir" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; zremote_compose_dir pyapp"
  [ "$output" = "/home/testuser/stack/pyapp/docker" ]
}

@test "zremote_compose_dir falls back to remote.path" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; zremote_compose_dir viteapp"
  [ "$output" = "/home/testuser/stack/viteapp" ]
}

@test "zedge_key finds the first edge-kind project" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; zedge_key"
  [ "$output" = "edgeproxy" ]
}

@test "zproj_keys_with_domain lists only projects that have a domain" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; zproj_keys_with_domain | paste -sd, -"
  [ "$output" = "pyapp,viteapp" ]
}

# ---- z_path (Windows -> host path translation) ------------------------------
# A shared zconfig.json may carry Windows paths when the same file is used from
# a Windows checkout and from WSL.

@test "z_path translates a Windows drive path to /mnt form" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; z_path 'F:\\evomedia.net\\app'"
  [ "$output" = "/mnt/f/evomedia.net/app" ]
}

@test "z_path lowercases the drive letter" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; z_path 'C:\\Users\\Someone'"
  [ "$output" = "/mnt/c/Users/Someone" ]
}

@test "z_path leaves a unix path untouched (no-op on native Linux/macOS)" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; z_path '/home/kelly/project'"
  [ "$output" = "/home/kelly/project" ]
}

@test "z_path leaves an empty string empty" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; z_path ''"
  [ "$output" = "" ]
}

# ---- z_archive_excludes -----------------------------------------------------
# Parity target: tests/ZHelpers.Tests.ps1 "Get-ArchiveExcludes".

@test "excludes: common junk applies to every kind" {
  run excludes pyapp
  for n in .git .idea .vscode .claude tmp nul .DS_Store backups; do
    has "$output" "$n" || { echo "missing common exclude: $n"; return 1; }
  done
}

@test "excludes: python build/venv cruft" {
  run excludes pyapp
  for n in .venv venv __pycache__ .pytest_cache .nicegui archive dist build htmlcov; do
    has "$output" "$n" || { echo "missing python exclude: $n"; return 1; }
  done
}

@test "excludes: vite drops node_modules and dist" {
  run excludes viteapp
  has "$output" "node_modules"
  has "$output" "dist"
}

@test "excludes: nextjs drops .next and .vercel" {
  run excludes nextapp
  has "$output" ".next"
  has "$output" ".vercel"
  has "$output" "next-env.d.ts"
}

# The regression this suite exists for: a dev .env shipped to production in a
# deploy zip. Deploys drop secrets and uploads; backups must keep them or the
# backup is not a restore point.
@test "excludes: python DEPLOY drops .env, .env.local, .env.production and uploads" {
  run excludes pyapp 0
  for n in .env .env.local .env.production uploads; do
    has "$output" "$n" || { echo "deploy should exclude: $n"; return 1; }
  done
}

@test "excludes: python BACKUP keeps .env, .env.local, .env.production and uploads" {
  run excludes pyapp 1
  for n in .env .env.local .env.production uploads; do
    if has "$output" "$n"; then echo "backup must NOT exclude: $n"; return 1; fi
  done
}

@test "excludes: python BACKUP still drops the virtualenv (bulk, not a secret)" {
  run excludes pyapp 1
  has "$output" ".venv"
}

@test "excludes: vite DEPLOY drops .env files" {
  run excludes viteapp 0
  for n in .env .env.local .env.production; do
    has "$output" "$n" || { echo "deploy should exclude: $n"; return 1; }
  done
}

@test "excludes: vite BACKUP keeps .env files" {
  run excludes viteapp 1
  for n in .env .env.local .env.production; do
    if has "$output" "$n"; then echo "backup must NOT exclude: $n"; return 1; fi
  done
}

@test "excludes: vite BACKUP still drops node_modules" {
  run excludes viteapp 1
  has "$output" "node_modules"
}

# nextjs has no backup gate on the PowerShell side either - both agree.
@test "excludes: nextjs drops .env in a backup too (no gate, matches PowerShell)" {
  run excludes nextapp 1
  has "$output" ".env"
}

@test "excludes: the project's own deploy.exclude entries are merged in" {
  run excludes pyapp
  has "$output" "docs"
  has "$output" "fixtures-extra"
}

@test "excludes: a kind with no specific list still gets the common entries" {
  run excludes edgeproxy
  has "$output" ".git"
}

# ---- json_build_label -------------------------------------------------------

@test "json_build_label formats v<productVersion>.<buildNumber>" {
  printf '{ "productVersion": "1.0", "buildNumber": 42 }' > "$BATS_TEST_TMPDIR/bv.json"
  run bash -c "source '$REPO/bash/zhelpers.sh'; json_build_label '$BATS_TEST_TMPDIR/bv.json'"
  [ "$output" = "v1.0.42" ]
}

@test "json_build_label reports unknown for a missing file" {
  run bash -c "source '$REPO/bash/zhelpers.sh'; json_build_label '$BATS_TEST_TMPDIR/nope.json'"
  [ "$output" = "unknown" ]
}
