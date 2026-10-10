# The token estimate every z-script prints and records.
#
#   Invoke-Pester .\tests
#
# Stop-ZTracking turns a run's output into "~N tokens est." and a ztokens record.
# For two and a half months it divided by 3.5, a prose rule of thumb nobody had
# measured. Anthropic's count_tokens on 8.9M characters of real z-script output
# gave 1.97 characters per token on every current Claude model, so every figure
# was about 44% low - and nothing failed, because an estimate cannot be wrong in
# a way any check looked for.
#
# So these tests pin two things: the ratio stays inside the measured band, so
# it cannot drift back to an unmeasured number unnoticed, and the footer and
# the record both use that one ratio, with the record naming its basis.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) "ZHelpers.ps1")
}

Describe "the characters-per-token ratio" {

    It "is the measured figure, not the old prose heuristic" {
        # 1.79-2.14 across the 60 measured windows; 1.97 overall. If the
        # tokenizer changes, re-measure and move this band with the constant.
        $global:ZCharsPerToken | Should -BeGreaterOrEqual 1.8
        $global:ZCharsPerToken | Should -BeLessOrEqual 2.2
    }

    It "is named in the label every record carries" {
        $global:ZTokenBasis | Should -Be ("est. chars/{0:0.0}" -f $global:ZCharsPerToken)
    }
}

Describe "Stop-ZTracking" {

    BeforeEach {
        $env:ZTOKENS_DATA = Join-Path $TestDrive ("data-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $env:ZTOKENS_DATA | Out-Null
        Remove-Item Env:\ZTOKENS_MODEL -ErrorAction SilentlyContinue
        # Start-ZTracking sweeps leftover transcripts from the temp directory
        #, so point it at a test folder, never the machine's real %TEMP%.
        $script:SavedTmp = $env:TMP, $env:TEMP
        $env:TMP = $env:TEMP = Join-Path $TestDrive ("tmp-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $env:TMP | Out-Null
    }
    AfterEach {
        Remove-Item Env:\ZTOKENS_DATA -ErrorAction SilentlyContinue
        $env:TMP, $env:TEMP = $script:SavedTmp
    }

    It "prints and records the same estimate, at the measured ratio" {
        Start-ZTracking
        Write-Host ("x" * 400)
        $footer = (Stop-ZTracking 6>&1 | Out-String)

        $rec = Get-Content -LiteralPath (Join-Path $env:ZTOKENS_DATA "tokens.jsonl") |
            Select-Object -Last 1 | ConvertFrom-Json

        $rec.chars | Should -BeGreaterThan 400
        $rec.est   | Should -Be ([math]::Round($rec.chars / $global:ZCharsPerToken))
        $rec.model | Should -Be $global:ZTokenBasis
        $footer    | Should -Match ("~{0:N0} tokens est\." -f $rec.est)
    }

    It "would have reported 44% fewer tokens at the old ratio" {
        # The size of the defect, stated once so the comment above stays honest.
        Start-ZTracking
        Write-Host ("x" * 700)
        Stop-ZTracking 6>&1 | Out-Null

        $rec = Get-Content -LiteralPath (Join-Path $env:ZTOKENS_DATA "tokens.jsonl") |
            Select-Object -Last 1 | ConvertFrom-Json
        $old = [math]::Round($rec.chars / 3.5)
        ($old / $rec.est) | Should -BeLessThan 0.6
    }
}
