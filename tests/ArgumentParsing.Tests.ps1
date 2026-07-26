# Evomedia.net Token Savers - https://github.com/kellymichels/zscripts-token-savers
# Created by Kelly Michels - dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# ArgumentParsing.Tests.ps1 - Pester 5 suite for how the scripts read their
# target arguments.
#
#   Invoke-Pester .\tests
#
# This is the layer that has regressed most often: bare vs dashed keys, 'all'
# expansion, and whether a bad key fails loudly or silently selects nothing.
#
# SAFETY
# ------
# These tests run the real scripts as child processes, so they are restricted to
# code paths that exit BEFORE doing any work:
#
#   * no arguments        -> usage + non-zero exit
#   * unknown project key -> error + non-zero exit (Get-ZProject exits first)
#
# Only zkill is exercised with a *valid* target, because with the fixture config
# it looks for listeners on deliberately unused high ports and finds none. The
# scripts that SSH, scp, deploy, or start servers (zdeploy, zbackup_ec2, zec2,
# zec2online, zrepair, zstop, zstart, zbackup) are NEVER invoked with a real
# target here - that is integration territory and needs a disposable server.
#
# Each test runs against an isolated temp installation: the .ps1 files copied to
# a temp dir alongside a fixture zconfig.json. Nothing touches this repo, and no
# real zconfig.json is read - so the suite is safe on a configured machine and
# passes on one that has never been configured.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot

    # Isolated installation: the scripts, plus a fixture config beside them.
    $script:Install = Join-Path ([IO.Path]::GetTempPath()) ("zargs-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $script:Install -Force | Out-Null
    Copy-Item (Join-Path $script:RepoRoot "*.ps1") $script:Install -Force

    # Fake roots that do not exist and ports nothing listens on, so any script
    # that somehow got past its guard would still find nothing to act on.
    $fixture = @{
        ec2 = @{ ip = "203.0.113.10"; user = "testuser"; pemKey = "C:\fixtures\test.pem"; stackRoot = "/home/testuser/stack" }
        paths = @{
            temp = (Join-Path $script:Install "temp")
            backupsLocal = (Join-Path $script:Install "backups")
            backupsEc2 = (Join-Path $script:Install "backups-ec2")
            scriptsRoot = $script:Install
            oneDriveBackups = ""
        }
        projects = [ordered]@{
            _note = "comment key - must never be treated as a project"
            pyapp = @{
                label = "Fixture Python App"; kind = "python"
                localRoot = (Join-Path $script:Install "nonexistent-pyapp")
                startModule = "pyapp.main"
                ports = @{ dev = 59990 }
                remote = @{ path = "/home/testuser/stack/pyapp" }
            }
            viteapp = @{
                label = "Fixture Vite Site"; kind = "vite"
                localRoot = (Join-Path $script:Install "nonexistent-viteapp")
                ports = @{ dev = 59991 }
                remote = @{ path = "/home/testuser/stack/viteapp" }
            }
            edgeproxy = @{
                label = "Fixture Edge"; kind = "edge"
                localRoot = (Join-Path $script:Install "nonexistent-edge")
                remote = @{ path = "/home/testuser/stack/edge" }
            }
        }
    }
    $fixture | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $script:Install "zconfig.json") -Encoding UTF8

    # Run a script in a child process; capture merged output and exit code.
    function Invoke-ZScript {
        param([string]$Script, [string[]]$ScriptArgs = @())
        $path = Join-Path $script:Install $Script
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $path @ScriptArgs 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output   = ($out -join "`n")
        }
    }
}

AfterAll {
    Remove-Item -LiteralPath $script:Install -Recurse -Force -ErrorAction SilentlyContinue
}

# Every target-taking script must refuse to guess. Running bare used to mean
# "do it to everything" for some of these, which is how an unintended full
# backup / deploy happens.
Describe "no arguments shows usage and exits non-zero" {
    It "<_> refuses to run bare" -ForEach @(
        "zstart.ps1", "ZKillOnly.ps1", "zdeploy.ps1", "zbackup.ps1",
        "zbackup_ec2.ps1", "zec2.ps1", "zec2online.ps1", "zrepair.ps1",
        "zstop.ps1", "zbackup_and_sync.ps1"
    ) {
        $r = Invoke-ZScript -Script $_
        $r.ExitCode | Should -Not -Be 0 -Because "$_ run bare must not silently act on every project"
        $r.Output | Should -Match "(?i)usage"
    }

    It "<_> lists the available project keys in its usage" -ForEach @(
        "zstart.ps1", "ZKillOnly.ps1", "zdeploy.ps1", "zbackup.ps1"
    ) {
        $r = Invoke-ZScript -Script $_
        $r.Output | Should -Match "pyapp"
        $r.Output | Should -Match "viteapp"
    }

    It "usage never advertises the underscore comment key" -ForEach @(
        "zstart.ps1", "ZKillOnly.ps1", "zdeploy.ps1", "zbackup.ps1"
    ) {
        (Invoke-ZScript -Script $_).Output | Should -Not -Match "_note"
    }
}

# An unknown key must fail loudly. Silently selecting nothing and exiting 0 is
# the dangerous outcome: a typo'd key in a scheduled task would look like a
# successful run that backed up nothing.
Describe "unknown project key fails loudly" {
    It "<_> rejects a key that is not in the config" -ForEach @(
        "zstart.ps1", "ZKillOnly.ps1", "zdeploy.ps1", "zbackup.ps1",
        "zbackup_ec2.ps1", "zec2.ps1", "zec2online.ps1", "zrepair.ps1", "zstop.ps1"
    ) {
        $r = Invoke-ZScript -Script $_ -ScriptArgs @("definitelynotaproject")
        $r.ExitCode | Should -Not -Be 0 -Because "$_ must not treat an unknown key as success"
        $r.Output | Should -Match "(?i)unknown project key|not.*found|available"
    }

    It "<_> names the offending key and the valid ones" -ForEach @(
        "zstart.ps1", "ZKillOnly.ps1", "zdeploy.ps1"
    ) {
        $r = Invoke-ZScript -Script $_ -ScriptArgs @("definitelynotaproject")
        $r.Output | Should -Match "definitelynotaproject"
        $r.Output | Should -Match "pyapp"
    }

    It "the underscore comment key is not addressable as a project" {
        $r = Invoke-ZScript -Script "ZKillOnly.ps1" -ScriptArgs @("_note")
        $r.ExitCode | Should -Not -Be 0
    }
}

# zdeploy -myapp == zdeploy myapp. The dash is tolerated everywhere for anyone
# with switch-style muscle memory; it must be stripped before the lookup, not
# passed through into the key.
Describe "leading-dash tolerance" {
    It "<_> strips a leading dash before resolving the key" -ForEach @(
        "zstart.ps1", "ZKillOnly.ps1", "zdeploy.ps1"
    ) {
        # A dashed *unknown* key proves the strip happened: the error must name
        # 'definitelynotaproject', not '-definitelynotaproject'. Using an unknown
        # key keeps this safe - it exits before doing any work.
        $r = Invoke-ZScript -Script $_ -ScriptArgs @("-definitelynotaproject")
        $r.Output | Should -Match "'definitelynotaproject'"
    }
}

# zkill is the one script safe to run for real here: the fixture's dev ports are
# deliberately unused, so it finds no listeners and kills nothing.
Describe "zkill target resolution (safe: fixture ports are unused)" {
    It "accepts a bare project key" {
        $r = Invoke-ZScript -Script "ZKillOnly.ps1" -ScriptArgs @("pyapp")
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "Fixture Python App"
        $r.Output | Should -Match "59990"
    }

    It "accepts the same key with a leading dash and behaves identically" {
        $bare   = Invoke-ZScript -Script "ZKillOnly.ps1" -ScriptArgs @("pyapp")
        $dashed = Invoke-ZScript -Script "ZKillOnly.ps1" -ScriptArgs @("-pyapp")
        $dashed.ExitCode | Should -Be $bare.ExitCode
        $dashed.Output | Should -Match "Fixture Python App"
    }

    It "accepts several keys at once" {
        $r = Invoke-ZScript -Script "ZKillOnly.ps1" -ScriptArgs @("pyapp", "viteapp")
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "Fixture Python App"
        $r.Output | Should -Match "Fixture Vite Site"
    }

    It "'all' expands to every project that has a dev port" {
        $r = Invoke-ZScript -Script "ZKillOnly.ps1" -ScriptArgs @("all")
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "Fixture Python App"
        $r.Output | Should -Match "Fixture Vite Site"
    }

    It "'all' skips projects with no dev port (edge/docker stacks)" {
        # edgeproxy has no ports.dev - it has no local dev server to stop.
        $r = Invoke-ZScript -Script "ZKillOnly.ps1" -ScriptArgs @("all")
        $r.Output | Should -Not -Match "Fixture Edge"
    }

    It "'-all' works the same as 'all'" {
        $r = Invoke-ZScript -Script "ZKillOnly.ps1" -ScriptArgs @("-all")
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "Fixture Python App"
    }

    It "reports the port it inspected rather than failing on an idle port" {
        $r = Invoke-ZScript -Script "ZKillOnly.ps1" -ScriptArgs @("viteapp")
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "59991"
    }

    It "-Port overrides the configured dev port" {
        $r = Invoke-ZScript -Script "ZKillOnly.ps1" -ScriptArgs @("pyapp", "-Port", "59999")
        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match "59999"
        $r.Output | Should -Not -Match "59990"
    }
}
