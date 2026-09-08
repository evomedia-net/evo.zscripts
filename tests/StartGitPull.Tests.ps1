# zstart's auto-pull must never stand between the user and a running server (#130).
#
#   Invoke-Pester .\tests
#
# The report was "I merged it but not sure why it crashed, should have skipped
# it and moved on". It crashed on a pull that SUCCEEDED:
#
#     git : From https://github.com/example/some-app
#     At ZStart.ps1:206 char:24
#     +             $pullOut = git pull --ff-only 2>&1
#
# Under $ErrorActionPreference = 'Stop', a stderr redirect on a native command
# in Windows PowerShell 5.1 wraps every stderr line in a terminating
# ErrorRecord - and git writes ordinary fetch progress ("From ...") to stderr.
# So the try block died before its own "Auto-pull skipped" branch could run.
#
# These tests drive REAL git under 'Stop' on the same host the defect lives
# on. A stand-in that faked git's output would prove nothing about the stream
# semantics that are the entire bug; one test asserts the fixture really does
# put that "From ..." line on stderr, so the reproduction cannot quietly go
# stale the way an LF changelog fixture once did.
#
# ZHelpers.ps1 is dot-sourced rather than ZStart.ps1, which runs its main flow
# on load. That is also why the logic moved into a helper: it was untestable
# where it sat.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) "ZHelpers.ps1")

    $script:tmpRoots = New-Object System.Collections.ArrayList

    function New-TempDir {
        param([string]$Tag)
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("zstart-pull-$Tag-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [void]$script:tmpRoots.Add($dir)
        return $dir
    }

    function Invoke-Git {
        # Test plumbing only. Runs git quietly from a directory and fails the
        # test loudly if it did not work - the thing under test does its own
        # git handling and must not go through here.
        param([string]$In, [string[]]$GitArgs)
        Push-Location -LiteralPath $In
        try {
            $ErrorActionPreference = 'Continue'
            # Quote anything with whitespace: a Windows temp root usually
            # sits under a user profile whose name has a space in it, and
            # an unquoted path splits into two arguments on the way through
            # cmd.
            $quoted = $GitArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
            $out = & cmd /c ("git " + ($quoted -join ' ') + " 2>&1")
            if ($LASTEXITCODE -ne 0) { throw "test plumbing: git $($GitArgs -join ' ') failed in $In`n$out" }
            return $out
        } finally { Pop-Location }
    }

    function New-ClonePair {
        # A bare "origin" and a working clone tracking main, one commit in.
        # Returns @{ Bare; Clone } and leaves a helper to advance origin.
        $bare = New-TempDir 'origin'
        Invoke-Git $bare @('init', '--bare', '--initial-branch=main', '--quiet') | Out-Null
        $seed = New-TempDir 'seed'
        Invoke-Git $seed @('init', '--initial-branch=main', '--quiet') | Out-Null
        Invoke-Git $seed @('config', 'user.email', 'test@example.invalid') | Out-Null
        Invoke-Git $seed @('config', 'user.name', 'zstart test') | Out-Null
        Set-Content -LiteralPath (Join-Path $seed 'a.txt') -Value 'one'
        Invoke-Git $seed @('add', '.') | Out-Null
        Invoke-Git $seed @('commit', '-q', '-m', 'one') | Out-Null
        Invoke-Git $seed @('remote', 'add', 'origin', $bare) | Out-Null
        Invoke-Git $seed @('push', '-q', '-u', 'origin', 'main') | Out-Null

        $clone = New-TempDir 'clone'
        Invoke-Git (Split-Path -Parent $clone) @('clone', '-q', $bare, $clone) | Out-Null
        Invoke-Git $clone @('config', 'user.email', 'test@example.invalid') | Out-Null
        Invoke-Git $clone @('config', 'user.name', 'zstart test') | Out-Null
        return [pscustomobject]@{ Bare = $bare; Clone = $clone; Seed = $seed }
    }

    function Add-OriginCommit {
        # Advance origin from the seed checkout, so the clone has something
        # to fetch - which is exactly what makes git print "From ..." on
        # stderr.
        param($Pair, [string]$Name = 'two')
        Set-Content -LiteralPath (Join-Path $Pair.Seed "$Name.txt") -Value $Name
        Invoke-Git $Pair.Seed @('add', '.') | Out-Null
        Invoke-Git $Pair.Seed @('commit', '-q', '-m', $Name) | Out-Null
        Invoke-Git $Pair.Seed @('push', '-q', 'origin', 'main') | Out-Null
    }

    function Get-Head {
        param([string]$Repo)
        return (Invoke-Git $Repo @('rev-parse', 'HEAD') | Select-Object -Last 1).ToString().Trim()
    }
}

AfterAll {
    foreach ($d in $script:tmpRoots) {
        try { Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue } catch { }
    }
}

Describe "Invoke-StartGitPull" {

    Context "the reported case: origin has new commits" {

        BeforeAll {
            $script:pair = New-ClonePair
            Add-OriginCommit $script:pair
            $script:originTip = Get-Head $script:pair.Seed
        }

        It "the fixture really puts fetch progress on stderr - the shape of the bug" {
            # Checked on a second clone so the one under test is still behind.
            $probe = New-TempDir 'probe'
            Invoke-Git (Split-Path -Parent $probe) @('clone', '-q', $script:pair.Bare, $probe) | Out-Null
            Add-OriginCommit $script:pair 'three'
            Push-Location -LiteralPath $probe
            try {
                $ErrorActionPreference = 'Continue'
                # stderr only: stdout is dropped, so anything captured came
                # from the stream that ErrorRecords are made from.
                $stderr = & cmd /c "git fetch origin 2>&1 1>nul"
            } finally { Pop-Location }
            ($stderr -join "`n") | Should -Match '(?m)^From '
        }

        It "does not abort under ErrorActionPreference = 'Stop'" {
            $ErrorActionPreference = 'Stop'
            { $script:r = Invoke-StartGitPull -Root $script:pair.Clone } | Should -Not -Throw
        }

        It "reports success" {
            $script:r.Ok | Should -BeTrue
            $script:r.Skipped | Should -BeFalse
            $script:r.Message | Should -Match '^Now at: '
        }

        It "actually fast-forwarded the checkout" {
            Get-Head $script:pair.Clone | Should -Be (Get-Head $script:pair.Seed)
        }

        It "leaves the caller's ErrorActionPreference as it found it" {
            $ErrorActionPreference = 'Stop'
            Invoke-StartGitPull -Root $script:pair.Clone | Out-Null
            $ErrorActionPreference | Should -Be 'Stop'
        }
    }

    Context "nothing to fetch" {

        It "is Ok and says so, not a skip" {
            $pair = New-ClonePair
            $ErrorActionPreference = 'Stop'
            $r = Invoke-StartGitPull -Root $pair.Clone
            $r.Ok | Should -BeTrue
            $r.Message | Should -Be 'Already up to date.'
        }
    }

    Context "a pull that cannot complete" {

        It "diverged history is reported, not thrown, and the checkout is left alone" {
            $pair = New-ClonePair
            # Local commit on the clone AND a different one on origin.
            Set-Content -LiteralPath (Join-Path $pair.Clone 'local.txt') -Value 'mine'
            Invoke-Git $pair.Clone @('add', '.') | Out-Null
            Invoke-Git $pair.Clone @('commit', '-q', '-m', 'local') | Out-Null
            $localTip = Get-Head $pair.Clone
            Add-OriginCommit $pair 'theirs'

            $ErrorActionPreference = 'Stop'
            { $script:div = Invoke-StartGitPull -Root $pair.Clone } | Should -Not -Throw
            $script:div.Ok | Should -BeFalse
            $script:div.Skipped | Should -BeFalse
            $script:div.Message | Should -Match 'cannot fast-forward'
            Get-Head $pair.Clone | Should -Be $localTip
        }

        It "a branch with no upstream is skipped - and never switched away from" {
            $pair = New-ClonePair
            Invoke-Git $pair.Clone @('checkout', '-q', '-b', 'feature/thing') | Out-Null
            $ErrorActionPreference = 'Stop'
            { $script:noup = Invoke-StartGitPull -Root $pair.Clone } | Should -Not -Throw
            $script:noup.Skipped | Should -BeTrue
            $script:noup.Message | Should -Match "no upstream"
            (Invoke-Git $pair.Clone @('rev-parse', '--abbrev-ref', 'HEAD') | Select-Object -Last 1).ToString().Trim() |
                Should -Be 'feature/thing'
        }

        It "a directory that is not a repo is skipped, not thrown" {
            $dir = New-TempDir 'norepo'
            $ErrorActionPreference = 'Stop'
            { $script:norepo = Invoke-StartGitPull -Root $dir } | Should -Not -Throw
            $script:norepo.Skipped | Should -BeTrue
            $script:norepo.Message | Should -Match 'not a git repo'
        }
    }

    Context "housekeeping" {

        It "restores GIT_TERMINAL_PROMPT to whatever it was" {
            $pair = New-ClonePair
            $prev = $env:GIT_TERMINAL_PROMPT
            try {
                $env:GIT_TERMINAL_PROMPT = 'sentinel'
                Invoke-StartGitPull -Root $pair.Clone | Out-Null
                $env:GIT_TERMINAL_PROMPT | Should -Be 'sentinel'
            } finally { $env:GIT_TERMINAL_PROMPT = $prev }
        }

        It "returns to the directory it was called from" {
            $pair = New-ClonePair
            $here = (Get-Location).Path
            Invoke-StartGitPull -Root $pair.Clone | Out-Null
            (Get-Location).Path | Should -Be $here
        }
    }
}

Describe "ZStart.ps1 uses the helper" {

    BeforeAll {
        $script:zstart = Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) "ZStart.ps1")
    }

    It "no longer carries its own redirected pull - the line that crashed" {
        $script:zstart | Should -Not -Match 'git pull --ff-only 2>&1'
    }

    It "calls Invoke-StartGitPull" {
        $script:zstart | Should -Match 'Invoke-StartGitPull -Root'
    }

    It "still tells the user when it skipped, and how to stop it trying" {
        $script:zstart | Should -Match 'Auto-pull skipped'
        $script:zstart | Should -Match 'start\.gitPull=false'
    }
}
