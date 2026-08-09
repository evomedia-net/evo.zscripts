# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# ZHelpers.Tests.ps1 — Pester 5 suite for the pure/config functions in ZHelpers.ps1.
#
#   Invoke-Pester .\tests
#
# Scope: functions with no side effects beyond reading a config file. Anything
# that SSHes, builds images, or kills processes is deliberately not covered here
# (see Invoke-Ec2Step, Stop-ProcessTree and friends) - those need a disposable
# server, not a unit test.
#
# The fixture config is injected via $env:ZCONFIG, the same override the bash
# port has always had. No real zconfig.json is read, so this suite is safe to
# run on a machine that has never been configured.

BeforeAll {
    $script:RepoRoot   = Split-Path -Parent $PSScriptRoot
    $script:Fixture    = Join-Path $PSScriptRoot "fixtures\zconfig.fixture.json"
    $script:HelpersPsm = Join-Path $script:RepoRoot "ZHelpers.ps1"

    $env:ZCONFIG = $script:Fixture
    . $script:HelpersPsm
    Reset-ZConfigCache
}

AfterAll {
    Remove-Item Env:\ZCONFIG -ErrorAction SilentlyContinue
}

Describe "Get-ZConfigPath" {
    It "uses the ZCONFIG override when set" {
        $env:ZCONFIG = "C:\somewhere\else.json"
        Get-ZConfigPath | Should -Be "C:\somewhere\else.json"
        $env:ZCONFIG = $script:Fixture
    }

    It "falls back to zconfig.json beside the scripts when ZCONFIG is unset" {
        Remove-Item Env:\ZCONFIG -ErrorAction SilentlyContinue
        Get-ZConfigPath | Should -Be (Join-Path $script:RepoRoot "zconfig.json")
        $env:ZCONFIG = $script:Fixture
    }
}

Describe "Get-ZConfig" {
    BeforeEach { Reset-ZConfigCache }

    It "loads the fixture pointed at by ZCONFIG" {
        (Get-ZConfig).ec2.ip | Should -Be "203.0.113.10"
    }

    It "memoises - a second call returns the same object instance" {
        $a = Get-ZConfig
        $b = Get-ZConfig
        [object]::ReferenceEquals($a, $b) | Should -BeTrue
    }

    It "re-reads after Reset-ZConfigCache" {
        $a = Get-ZConfig
        Reset-ZConfigCache
        $b = Get-ZConfig
        [object]::ReferenceEquals($a, $b) | Should -BeFalse
        $b.ec2.user | Should -Be "testuser"   # still correct content
    }
}

Describe "Get-ZProjectKeys" {
    It "returns every project key in config order" {
        Get-ZProjectKeys | Should -Be @("pyapp", "viteapp", "nextapp", "edgeproxy", "dockeronly", "noports")
    }

    It "omits underscore-prefixed comment keys" {
        Get-ZProjectKeys | Should -Not -Contain "_note"
    }
}

Describe "Get-ZProject" {
    It "returns the project for a known key" {
        (Get-ZProject -Key "pyapp").label | Should -Be "Fixture Python App"
    }

    It "tolerates a leading dash (-pyapp resolves the same as pyapp)" {
        # Muscle memory from per-project switches; every z-script accepts both.
        (Get-ZProject -Key "-pyapp").label | Should -Be "Fixture Python App"
    }

    It "is case-insensitive on the key, as PowerShell property access is" {
        (Get-ZProject -Key "PyApp").label | Should -Be "Fixture Python App"
    }
}

Describe "Get-ZEdgeProject" {
    It "finds the first edge-kind project and reports its key" {
        $edge = Get-ZEdgeProject
        $edge.Key | Should -Be "edgeproxy"
        $edge.Config.proxyContainer | Should -Be "edge_proxy"
    }
}

Describe "Get-RemoteComposeDir" {
    It "prefers remote.composeDir when the project sets one" {
        Get-RemoteComposeDir -Key "pyapp" | Should -Be "/home/testuser/stack/pyapp/docker"
    }

    It "falls back to remote.path when composeDir is absent" {
        Get-RemoteComposeDir -Key "viteapp" | Should -Be "/home/testuser/stack/viteapp"
    }
}

Describe "EC2 target helpers" {
    It "composes user@ip" {
        Get-Ec2Target | Should -Be "testuser@203.0.113.10"
    }

    It "composes the remote home directory from the ssh user" {
        Get-Ec2Home | Should -Be "/home/testuser"
    }
}

Describe "Get-LabelFromBuildJsonObj" {
    It "formats the label as v{productVersion}.{buildNumber}" {
        Get-LabelFromBuildJsonObj ([pscustomobject]@{ productVersion = "1.0"; buildNumber = 42 }) |
            Should -Be "v1.0.42"
    }

    It "returns null for a null object rather than a bare 'v.'" {
        Get-LabelFromBuildJsonObj $null | Should -BeNullOrEmpty
    }

    It "coerces a string buildNumber to int (JSON types vary)" {
        Get-LabelFromBuildJsonObj ([pscustomobject]@{ productVersion = "2.1"; buildNumber = "7" }) |
            Should -Be "v2.1.7"
    }
}

Describe "Read-JsonBuildVersion" {
    BeforeAll {
        $script:TmpDir = Join-Path ([IO.Path]::GetTempPath()) ("zhelptest-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $script:TmpDir -Force | Out-Null
    }
    AfterAll {
        Remove-Item -LiteralPath $script:TmpDir -Recurse -Force -ErrorAction SilentlyContinue
    }

    It "parses a valid build-version.json" {
        $p = Join-Path $script:TmpDir "good.json"
        '{ "productVersion": "3.4", "buildNumber": 11 }' | Set-Content -LiteralPath $p -Encoding UTF8
        (Read-JsonBuildVersion $p).buildNumber | Should -Be 11
    }

    It "returns null for a missing file" {
        Read-JsonBuildVersion (Join-Path $script:TmpDir "nope.json") | Should -BeNullOrEmpty
    }

    It "returns null for malformed JSON instead of throwing" {
        $p = Join-Path $script:TmpDir "bad.json"
        '{ not json at all' | Set-Content -LiteralPath $p -Encoding UTF8
        Read-JsonBuildVersion $p | Should -BeNullOrEmpty
    }
}

Describe "Get-ArchiveExcludes" {
    BeforeAll {
        $script:Py    = Get-ZProject -Key "pyapp"
        $script:Vite  = Get-ZProject -Key "viteapp"
        $script:Next  = Get-ZProject -Key "nextapp"
        $script:Dock  = Get-ZProject -Key "dockeronly"
    }

    Context "common excludes (every kind)" {
        It "always excludes <_>" -ForEach @(".git", ".idea", ".vscode", ".claude", "tmp", "nul", ".DS_Store", "backups") {
            Get-ArchiveExcludes -Project $script:Py | Should -Contain $_
        }

        It "applies the common list even to an unrecognised kind" {
            Get-ArchiveExcludes -Project $script:Dock | Should -Contain ".git"
        }
    }

    Context "python kind" {
        It "excludes build/venv cruft: <_>" -ForEach @(".venv", "venv", "__pycache__", ".pytest_cache", ".nicegui", "archive", "dist", "build", "htmlcov") {
            Get-ArchiveExcludes -Project $script:Py | Should -Contain $_
        }
    }

    Context "vite kind" {
        It "excludes node_modules and dist" {
            $x = Get-ArchiveExcludes -Project $script:Vite
            $x | Should -Contain "node_modules"
            $x | Should -Contain "dist"
        }
    }

    Context "nextjs kind" {
        It "excludes .next, .vercel and build output" {
            $x = Get-ArchiveExcludes -Project $script:Next
            $x | Should -Contain ".next"
            $x | Should -Contain ".vercel"
            $x | Should -Contain "next-env.d.ts"
        }

        It "excludes .env in deploys AND backups (nextjs has no ForBackup gate)" {
            Get-ArchiveExcludes -Project $script:Next -ForBackup | Should -Contain ".env"
        }
    }

    # The regression that motivated this suite: a dev .env shipped to production
    # in a deploy zip. Deploys must drop secrets and uploads; backups must keep
    # them, or the backup is not a full restore point.
    Context "deploy-vs-backup gating (python)" {
        It "deploy excludes secret <_>" -ForEach @(".env", ".env.local", ".env.production") {
            Get-ArchiveExcludes -Project $script:Py | Should -Contain $_
        }

        It "backup KEEPS secret <_>" -ForEach @(".env", ".env.local", ".env.production") {
            Get-ArchiveExcludes -Project $script:Py -ForBackup | Should -Not -Contain $_
        }

        It "deploy excludes user uploads" {
            Get-ArchiveExcludes -Project $script:Py | Should -Contain "uploads"
        }

        It "backup KEEPS user uploads" {
            Get-ArchiveExcludes -Project $script:Py -ForBackup | Should -Not -Contain "uploads"
        }
    }

    Context "deploy-vs-backup gating (vite)" {
        It "deploy excludes secret <_>" -ForEach @(".env", ".env.local", ".env.production") {
            Get-ArchiveExcludes -Project $script:Vite | Should -Contain $_
        }

        It "backup KEEPS secret <_>" -ForEach @(".env", ".env.local", ".env.production") {
            Get-ArchiveExcludes -Project $script:Vite -ForBackup | Should -Not -Contain $_
        }

        It "still excludes node_modules in a backup (bulk, not a secret)" {
            Get-ArchiveExcludes -Project $script:Vite -ForBackup | Should -Contain "node_modules"
        }
    }

    Context "per-project deploy.exclude" {
        It "merges the project's own exclude list" {
            $x = Get-ArchiveExcludes -Project $script:Py
            $x | Should -Contain "docs"
            $x | Should -Contain "fixtures-extra"
        }

        It "omits nothing when the project has no deploy block" {
            { Get-ArchiveExcludes -Project $script:Vite } | Should -Not -Throw
        }
    }

    Context "result shape" {
        It "contains no duplicates" {
            $x = @(Get-ArchiveExcludes -Project $script:Py)
            ($x | Select-Object -Unique).Count | Should -Be $x.Count
        }

        It "returns an array even for a kind with no specific excludes" {
            , (Get-ArchiveExcludes -Project $script:Dock) | Should -BeOfType [System.Array]
        }
    }
}
