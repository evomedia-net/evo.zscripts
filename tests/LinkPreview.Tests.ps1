# evomedia.net Token Savers - https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels - dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# LinkPreview.Tests.ps1 - the public page renders a card, not a bare URL.
#
#   Invoke-Pester .\tests
#
# Pasting zscripts.evomedia.net into LinkedIn, Slack or a message builds a card
# from the page's og:* tags. The page had a title and a description and nothing
# else, so it pasted as a bare URL.
#
# None of that is visible from here. The page is correct, the site is up, and
# the only symptom is a card somewhere else - which is why the rule is asserted
# rather than remembered.
#
# The last test is the one that earned its place: the first draft of the card
# showed `ztests`, which is not a command in this repo. A card is public copy,
# and public copy must not advertise a script that does not exist.

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Page = Join-Path $script:RepoRoot "site\index.html"
    $script:Card = Join-Path $script:RepoRoot "site\og-card.png"
    $script:Html = [IO.File]::ReadAllText($script:Page)

    function Get-Meta {
        param([string]$Key)
        $pattern = '<meta (?:property|name)="' + [regex]::Escape($Key) + '" content="([^"]*)">'
        $m = [regex]::Match($script:Html, $pattern)
        if ($m.Success) { return $m.Groups[1].Value }
        return $null
    }
}

Describe "zscripts.evomedia.net link preview" {

    It "carries the tags a card is built from" {
        foreach ($key in @('og:type', 'og:url', 'og:title', 'og:description', 'og:image')) {
            Get-Meta $key | Should -Not -BeNullOrEmpty -Because "$key is what the card is made of"
        }
        # Without it X renders the small square variant instead of a card.
        Get-Meta 'twitter:card' | Should -Be 'summary_large_image'
    }

    It "gives absolute URLs, which the strict crawlers require" {
        foreach ($key in @('og:url', 'og:image', 'twitter:image')) {
            Get-Meta $key | Should -Match '^https://'
        }
    }

    It "points og:url at the same place as the canonical" {
        $canonical = [regex]::Match($script:Html, '<link rel="canonical" href="([^"]*)">')
        $canonical.Success | Should -BeTrue
        Get-Meta 'og:url' | Should -Be $canonical.Groups[1].Value
    }

    It "publishes the card beside the page" {
        # site/ is copied to the server wholesale; a card outside it is a 404
        # and the preview falls back to text.
        Test-Path -LiteralPath $script:Card | Should -BeTrue
    }

    It "serves a card that is the size the tags claim" {
        # PNG header: width and height are big-endian at offsets 16 and 20.
        $bytes = [IO.File]::ReadAllBytes($script:Card)[0..23]
        $width = [int]$bytes[16] * 16777216 + [int]$bytes[17] * 65536 + [int]$bytes[18] * 256 + [int]$bytes[19]
        $height = [int]$bytes[20] * 16777216 + [int]$bytes[21] * 65536 + [int]$bytes[22] * 256 + [int]$bytes[23]
        $width | Should -Be 1200
        $height | Should -Be 630
        Get-Meta 'og:image:width' | Should -Be '1200'
        Get-Meta 'og:image:height' | Should -Be '630'
    }

    It "does not advertise a command this repo does not ship" {
        $alt = Get-Meta 'og:image:alt'
        $alt | Should -Not -BeNullOrEmpty

        $named = [regex]::Matches($alt, '\bz[a-z_]+\b') | ForEach-Object { $_.Value } | Sort-Object -Unique
        $named.Count | Should -BeGreaterThan 0 -Because 'the alt text names the commands on the card'

        foreach ($cmd in $named) {
            if ($cmd -eq 'zscripts') { continue }  # the toolkit, not a command
            $exists = @('.ps1', '.cmd') | Where-Object {
                Test-Path -LiteralPath (Join-Path $script:RepoRoot "$cmd$_")
            }
            $exists | Should -Not -BeNullOrEmpty -Because "$cmd is on the card but is not in this repo"
        }
    }
}
