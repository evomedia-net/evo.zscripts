# zdeploy lays the release tag it already knows the number for.
#
#   Invoke-Pester .\tests
#
# A versioning scheme that asks every release to lay an annotated tag needs
# something to enforce it. For a project whose build number lives OUTSIDE git -
# in a database, say - nothing did, and one project reached thirty-eight builds
# with four tags. Those builds were not recoverable: the number only ever
# existed in the database.
#
# These tests drive REAL git against a real bare remote in a temp directory,
# the way StartGitPull.Tests.ps1 does. A stand-in that faked git would prove
# nothing about the two properties that matter most here: that the tag is
# annotated and pushed, and that NOTHING this function does can fail a deploy
# which already reached production.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) "ZHelpers.ps1")

    $script:tmpRoots = New-Object System.Collections.ArrayList

    function New-TempDir {
        param([string]$Tag)
        $dir = Join-Path ([IO.Path]::GetTempPath()) ("zdeploy-tag-$Tag-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        [void]$script:tmpRoots.Add($dir)
        return $dir
    }

    function Invoke-Git {
        # Test plumbing only. The thing under test does its own git handling
        # and must not go through here.
        param([string]$In, [string[]]$GitArgs)
        Push-Location -LiteralPath $In
        try {
            $ErrorActionPreference = 'Continue'
            $quoted = $GitArgs | ForEach-Object { if ($_ -match '\s') { '"' + $_ + '"' } else { $_ } }
            $out = & cmd /c ("git " + ($quoted -join ' ') + " 2>&1")
            if ($LASTEXITCODE -ne 0) { throw "test plumbing: git $($GitArgs -join ' ') failed in $In`n$out" }
            return $out
        }
        finally { Pop-Location }
    }

    function New-RepoWithRemote {
        param([string]$Tag)
        $remote = New-TempDir "$Tag-remote"
        Invoke-Git -In $remote -GitArgs @('init', '--bare', '-q') | Out-Null
        $work = New-TempDir "$Tag-work"
        Invoke-Git -In $work -GitArgs @('init', '-q', '-b', 'main') | Out-Null
        Invoke-Git -In $work -GitArgs @('config', 'user.email', 'test@example.com') | Out-Null
        Invoke-Git -In $work -GitArgs @('config', 'user.name', 'Test') | Out-Null
        Set-Content -LiteralPath (Join-Path $work 'app.txt') -Value 'v1' -Encoding utf8
        Invoke-Git -In $work -GitArgs @('add', '-A') | Out-Null
        Invoke-Git -In $work -GitArgs @('commit', '-q', '-m', 'first') | Out-Null
        Invoke-Git -In $work -GitArgs @('remote', 'add', 'origin', $remote) | Out-Null
        Invoke-Git -In $work -GitArgs @('push', '-q', '-u', 'origin', 'main') | Out-Null
        return @{ Work = $work; Remote = $remote }
    }

    function New-Proj {
        param([string]$Root, $TagOnDeploy = $true)
        $deploy = if ($null -eq $TagOnDeploy) {
            [pscustomobject]@{ zipName = 'X.zip' }
        } else {
            [pscustomobject]@{ zipName = 'X.zip'; tagOnDeploy = $TagOnDeploy }
        }
        return [pscustomobject]@{ localRoot = $Root; deploy = $deploy }
    }

    function Get-Tags {
        param([string]$In)
        $out = Invoke-Git -In $In -GitArgs @('tag', '--list')
        return @($out | Where-Object { $_ -and $_.ToString().Trim() } |
                 ForEach-Object { $_.ToString().Trim() })
    }
}

AfterAll {
    foreach ($d in $script:tmpRoots) {
        Remove-Item -LiteralPath $d -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Describe 'New-DeployTag' {

    It 'tags the deployed commit and pushes it' {
        $r = New-RepoWithRemote 'happy'
        New-DeployTag -Proj (New-Proj $r.Work) -Version 'v0.0.1.0.39' -Note 'Build deployed'

        Get-Tags -In $r.Work | Should -Contain 'v0.0.1.0.39'
        # On the remote too: a tag only in the local checkout is not a record.
        $remoteTags = Invoke-Git -In $r.Work -GitArgs @('ls-remote', '--tags', 'origin')
        ($remoteTags -join "`n") | Should -Match 'refs/tags/v0\.0\.1\.0\.39'
    }

    It 'writes an ANNOTATED tag carrying the version and the note' {
        $r = New-RepoWithRemote 'annotated'
        New-DeployTag -Proj (New-Proj $r.Work) -Version 'v1.2.3.4.5' -Note 'Ask AI sources'

        # cat-file says "tag" for an annotated object and "commit" for a
        # lightweight one. The scheme asks for annotated.
        $type = Invoke-Git -In $r.Work -GitArgs @('cat-file', '-t', 'v1.2.3.4.5')
        ($type -join '').Trim() | Should -Be 'tag'
        $msg = Invoke-Git -In $r.Work -GitArgs @('tag', '-l', 'v1.2.3.4.5', '--format=%(contents)')
        ($msg -join ' ') | Should -Match 'v1\.2\.3\.4\.5'
        ($msg -join ' ') | Should -Match 'Ask AI sources'
    }

    It 'points the tag at the commit that was deployed' {
        $r = New-RepoWithRemote 'sha'
        $head = (Invoke-Git -In $r.Work -GitArgs @('rev-parse', 'HEAD') -join '').Trim()
        New-DeployTag -Proj (New-Proj $r.Work) -Version 'v9.9.9.9.9'
        $tagged = (Invoke-Git -In $r.Work -GitArgs @('rev-list', '-n', '1', 'v9.9.9.9.9') -join '').Trim()
        $tagged | Should -Be $head
    }

    It 'does nothing at all unless the project opts in' {
        $r = New-RepoWithRemote 'optout'
        New-DeployTag -Proj (New-Proj $r.Work -TagOnDeploy $false) -Version 'v0.0.0.0.1'
        Get-Tags -In $r.Work | Should -BeNullOrEmpty

        # And when the key is absent entirely, which is every existing project.
        New-DeployTag -Proj (New-Proj $r.Work -TagOnDeploy $null) -Version 'v0.0.0.0.2'
        Get-Tags -In $r.Work | Should -BeNullOrEmpty
    }

    It 'leaves an existing tag alone rather than failing a redeploy' {
        $r = New-RepoWithRemote 'exists'
        New-DeployTag -Proj (New-Proj $r.Work) -Version 'v0.0.1.0.40' -Note 'first'
        { New-DeployTag -Proj (New-Proj $r.Work) -Version 'v0.0.1.0.40' -Note 'second' } |
            Should -Not -Throw
        $msg = Invoke-Git -In $r.Work -GitArgs @('tag', '-l', 'v0.0.1.0.40', '--format=%(contents)')
        ($msg -join ' ') | Should -Match 'first'
        ($msg -join ' ') | Should -Not -Match 'second'
    }

    It 'never throws when the directory is not a git repo' {
        $plain = New-TempDir 'notrepo'
        { New-DeployTag -Proj (New-Proj $plain) -Version 'v0.0.0.0.3' } | Should -Not -Throw
    }

    It 'never throws when the push fails, and still writes the tag locally' {
        # A deploy that reached production must not be reported as failed
        # because a tag could not leave the machine.
        $r = New-RepoWithRemote 'badremote'
        Invoke-Git -In $r.Work -GitArgs @('remote', 'set-url', 'origin',
                                          (Join-Path ([IO.Path]::GetTempPath()) 'no-such-remote-zz')) | Out-Null
        { New-DeployTag -Proj (New-Proj $r.Work) -Version 'v0.0.1.0.41' } | Should -Not -Throw
        Get-Tags -In $r.Work | Should -Contain 'v0.0.1.0.41'
    }

    It 'survives the deploy-wide ErrorActionPreference of Stop' {
        # The trap this whole file documents: under 'Stop', PS 5.1 turns any
        # native stderr line into a terminating error. git push writes its
        # ordinary progress to stderr, so a tag that works interactively can
        # still kill a deploy.
        $r = New-RepoWithRemote 'stoppref'
        $ErrorActionPreference = 'Stop'
        { New-DeployTag -Proj (New-Proj $r.Work) -Version 'v0.0.1.0.42' } | Should -Not -Throw
        Get-Tags -In $r.Work | Should -Contain 'v0.0.1.0.42'
    }
}

Describe 'Get-DeployStampFiles' {

    It 'covers every changelog name the fleet actually writes' {
        # The old inline copy knew CHANGELOG.md and not build_changelog.md,
        # a name a project's own changelog tool may write - so that stamp
        # counted as unreviewed source in the branch guard.
        $stamps = Get-DeployStampFiles
        $stamps | Should -Contain 'build-version.json'
        $stamps | Should -Contain 'CHANGELOG.md'
        $stamps | Should -Contain 'build_changelog.md'
    }

    It 'does not count a stamp the deploy just wrote as an uncommitted change' {
        $r = New-RepoWithRemote 'stamps'
        Set-Content -LiteralPath (Join-Path $r.Work 'build_changelog.md') -Value 'x' -Encoding utf8
        Invoke-Git -In $r.Work -GitArgs @('add', '-A') | Out-Null
        Invoke-Git -In $r.Work -GitArgs @('commit', '-q', '-m', 'add changelog') | Out-Null
        Set-Content -LiteralPath (Join-Path $r.Work 'build_changelog.md') -Value 'stamped by the deploy' -Encoding utf8

        Push-Location -LiteralPath $r.Work
        try { $changes = Get-TrackedChangesExcludingStamps } finally { Pop-Location }
        $changes.Count | Should -Be 0
    }

    It 'still reports real source changes' {
        $r = New-RepoWithRemote 'realchange'
        Set-Content -LiteralPath (Join-Path $r.Work 'app.txt') -Value 'edited' -Encoding utf8
        Push-Location -LiteralPath $r.Work
        try { $changes = Get-TrackedChangesExcludingStamps } finally { Pop-Location }
        $changes.Count | Should -Be 1
        ($changes -join ' ') | Should -Match 'app\.txt'
    }
}
