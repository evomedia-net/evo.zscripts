# evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# zkill says what it could not stop, and why.
#
#   Invoke-Pester .\tests
#
# On 2026-11-26 `zkill <project> -port 8090` was run from an admin
# PowerShell over a branch review server that a Remote Control boot session
# had started in session 0. zkill printed
#
#     Killing PID 23180 (python)
#     1 process(es) stopped
#
# and the server went on answering. Stop-Process had been refused ("Access is
# denied") under -ErrorAction SilentlyContinue, and the count went up anyway.
# taskkill /F in the same window then stopped it. Kelly: "plz have it show
# errors like access denied, if possible". These tests hold:
#
#   * a process that does stop is counted stopped, and is gone - a real one;
#   * a refused Stop-Process falls back to taskkill /F, and counts as stopped
#     only when taskkill actually ends it;
#   * a process neither can stop is counted failed, with Windows' reason from
#     both printed, and the session-0 and not-elevated hints;
#   * a tree adds up what went and what did not;
#   * zkill, run for real against a listener, reports only what it stopped,
#     and exits 1 when anything is left running, so zrestart stops.
#
# A refusal cannot be staged without a second sign-in, so the refused paths
# mock Stop-Process and taskkill with the messages Windows gave on the day.

BeforeAll {
    $scripts = Split-Path -Parent $PSScriptRoot
    . (Join-Path $scripts "ZHelpers.ps1")
    $script:ZKillOnly = Join-Path $scripts "ZKillOnly.ps1"

    function Start-Sleeper {
        Start-Process -FilePath powershell.exe -WindowStyle Hidden -PassThru `
            -ArgumentList '-NoProfile', '-Command', 'Start-Sleep -Seconds 120'
    }
}

Describe 'Stop-OneProcess' {
    It 'stops a real process and counts it only once it is gone' {
        $p = Start-Sleeper
        try {
            Stop-OneProcess -TargetPid $p.Id -Name 'powershell' | Should -BeTrue
            Get-Process -Id $p.Id -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        } finally {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }

    Context 'when Windows refuses Stop-Process' {
        BeforeEach {
            $script:alive = $true
            $script:said = [System.Collections.Generic.List[string]]::new()
            Mock Stop-Process { throw 'Cannot stop process "python (4242)" because of the following error: Access is denied' }
            Mock Get-Process { if ($script:alive) { [pscustomobject]@{ Id = 4242; ProcessName = 'python'; SessionId = 0 } } }
            Mock Start-Sleep {}
            Mock Write-Host { $script:said.Add([string]$Object) }
            Mock Test-IsElevated { $true }
        }

        It 'falls back to taskkill /F, and counts it stopped when that ends it' {
            Mock Invoke-TaskKill {
                $script:alive = $false
                [pscustomobject]@{ ExitCode = 0; Output = 'SUCCESS: The process with PID 4242 has been terminated.' }
            }
            Stop-OneProcess -TargetPid 4242 -Name 'python' | Should -BeTrue
            Should -Invoke Invoke-TaskKill -Times 1 -Exactly
            ($script:said -join "`n") | Should -Match 'Stop-Process was refused; taskkill /F stopped it'
        }

        It 'counts it failed, and prints both reasons, when taskkill is refused too' {
            Mock Invoke-TaskKill {
                [pscustomobject]@{ ExitCode = 1; Output = 'ERROR: The process with PID 4242 could not be terminated. Reason: Access is denied.' }
            }
            Stop-OneProcess -TargetPid 4242 -Name 'python' | Should -BeFalse
            $out = $script:said -join "`n"
            $out | Should -Match 'Could not stop PID 4242 \(python\) - it is still running'
            $out | Should -Match 'Stop-Process: .*Access is denied'
            $out | Should -Match 'taskkill: ERROR: .* Reason: Access is denied\.'
            $out | Should -Match 'session 0'
            $out | Should -Not -Match 'not elevated'
        }

        It 'tells a window that is not elevated to try an admin one' {
            Mock Invoke-TaskKill { [pscustomobject]@{ ExitCode = 1; Output = 'ERROR: Reason: Access is denied.' } }
            Mock Test-IsElevated { $false }
            Stop-OneProcess -TargetPid 4242 -Name 'python' | Should -BeFalse
            ($script:said -join "`n") | Should -Match 'not elevated\. Run zkill again from an admin PowerShell'
        }

        It 'does not wait for a refused process before trying taskkill' {
            Mock Invoke-TaskKill { [pscustomobject]@{ ExitCode = 1; Output = 'ERROR: Reason: Access is denied.' } }
            Stop-OneProcess -TargetPid 4242 -Name 'python' | Should -BeFalse
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }
}

Describe 'Invoke-TaskKill' {
    It 'keeps taskkill''s own message on one line, and its exit code' {
        # No process has PID 0x7FFFFFFC; taskkill says so on stderr and exits 128.
        $r = Invoke-TaskKill -TargetPid 2147483644
        $r.ExitCode | Should -Not -Be 0
        $r.Output | Should -Match '^ERROR: .*2147483644'
        $r.Output | Should -Not -Match "`n"
    }
}

Describe 'Stop-ProcessTree' {
    It 'adds up what went and what would not, children first' {
        Mock Write-Host {}
        Mock Get-CimInstance { @([pscustomobject]@{ ProcessId = 11 }, [pscustomobject]@{ ProcessId = 12 }) } -ParameterFilter { $Filter -eq 'ParentProcessId=10' }
        Mock Get-CimInstance { @() } -ParameterFilter { $Filter -ne 'ParentProcessId=10' }
        Mock Get-Process { [pscustomobject]@{ Id = $Id; ProcessName = 'python'; SessionId = 1 } }
        $script:order = [System.Collections.Generic.List[int]]::new()
        Mock Stop-OneProcess { $script:order.Add($TargetPid); $TargetPid -ne 12 }

        $t = Stop-ProcessTree -TargetPid 10
        $t.Stopped | Should -Be 2
        $t.Failed  | Should -Be 1
        @($script:order) | Should -Be @(11, 12, 10)
    }
}

Describe 'zkill' {
    BeforeAll {
        $cfg = Join-Path $TestDrive 'zconfig.json'
        Set-Content -LiteralPath $cfg -Encoding ASCII -Value '{ "projects": { "demo": { "label": "demo" } } }'
        $script:Env = @{ ZCONFIG = $cfg; ZTOKENS_DATA = (Join-Path $TestDrive 'no-such-dir') }

        function Invoke-ZKill {
            param([int]$Port)
            $saved = @{}
            foreach ($k in $script:Env.Keys) { $saved[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $script:Env[$k]) }
            try {
                $out = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $script:ZKillOnly demo -Port $Port | Out-String
                return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $out }
            } finally {
                foreach ($k in $saved.Keys) { [Environment]::SetEnvironmentVariable($k, $saved[$k]) }
            }
        }
    }

    It 'stops a real listener, says so, and exits 0' {
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
        $p = Start-Process -FilePath powershell.exe -WindowStyle Hidden -PassThru -ArgumentList '-NoProfile', '-Command',
            "`$l = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, $port); `$l.Start(); Start-Sleep -Seconds 120"
        try {
            $deadline = (Get-Date).AddSeconds(15)
            while (-not (netstat -ano | Select-String ":$port\s+.*LISTENING") -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200 }
            netstat -ano | Select-String ":$port\s+.*LISTENING" | Should -Not -BeNullOrEmpty

            $r = Invoke-ZKill -Port $port
            $r.Output | Should -Match "Killing PID $($p.Id)"
            $r.Output | Should -Match '\d+ process\(es\) stopped'
            $r.Output | Should -Not -Match 'could not be stopped'
            $r.Output | Should -Match 'Kill complete\.'
            $r.ExitCode | Should -Be 0
            Get-Process -Id $p.Id -ErrorAction SilentlyContinue | Should -BeNullOrEmpty
        } finally {
            Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
        }
    }

    It 'says "Nothing to kill" for a port nobody is on, and exits 0' {
        $probe = [System.Net.Sockets.TcpListener]::new([System.Net.IPAddress]::Loopback, 0)
        $probe.Start(); $port = $probe.LocalEndpoint.Port; $probe.Stop()
        $r = Invoke-ZKill -Port $port
        $r.Output | Should -Match 'Nothing to kill'
        $r.ExitCode | Should -Be 0
    }

    It 'reports what is left running and exits 1' {
        # The refusal itself cannot be staged here, so this holds the wiring:
        # a failed stop is reported as such, and the run ends non-zero.
        $src = Get-Content -LiteralPath $script:ZKillOnly -Raw
        $src | Should -Match 'process\(es\) could not be stopped and are still running'
        $src | Should -Match '(?s)if \(\$anyFailed\) \{\s+Write-Host "Kill incomplete\." -ForegroundColor Red\s+Stop-ZTracking; exit 1'
        $src | Should -Not -Match '\$killed\s*\+='
        (Get-Content -LiteralPath (Join-Path (Split-Path -Parent $PSScriptRoot) 'ZHelpers.ps1') -Raw) |
            Should -Not -Match 'Stop-Process -Id \$\w+ -Force -ErrorAction SilentlyContinue\s+\$killed\+\+'
    }
}
