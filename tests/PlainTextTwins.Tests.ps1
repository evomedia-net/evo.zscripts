# The .txt twins are generated, and this is what makes that true.
#
#   Invoke-Pester .\tests
#
# scripts/plaintext_twins.py has always shipped a --check mode, and its
# docstring claimed "the test suite runs --check". Nothing ran it. So README.txt
# could drift from README.md silently, and CHANGELOG.txt - which no generator
# covered at all - actually did.
#
# A twin that disagrees with the file it mirrors is worse than no twin: it is a
# second document that looks authoritative and is wrong.

# -Skip is evaluated during DISCOVERY, before BeforeAll runs, so a python
# lookup done in BeforeAll leaves the flag $null and the real check silently
# skips - which is how this test first "passed" while verifying nothing.
BeforeDiscovery {
    $script:Python = $null
    foreach ($candidate in @('python', 'python3', 'py')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { $script:Python = $cmd.Source; break }
    }
}

BeforeAll {
    $script:RepoRoot = Split-Path -Parent $PSScriptRoot
    $script:Generator = Join-Path $script:RepoRoot "scripts\plaintext_twins.py"

    $script:Python = $null
    foreach ($candidate in @('python', 'python3', 'py')) {
        $cmd = Get-Command $candidate -ErrorAction SilentlyContinue
        if ($cmd) { $script:Python = $cmd.Source; break }
    }
}

Describe "plain-text twins" {

    It "the generator is where the tests and the docs say it is" {
        Test-Path -LiteralPath $script:Generator | Should -BeTrue
    }

    # Asks the REPOSITORY what markdown it has, not the generator what it was
    # told about. Scraping the generator's own list could only ever prove the
    # list was self-consistent - a document nobody added to it was invisible to
    # the check, which is how ELEVATOR_PITCH.md and TOKEN_SAVINGS.md sat here
    # with no twin while this test passed.
    It "every .md at the repository root has a twin" {
        $mds = Get-ChildItem -LiteralPath $script:RepoRoot -Filter *.md -File

        $mds.Count | Should -BeGreaterThan 0 -Because "the repo documents itself in markdown"
        foreach ($md in $mds) {
            $txt = [IO.Path]::ChangeExtension($md.FullName, ".txt")
            Test-Path -LiteralPath $txt |
                Should -BeTrue -Because "$($md.Name) owes a twin at $(Split-Path -Leaf $txt)"
        }
    }

    It "every twin is in sync with its markdown" -Skip:(-not $script:Python) {
        Push-Location $script:RepoRoot
        try {
            $output = & $script:Python $script:Generator --check 2>&1
            $code = $LASTEXITCODE
        }
        finally { Pop-Location }

        $code | Should -Be 0 -Because ($output -join "`n")
    }

    It "reports the python that was missing rather than passing quietly" -Skip:([bool]$script:Python) {
        # Not a pass. If this is the test you are reading, --check never ran:
        # install python, or regenerate the twins by hand before shipping.
        Set-ItResult -Inconclusive -Because "no python on PATH, so the twins were not verified"
    }
}
