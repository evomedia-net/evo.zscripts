# Tracking ends on every exit, and leaves no transcript behind.
#
#   Invoke-Pester .\tests
#
# Start-ZTracking starts a transcript; only Stop-ZTracking stops and deletes it,
# and scripts called that only on the paths that reached it. A terminating error
# or Ctrl+C left the transcript recording the rest of the window - every later
# command and its output - in a %TEMP% file nothing deleted. 874 of them, 343 MB,
# had piled up, the largest 13.8 MB, and none of those runs reached ztokens.
#
# The fix has two halves, and each is tested here:
#  - every tracked script runs its body in try/finally (the static test below
#    reads every script, so a new one cannot ship without it);
#  - Start-ZTracking clears leftovers: this window's unstopped transcript, and
#    files whose process has ended - never a live run's.
#
# Ctrl+C itself is not simulated: a finally block runs on it by definition
# (about_Try_Catch_Finally), so the static test is what covers it.
#
# Transcripts run in child processes with TMP pointed at a test folder, so the
# real %TEMP% and the test runner's own session are never touched.

BeforeAll {
    $script:Root    = Split-Path -Parent $PSScriptRoot
    $script:Helpers = Join-Path $script:Root "ZHelpers.ps1"

    # Run a script in a fresh PowerShell with its own TMP and ztokens store.
    # Returns the process exit code, the transcripts left, and the records.
    function Invoke-Isolated([string]$Body) {
        $dir  = Join-Path $TestDrive ([guid]::NewGuid().ToString("N"))
        $tmp  = Join-Path $dir "tmp";  New-Item -ItemType Directory -Path $tmp  | Out-Null
        $data = Join-Path $dir "data"; New-Item -ItemType Directory -Path $data | Out-Null
        $file = Join-Path $dir "fixture.ps1"
        Set-Content -LiteralPath $file -Value $Body -Encoding UTF8
        $saved = @{ TMP = $env:TMP; TEMP = $env:TEMP; ZTOKENS_DATA = $env:ZTOKENS_DATA }
        try {
            $env:TMP = $tmp; $env:TEMP = $tmp; $env:ZTOKENS_DATA = $data
            $out = & powershell -NoProfile -ExecutionPolicy Bypass -File $file 2>&1 | Out-String
            $code = $LASTEXITCODE
        }
        finally {
            $env:TMP = $saved.TMP; $env:TEMP = $saved.TEMP; $env:ZTOKENS_DATA = $saved.ZTOKENS_DATA
        }
        $records = @()
        $jsonl = Join-Path $data "tokens.jsonl"
        if (Test-Path -LiteralPath $jsonl) { $records = @(Get-Content -LiteralPath $jsonl | ForEach-Object { $_ | ConvertFrom-Json }) }
        return [pscustomobject]@{
            Code    = $code
            Output  = $out
            Left    = @(Get-ChildItem -LiteralPath $tmp -Filter "_ztrack_*.txt" -File)
            Records = $records
            Tmp     = $tmp
        }
    }

    function Fixture([string]$Inside) {
        return @"
. '$script:Helpers'
Start-ZTracking
try {
Write-Host 'working'
$Inside
} finally { Stop-ZTracking -IfActive }
"@
    }
}

Describe "every tracked script ends tracking in a finally" {

    It "wraps everything after Start-ZTracking in try { } finally { Stop-ZTracking -IfActive }" {
        # Scripts that CALL Start-ZTracking - read from the parse tree, so a
        # comment that only mentions it does not count.
        $tracked = @(Get-ChildItem -LiteralPath $script:Root -Filter *.ps1 -File |
            Where-Object {
                $a = [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$null, [ref]$null)
                $_.Name -ne "ZHelpers.ps1" -and $a.Find({ param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq "Start-ZTracking" }, $true)
            })
        $tracked.Count | Should -BeGreaterThan 10

        $unwrapped = foreach ($f in $tracked) {
            $ast   = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$null)
            $stmts = @($ast.EndBlock.Statements)
            $si    = -1
            for ($i = 0; $i -lt $stmts.Count; $i++) { if ($stmts[$i].Extent.Text -eq "Start-ZTracking") { $si = $i } }
            $rest  = @($stmts | Select-Object -Skip ($si + 1))
            $ok = $si -ge 0 -and $rest.Count -eq 1 -and
                  $rest[0] -is [System.Management.Automation.Language.TryStatementAst] -and
                  $rest[0].Finally -and $rest[0].Finally.Extent.Text -match "Stop-ZTracking -IfActive"
            if (-not $ok) { $f.Name }
        }
        $unwrapped | Should -BeNullOrEmpty -Because "a script whose body can leave without Stop-ZTracking leaks its transcript"
    }
}

Describe "a run that leaves early" {

    It "stops and deletes its transcript, and is still recorded, when it throws" {
        $r = Invoke-Isolated (Fixture "throw 'boom'")
        $r.Code         | Should -Not -Be 0
        $r.Left         | Should -BeNullOrEmpty
        $r.Records.Count | Should -Be 1
        $r.Output       | Should -Match "tokens est\."
    }

    It "keeps the exit code, and prints the footer once, when it exits early" {
        $r = Invoke-Isolated (Fixture "exit 3")
        $r.Code  | Should -Be 3
        $r.Left  | Should -BeNullOrEmpty
        $r.Records.Count | Should -Be 1
        ([regex]::Matches($r.Output, "tokens est\.")).Count | Should -Be 1
    }

    It "does not stop tracking twice when the script already stopped it" {
        $r = Invoke-Isolated (Fixture "Stop-ZTracking; exit 1")
        $r.Code  | Should -Be 1
        $r.Left  | Should -BeNullOrEmpty
        $r.Records.Count | Should -Be 1
        ([regex]::Matches($r.Output, "tokens est\.")).Count | Should -Be 1
    }

    It "leaked before the fix - the shape the static test guards against" {
        # The same throw without the finally: the check above must be able to fail.
        $r = Invoke-Isolated (". '$script:Helpers'`nStart-ZTracking`nWrite-Host 'working'`nthrow 'boom'`nStop-ZTracking")
        $r.Left.Count    | Should -Be 1
        $r.Records.Count | Should -Be 0
    }
}

Describe "Start-ZTracking clears leftovers" {

    It "stops and deletes a transcript this window left running" {
        # A run that never stopped: a transcript still recording this process.
        # Reloading ZHelpers resets $global:_ZTrackPath, as the next z-script does,
        # so the cleanup cannot rely on it.
        $r = Invoke-Isolated @"
`$leak = Join-Path ([IO.Path]::GetTempPath()) '_ztrack_leaked.txt'
Start-Transcript -Path `$leak | Out-Null
Write-Host 'an earlier run that never stopped'
. '$script:Helpers'
Start-ZTracking
try {
Write-Host 'the next run'
} finally { Stop-ZTracking -IfActive }
`$still = `$true
try { Stop-Transcript | Out-Null } catch { `$still = `$false }
Write-Host "STILL-TRANSCRIBING=`$still"
"@
        $r.Left   | Should -BeNullOrEmpty
        $r.Output | Should -Match "STILL-TRANSCRIBING=False"
    }

    It "deletes another process's ended transcript once it is an hour old, and leaves a newer one" {
        $r = Invoke-Isolated @"
foreach (`$n in 'old', 'new') {
    `$p = Join-Path ([IO.Path]::GetTempPath()) "_ztrack_`$n.txt"
    Set-Content -LiteralPath `$p -Value "**********************`nProcess ID: 999999`n**********************"
}
(Get-Item (Join-Path ([IO.Path]::GetTempPath()) '_ztrack_old.txt')).LastWriteTime = (Get-Date).AddHours(-2)
. '$script:Helpers'
Clear-ZTrackLeftovers
"@
        @($r.Left | ForEach-Object Name) | Should -Be @("_ztrack_new.txt")
    }

    It "never deletes a transcript another live process holds open" {
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString("N")); New-Item -ItemType Directory -Path $dir | Out-Null
        $held = Join-Path $dir "_ztrack_live.txt"
        Set-Content -LiteralPath $held -Value "Process ID: 999999"
        (Get-Item -LiteralPath $held).LastWriteTime = (Get-Date).AddHours(-2)
        $fs = [IO.File]::Open($held, 'Open', 'ReadWrite', 'ReadWrite')   # no Delete share, as a live transcript
        $saved = $env:TMP
        try {
            $env:TMP = $dir
            & powershell -NoProfile -Command ". '$script:Helpers'; Clear-ZTrackLeftovers" | Out-Null
        }
        finally { $env:TMP = $saved; $fs.Dispose() }
        Test-Path -LiteralPath $held | Should -BeTrue
    }
}

Describe "Stop-ZTracking -IfActive" {

    It "is silent when nothing is being tracked" {
        . $script:Helpers
        $global:_ZTrackPath = $null
        # Count records, not text: the trailer is two blank lines, which a
        # trimmed string would hide.
        @(Stop-ZTracking -IfActive 6>&1).Count | Should -Be 0
    }
}
