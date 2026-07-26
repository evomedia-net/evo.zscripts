#!/usr/bin/env bats
# Evomedia.net Token Savers - https://github.com/kellymichels/zscripts-token-savers
# Created by Kelly Michels - dev@evomedia.net
# Licensed under the MIT License. See LICENSE.
#
# args.bats - how the bash scripts read their target arguments.
#
#   bats tests/bash
#
# Mirrors tests/ArgumentParsing.Tests.ps1. Same safety rule as the PowerShell
# side: these run the real scripts, so they stay on code paths that exit BEFORE
# doing any work (no args, unknown key). Only zkill runs with a valid target,
# and only because the fixture's dev ports are deliberately unused and its
# localRoots do not exist - it finds no listeners and kills nothing. zdeploy,
# zbackup_ec2, zec2, zec2online, zrepair, zstop, zstart and zbackup are never
# invoked with a real target; that needs a disposable server.

setup() {
  REPO="$(cd "$(dirname "$BATS_TEST_FILENAME")/../.." && pwd)"
  BASHDIR="$REPO/bash"
  export ZCONFIG="$BATS_TEST_TMPDIR/zconfig.json"
  cat > "$ZCONFIG" <<'JSON'
{
  "ec2": { "ip": "203.0.113.10", "user": "testuser", "pemKey": "/fixtures/test.pem", "stackRoot": "/home/testuser/stack" },
  "paths": { "temp": "/fixtures/temp", "backupsLocal": "/fixtures/backups", "backupsEc2": "/fixtures/backups-ec2", "scriptsRoot": "/fixtures/zscripts", "oneDriveBackups": "" },
  "projects": {
    "_note": "comment key - must never be treated as a project",
    "pyapp": {
      "label": "Fixture Python App", "kind": "python", "localRoot": "/fixtures/nonexistent-pyapp",
      "startModule": "pyapp.main", "ports": { "dev": 59990 },
      "remote": { "path": "/home/testuser/stack/pyapp" }
    },
    "viteapp": {
      "label": "Fixture Vite Site", "kind": "vite", "localRoot": "/fixtures/nonexistent-viteapp",
      "ports": { "dev": 59991 }, "remote": { "path": "/home/testuser/stack/viteapp" }
    },
    "edgeproxy": {
      "label": "Fixture Edge", "kind": "edge", "localRoot": "/fixtures/nonexistent-edge",
      "remote": { "path": "/home/testuser/stack/edge" }
    }
  }
}
JSON
}

# ---- no arguments -----------------------------------------------------------
# Running bare must never mean "do it to everything".

@test "zkill with no args shows usage and exits 1" {
  run "$BASHDIR/zkill"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Usage"* ]]
}

@test "zstart with no args shows usage and exits non-zero" {
  run "$BASHDIR/zstart"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "zdeploy with no args shows usage and exits non-zero" {
  run "$BASHDIR/zdeploy"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "zbackup with no args shows usage and exits non-zero" {
  run "$BASHDIR/zbackup"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Usage"* ]]
}

@test "usage lists the configured project keys" {
  run "$BASHDIR/zkill"
  [[ "$output" == *"pyapp"* ]]
  [[ "$output" == *"viteapp"* ]]
}

@test "usage never advertises the underscore comment key" {
  run "$BASHDIR/zkill"
  [[ "$output" != *"_note"* ]]
}

# ---- unknown key ------------------------------------------------------------
# Exiting 0 having selected nothing is the dangerous outcome.

@test "zkill rejects an unknown project key" {
  run "$BASHDIR/zkill" definitelynotaproject
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown project key"* ]]
}

@test "zstart rejects an unknown project key" {
  run "$BASHDIR/zstart" definitelynotaproject
  [ "$status" -ne 0 ]
}

@test "zdeploy rejects an unknown project key" {
  run "$BASHDIR/zdeploy" definitelynotaproject
  [ "$status" -ne 0 ]
}

@test "the unknown-key error names both the bad key and the valid ones" {
  run "$BASHDIR/zkill" definitelynotaproject
  [[ "$output" == *"definitelynotaproject"* ]]
  [[ "$output" == *"pyapp"* ]]
}

@test "the underscore comment key is not addressable as a project" {
  run "$BASHDIR/zkill" _note
  [ "$status" -ne 0 ]
}

# The convention is that ANY "_"-prefixed key is a comment, not a project -
# PowerShell's Get-ZProject refuses them outright. A string-valued comment is
# also caught by the "is it an object?" check, so this uses an OBJECT-valued
# underscore key (e.g. someone keeping a "_template" block to copy from) to
# prove the prefix rule itself is enforced.
@test "an object-valued underscore key is still not addressable" {
  cat > "$BATS_TEST_TMPDIR/objkey.json" <<'JSON'
{
  "ec2": { "ip": "203.0.113.10", "user": "testuser", "pemKey": "/f/t.pem", "stackRoot": "/s" },
  "paths": { "temp": "/f/t", "backupsLocal": "/f/b", "backupsEc2": "/f/be", "scriptsRoot": "/f/z", "oneDriveBackups": "" },
  "projects": {
    "_template": {
      "label": "Template To Copy", "kind": "python", "localRoot": "/fixtures/none",
      "ports": { "dev": 59993 }, "remote": { "path": "/s/t" }
    },
    "pyapp": {
      "label": "Fixture Python App", "kind": "python", "localRoot": "/fixtures/nonexistent-pyapp",
      "ports": { "dev": 59990 }, "remote": { "path": "/s/py" }
    }
  }
}
JSON
  ZCONFIG="$BATS_TEST_TMPDIR/objkey.json" run "$BASHDIR/zkill" _template
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown project key"* ]]
}

@test "an object-valued underscore key is excluded from 'all'" {
  cat > "$BATS_TEST_TMPDIR/objkey2.json" <<'JSON'
{
  "ec2": { "ip": "203.0.113.10", "user": "testuser", "pemKey": "/f/t.pem", "stackRoot": "/s" },
  "paths": { "temp": "/f/t", "backupsLocal": "/f/b", "backupsEc2": "/f/be", "scriptsRoot": "/f/z", "oneDriveBackups": "" },
  "projects": {
    "_template": {
      "label": "Template To Copy", "kind": "python", "localRoot": "/fixtures/none",
      "ports": { "dev": 59993 }, "remote": { "path": "/s/t" }
    },
    "pyapp": {
      "label": "Fixture Python App", "kind": "python", "localRoot": "/fixtures/nonexistent-pyapp",
      "ports": { "dev": 59990 }, "remote": { "path": "/s/py" }
    }
  }
}
JSON
  ZCONFIG="$BATS_TEST_TMPDIR/objkey2.json" run "$BASHDIR/zkill" all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fixture Python App"* ]]
  [[ "$output" != *"Template To Copy"* ]]
}

# ---- leading dash: CURRENT bash behaviour ------------------------------------
# NOTE: this is a known divergence from the PowerShell port, pinned here as it
# actually behaves rather than as it ideally would. PowerShell tolerates a
# leading dash on any project key (zdeploy -myapp == zdeploy myapp). In bash,
# only zdeploy strips it ("${1#-}"); every other script treats -myapp as an
# unknown option and exits 1. These tests document today's behaviour so a fix
# is a deliberate change with a failing test to update, not a silent surprise.

@test "bash zdeploy strips a leading dash from a project key" {
  # Unknown key keeps this on the no-work path; the error must name the key
  # without its dash, proving the strip happened.
  run "$BASHDIR/zdeploy" -definitelynotaproject
  [ "$status" -ne 0 ]
  [[ "$output" == *"definitelynotaproject"* ]]
  [[ "$output" != *"-definitelynotaproject"* ]]
}

@test "bash zkill rejects a dashed key as an unknown option (diverges from PowerShell)" {
  run "$BASHDIR/zkill" -pyapp
  [ "$status" -eq 1 ]
  [[ "$output" == *"Unknown option"* ]]
}

@test "bash zstart rejects a dashed key as an unknown option (diverges from PowerShell)" {
  run "$BASHDIR/zstart" -pyapp
  [ "$status" -ne 0 ]
  [[ "$output" == *"Unknown option"* ]]
}

# ---- zkill target resolution (safe: fixture ports are unused) ----------------

@test "zkill accepts a bare project key" {
  run "$BASHDIR/zkill" pyapp
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fixture Python App"* ]]
  [[ "$output" == *"59990"* ]]
}

@test "zkill accepts several keys at once" {
  run "$BASHDIR/zkill" pyapp viteapp
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fixture Python App"* ]]
  [[ "$output" == *"Fixture Vite Site"* ]]
}

@test "zkill 'all' expands to every project with a dev port" {
  run "$BASHDIR/zkill" all
  [ "$status" -eq 0 ]
  [[ "$output" == *"Fixture Python App"* ]]
  [[ "$output" == *"Fixture Vite Site"* ]]
}

@test "zkill 'all' skips projects with no dev port (edge/docker stacks)" {
  run "$BASHDIR/zkill" all
  [[ "$output" != *"Fixture Edge"* ]]
}

@test "zkill --port overrides the configured dev port" {
  run "$BASHDIR/zkill" pyapp --port 59999
  [ "$status" -eq 0 ]
  [[ "$output" == *"59999"* ]]
  [[ "$output" != *"59990"* ]]
}

@test "zkill announces that --kill-all is not implemented rather than silently ignoring it" {
  run "$BASHDIR/zkill" pyapp --kill-all
  [ "$status" -eq 0 ]
  [[ "$output" == *"kill-all"* ]]
}
