# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# Sanitization.Tests.ps1 — this repo is public and must stay standalone.
#
# WHY THIS EXISTS
# ---------------
# The toolkit is developed in a private checkout and copied here. Twice in three
# days a wholesale copy landed carrying environment-specific detail: real
# project names, internal hostnames, host disk figures, and references to
# scripts that exist only in the private copy. Each time it was caught by a
# human reading the diff, which is exactly the control that fails when a diff is
# 280 lines of good work with three bad words buried in it.
#
# So it is a test. A copy that reintroduces private detail turns the suite red
# at the moment it happens rather than at review.
#
# WHAT IT CANNOT DO
# -----------------
# This is a denylist, so it proves the absence of KNOWN patterns, not the
# absence of secrets. It is a regression net for a specific recurring mistake -
# not a substitute for reading what you publish. Add a pattern whenever a new
# private identifier appears; the cost of a stale entry is zero.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot

    # Scanned: everything a reader of the published repo can see. Skipped:
    # .git (history is out of scope here), releases/ (published zips are
    # immutable by policy - rewriting one would break its checksum), and this
    # file, which necessarily contains every pattern it looks for.
    $script:Scanned = @(
        Get-ChildItem -LiteralPath $script:RepoRoot -Recurse -File |
            Where-Object {
                $_.Extension -in @('.ps1', '.cmd', '.md', '.txt', '.json', '.bats', '.sh') -and
                $_.FullName -notlike '*\.git\*' -and
                $_.FullName -notlike '*\releases\*' -and
                $_.Name -ne 'Sanitization.Tests.ps1'
            }
    )

    # name        -> what it is, so a failure explains itself
    # pattern     -> regex, case-insensitive
    # Kept narrow on purpose: "evomedia.net" alone is legitimate here (the
    # attribution header and the repo URL), so only the drive path and specific
    # internal hosts are matched.
    $script:Denied = @(
        @{ Name = 'private project name';   Pattern = '\b(EvoCivilCode|EvoPlatform|DocketMail|SmartPlant\w*|ProvenSheet|evoehs|evoproven|evoaicc|evolocate|evoplatform)\b' }
        @{ Name = 'private product domain'; Pattern = '\b(smartplantehs\.com|provensheet\.com|evoehs\.com|civilcode\.evomedia\.net|dashboard\.evomedia\.net|webmail\.evomedia\.net|mail-admin\.evomedia\.net|docketmail\.evomedia\.net|cardiff\.evomedia\.net|platform\.evomedia\.net|ai\.evomedia\.net|git\.evomedia\.net|analytics\.evomedia\.net)\b' }
        @{ Name = 'private-only script';    Pattern = '\b(register_civilcode|register_docketmail|sp_seed_demo_prod|zpublish_stats|zcoverage|zmerge|zpull|zresume|swag_set_owner|provision_demo|apply_platform_config_fixes)\b' }
        @{ Name = 'local drive path';       Pattern = '[A-Za-z]:\\\\?evomedia\.net' }
        @{ Name = 'operator home path';     Pattern = '/home/ubuntu/' }
        @{ Name = 'real pem key name';      Pattern = 'evomedia-prod\.pem' }
        # RFC 5737 reserves 203.0.113.0/24 for documentation - that one is the
        # correct placeholder and must stay allowed, as are loopback and the
        # private ranges. Anything else that looks like a public IPv4 literal is
        # suspect.
        #
        # The boundaries are [\d.] rather than \d on purpose: this toolkit's own
        # 5-segment version (v1.0.0.0.14) contains "0.0.0.14", which a plain
        # digit boundary happily reads as an address. Refusing a match that
        # touches another dot rules out every version string without weakening
        # detection of a real address, which is always delimited by whitespace
        # or quotes.
        @{ Name = 'non-documentation IP';   Pattern = '(?<![\d.])(?!203\.0\.113\.)(?!127\.0\.0\.1)(?!0\.0\.0\.0)(?!255\.)(?!10\.)(?!192\.168\.)(?!172\.(1[6-9]|2\d|3[01])\.)\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}(?![\d.])' }
    )

    function Get-Hits {
        param([string]$Pattern)
        $hits = @()
        foreach ($f in $script:Scanned) {
            $m = Select-String -LiteralPath $f.FullName -Pattern $Pattern -AllMatches -ErrorAction SilentlyContinue
            foreach ($line in $m) {
                $rel = $line.Path.Substring($script:RepoRoot.Length).TrimStart('\')
                $hits += "$rel`:$($line.LineNumber): $($line.Line.Trim())"
            }
        }
        return $hits
    }
}

Describe "public repo carries no private detail" {

    It "finds files to scan at all" {
        # Guards the guard: a bad filter here would make every test below pass
        # vacuously, which is worse than no test.
        $script:Scanned.Count | Should -BeGreaterThan 30
    }

    It "contains no <Name>" -ForEach @(
        @{ Name = 'private project name' }
        @{ Name = 'private product domain' }
        @{ Name = 'private-only script' }
        @{ Name = 'local drive path' }
        @{ Name = 'operator home path' }
        @{ Name = 'real pem key name' }
        @{ Name = 'non-documentation IP' }
    ) {
        $rule = $script:Denied | Where-Object { $_.Name -eq $Name }
        $hits = Get-Hits -Pattern $rule.Pattern
        $hits | Should -BeNullOrEmpty -Because "these look like private detail copied in from the internal toolkit:`n$($hits -join "`n")"
    }

    It "still detects a planted violation" {
        # Mutation check. Without this the suite passes just as happily when the
        # patterns are broken as when the repo is clean - the failure mode that
        # makes a denylist worthless.
        $probe = Join-Path ([IO.Path]::GetTempPath()) ("sanitize-probe-" + [guid]::NewGuid().ToString("N") + ".ps1")
        try {
            Set-Content -LiteralPath $probe -Value '# deploy target /home/ubuntu/stack/example' -Encoding UTF8
            $found = Select-String -LiteralPath $probe -Pattern ($script:Denied | Where-Object { $_.Name -eq 'operator home path' }).Pattern
            $found | Should -Not -BeNullOrEmpty
        }
        finally { Remove-Item -LiteralPath $probe -Force -ErrorAction SilentlyContinue }
    }
}
