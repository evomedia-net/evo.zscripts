# Evomedia.net Token Savers - https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels - dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# Checksums.Tests.ps1 - keeps CHECKSUMS.txt honest.
#
#   Invoke-Pester .\tests
#
# A checksum manifest is worse than useless once it drifts: it either cries wolf
# on every run until people stop reading it, or it quietly stops covering a new
# script. These tests fail the moment the manifest and the scripts disagree, so
# "forgot to run zchecksums -Update" surfaces here rather than in a user's
# verification run.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Manifest = Join-Path $script:RepoRoot "CHECKSUMS.txt"

    # Same set zchecksums.ps1 covers: top-level executables.
    $script:Covered = @(
        Get-ChildItem -LiteralPath $script:RepoRoot -File |
            Where-Object { $_.Extension -in @('.ps1', '.cmd') } |
            Sort-Object Name
    )

    $script:Listed = [ordered]@{}
    if (Test-Path -LiteralPath $script:Manifest) {
        foreach ($line in [IO.File]::ReadAllLines($script:Manifest)) {
            if ($line -match '^([0-9a-fA-F]{64})\s+(.+)$') {
                $script:Listed[$Matches[2].Trim()] = $Matches[1].ToLowerInvariant()
            }
        }
    }
}

Describe "CHECKSUMS.txt" {
    It "exists" {
        Test-Path -LiteralPath $script:Manifest | Should -BeTrue
    }

    # NOTE: no angle brackets in It names - Pester treats them as -ForEach data
    # placeholders and tries to evaluate the contents as an expression.
    It "is sha256sum-compatible: 64 hex chars, two spaces, then the filename" {
        # Anything else and `sha256sum -c CHECKSUMS.txt` warns or bails, which
        # is half the point of publishing it.
        foreach ($line in [IO.File]::ReadAllLines($script:Manifest)) {
            if (-not $line.Trim()) { continue }
            $line | Should -Match '^[0-9a-f]{64}  \S.*$'
        }
    }

    It "uses LF line endings" {
        # A trailing CR becomes part of the filename for sha256sum, so every
        # entry would report as missing on Linux/macOS.
        ([IO.File]::ReadAllText($script:Manifest)) | Should -Not -Match "`r"
    }

    It "is sorted by filename" {
        $names = @($script:Listed.Keys)
        ($names -join ',') | Should -Be (($names | Sort-Object) -join ',')
    }
}

Describe "manifest matches what is on disk" {
    It "lists every top-level .ps1 / .cmd (nothing silently uncovered)" {
        $missingFromManifest = @($script:Covered.Name | Where-Object { -not $script:Listed.Contains($_) })
        $missingFromManifest -join ', ' | Should -BeNullOrEmpty -Because "these scripts are not in CHECKSUMS.txt - run 'zchecksums -Update'"
    }

    It "lists nothing that no longer exists" {
        $onDisk = @($script:Covered.Name)
        $stale = @($script:Listed.Keys | Where-Object { $onDisk -notcontains $_ })
        $stale -join ', ' | Should -BeNullOrEmpty -Because "these entries point at files that are gone - run 'zchecksums -Update'"
    }

    It "records the current hash of <_>" -ForEach @(
        (Get-ChildItem -LiteralPath (Split-Path -Parent $PSScriptRoot) -File |
            Where-Object { $_.Extension -in @('.ps1', '.cmd') } |
            Sort-Object Name | Select-Object -ExpandProperty Name)
    ) {
        $name = $_
        $script:Listed.Contains($name) | Should -BeTrue -Because "$name is missing from CHECKSUMS.txt"
        $actual = (Get-FileHash -LiteralPath (Join-Path $script:RepoRoot $name) -Algorithm SHA256).Hash.ToLowerInvariant()
        $actual | Should -Be $script:Listed[$name] -Because "$name changed since CHECKSUMS.txt was written - run 'zchecksums -Update'"
    }
}

Describe "zchecksums.ps1" {
    It "verifies clean and exits 0 against the committed manifest" {
        $out = & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepoRoot "zchecksums.ps1") -Quiet 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($out -join "`n")
    }

    It "exits non-zero when a covered file has been tampered with" {
        # Proves the check actually detects a modified script rather than always
        # passing. Appends a byte to a real script, verifies, then restores it.
        $victim = Join-Path $script:RepoRoot "zchecksums.cmd"
        $original = [IO.File]::ReadAllBytes($victim)
        try {
            [IO.File]::AppendAllText($victim, "REM tampered`r`n")
            & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepoRoot "zchecksums.ps1") -Quiet *> $null
            $LASTEXITCODE | Should -Be 1
        }
        finally {
            [IO.File]::WriteAllBytes($victim, $original)
        }
        # Restored, so a normal verify passes again.
        & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $script:RepoRoot "zchecksums.ps1") -Quiet *> $null
        $LASTEXITCODE | Should -Be 0
    }
}
