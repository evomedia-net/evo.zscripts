# evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# A container left on a replaced single-file mount is restarted.
#
#   Invoke-Pester .\tests
#
# A docker stack can bind-mount a single FILE; the mail server mounts its alias
# and relay maps that way. The mount is pinned to the file that was there when
# the container started. The deploy unzips a new copy - a new inode - and
# `docker compose up -d` recreates nothing unless docker-compose.yml changed,
# so the container kept reading the old aliases after a deploy that reported
# success. A newly added mail alias once stayed refused that way until
# a manual `docker restart mailserver`.
#
# The behaviour tests run the real script under Git Bash with stub `docker`,
# `stat` and `sudo` commands on PATH: two containers, one whose mounted file
# was replaced (host inode 200, container 100) and one that is current.
# Every container name and path here is invented.

BeforeDiscovery {
    $script:GitBash = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
}

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) "ZHelpers.ps1")
    $script:GitBash = @(
        (Join-Path $env:ProgramFiles 'Git\bin\bash.exe'),
        (Join-Path ${env:ProgramFiles(x86)} 'Git\bin\bash.exe')
    ) | Where-Object { $_ -and (Test-Path -LiteralPath $_) } | Select-Object -First 1
    $script:Utf8 = New-Object Text.UTF8Encoding $false

    # POSIX form (/c/Users/...), not C:/Users/...: the drive's colon would
    # split a PATH entry in two, and the stubs would never be found.
    function ConvertTo-BashPath { param([string]$Path)
        $p = $Path -replace '\\', '/'
        if ($p -match '^([A-Za-z]):(.*)$') { $p = '/' + $Matches[1].ToLower() + $Matches[2] }
        return $p
    }

    function Get-Decoded { param([string]$Command)
        $b64 = ($Command -replace '^echo ', '') -replace ' \| base64 -d \| bash$', ''
        return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64))
    }

    function Save-Lf { param([string]$Path, [string[]]$Lines)
        [IO.File]::WriteAllText($Path, (($Lines -join "`n") + "`n"), $script:Utf8)
    }

    # A fake stack: a directory holding the two mounted files, and stubs that
    # answer the questions the script asks. RESTART_EXIT decides whether
    # `docker restart` succeeds.
    function New-FakeStack { param([int]$RestartExit = 0)
        $stack = Join-Path $TestDrive ("stack-{0}" -f [guid]::NewGuid().ToString('N'))
        $bin = Join-Path $stack 'bin'
        New-Item -ItemType Directory -Path $bin, (Join-Path $stack 'data') -Force | Out-Null
        Save-Lf (Join-Path $stack 'virtual.cf') @('a b')
        Save-Lf (Join-Path $stack 'other.cf') @('x')
        $s = ConvertTo-BashPath $stack
        Save-Lf (Join-Path $bin 'sudo') @('#!/bin/bash', 'exec "$@"')
        Save-Lf (Join-Path $bin 'stat') @(
            '#!/bin/bash',
            'case "$*" in',
            '  *virtual.cf*) echo 200 ;;',
            '  *other.cf*) echo 300 ;;',
            '  *) echo 999 ;;',
            'esac')
        Save-Lf (Join-Path $bin 'docker') @(
            '#!/bin/bash',
            'case "$*" in',
            '  "compose ps -q") printf "c1\nc2\n" ;;',
            '  *".Name"*c1) echo /mailserver ;;',
            '  *".Name"*c2) echo /other ;;',
            "  *Mounts*c1) printf '%s\n' '$s/virtual.cf|/etc/postfix-virtual.cf' '$s/data|/var/mail' ;;",
            "  *Mounts*c2) printf '%s\n' '$s/other.cf|/etc/other.cf' ;;",
            '  "exec c1 stat -c %i /etc/postfix-virtual.cf") echo 100 ;;',
            '  "exec c2 stat -c %i /etc/other.cf") echo 300 ;;',
            ('  restart*) echo "$*" >> "' + $s + '/restarts.log"; exit ' + $RestartExit + ' ;;'),
            '  *) echo "unexpected: $*" >&2; exit 2 ;;',
            'esac')
        return $stack
    }

    function Invoke-Stale { param([string]$Stack)
        $cmd = Get-RestartStaleMountsBash -RemotePath (ConvertTo-BashPath $Stack)
        $bin = ConvertTo-BashPath (Join-Path $Stack 'bin')
        $runner = Join-Path $Stack 'run.sh'
        Save-Lf $runner @('#!/bin/bash', "chmod +x '$bin'/*", "export PATH='$bin':`$PATH", $cmd)
        $out = & $script:GitBash (ConvertTo-BashPath $runner) 2>&1 | ForEach-Object { "$_" }
        return [pscustomobject]@{ Output = ($out -join "`n"); Exit = $LASTEXITCODE }
    }
}

Describe 'Get-RestartStaleMountsBash - the command' {

    It 'is base64 only, so PowerShell 5.1 cannot mangle its quotes on the way to ssh' {
        $cmd = Get-RestartStaleMountsBash -RemotePath '/srv/demo/stack'
        $cmd | Should -Match '^echo [A-Za-z0-9+/=]+ \| base64 -d \| bash$'
    }

    It 'runs in the stack directory, with LF line endings' {
        $script = Get-Decoded (Get-RestartStaleMountsBash -RemotePath '/srv/demo/stack')
        $script | Should -Match "^cd '/srv/demo/stack' \|\| exit 1"
        $script | Should -Not -Match "`r"
    }

    It 'compares the host inode with the one the container sees, for file mounts only' {
        $script = Get-Decoded (Get-RestartStaleMountsBash -RemotePath '/srv/x')
        $script | Should -Match 'docker compose ps -q'
        $script | Should -Match 'eq \.Type "bind"'
        $script | Should -Match 'sudo test -f "\$src"'
        $script | Should -Match 'sudo stat -c %i "\$src"'
        $script | Should -Match 'docker exec "\$c" stat -c %i "\$dst"'
        $script | Should -Match 'sudo docker restart "\$n"'
    }
}

Describe 'zdeploy docker deploy - wiring' {

    It 'checks for stale mounts right after docker compose up -d' {
        $src = Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) 'zdeploy.ps1')
        $fn = $src.Substring($src.IndexOf('function Invoke-DockerDeploy'))
        $fn = $fn.Substring(0, $fn.IndexOf("`nfunction "))
        $up = $fn.IndexOf('"docker compose up -d" "cd $remotePath && sudo docker compose up -d"')
        $check = $fn.IndexOf('Get-RestartStaleMountsBash -RemotePath $remotePath')
        $up | Should -BeGreaterThan 0
        $check | Should -BeGreaterThan $up
    }
}

Describe 'Get-RestartStaleMountsBash - behaviour' -Skip:(-not $script:GitBash) {

    It 'restarts only the container reading a replaced file, and says which file' {
        $stack = New-FakeStack
        $r = Invoke-Stale $stack
        $r.Exit | Should -Be 0
        $r.Output | Should -Match 'mailserver reads the replaced copy of: /etc/postfix-virtual.cf - restarting it'
        $r.Output | Should -Match 'mailserver restarted'
        $r.Output | Should -Match 'other: every single-file mount is current'
        (Get-Content (Join-Path $stack 'restarts.log')) | Should -Be @('restart mailserver')
    }

    It 'fails the step when a restart fails' {
        $stack = New-FakeStack -RestartExit 1
        $r = Invoke-Stale $stack
        $r.Exit | Should -Be 1
        $r.Output | Should -Match 'mailserver: restart FAILED'
    }
}
