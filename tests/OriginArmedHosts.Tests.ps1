# A hostname whose origin is armed is asked on the server (#263).
#
#   Invoke-Pester .\tests
#
# A site served through CloudFront can have its edge armed to close the
# connection on any request for it that did not come through CloudFront.
# Several tools ask a site how it is by going straight to the server with a
# Host header. For an armed hostname each would get no answer, read a healthy
# site as dead, and the online check would then start its stack.
#
# For an armed hostname they ask ON the server, through the edge project's
# bin/origin-request.sh. These tests hold:
#   * the pure parts: which hostnames the server's answer names, the command
#     that is sent to a shell, and how a response is taken apart;
#   * that nothing being armed, or nothing to ask, leaves every tool exactly
#     as it was;
#   * the wiring, read with the parser because these scripts run on load -
#     each of the three asks Test-OriginArmed before it goes direct.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) "ZHelpers.ps1")
    $script:ScriptsDir = Split-Path -Parent $PSScriptRoot

    function Get-FunctionText {
        param([string]$File, [string]$Name)
        $errs = $null
        $ast = [System.Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $script:ScriptsDir $File), [ref]$null, [ref]$errs)
        $fn = $ast.Find({ param($n)
                $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $Name }, $true)
        if (-not $fn) { throw "no function $Name in $File" }
        return $fn.Extent.Text
    }

    function Get-FileText {
        param([string]$File)
        return [System.IO.File]::ReadAllText((Join-Path $script:ScriptsDir $File))
    }
}

Describe "ConvertTo-OriginArmedHosts" {
    It "reads one hostname per line, lowercased" {
        $hosts = ConvertTo-OriginArmedHosts -Lines @('example.test', 'WWW.Example.test', '')
        $hosts | Should -Be @('example.test', 'www.example.test')
    }

    It "drops anything that is not a hostname" {
        # Server output decides which requests are sent where.
        $hosts = ConvertTo-OriginArmedHosts -Lines @('example.test; rm -rf /', "bash: no such file", '-oops', 'ok.example.test')
        $hosts | Should -Be @('ok.example.test')
    }

    It "names each hostname once" {
        (ConvertTo-OriginArmedHosts -Lines @('a.example.test', 'A.example.test')).Count | Should -Be 1
    }

    It "gives an empty list, not null, when nothing is armed" {
        $hosts = ConvertTo-OriginArmedHosts -Lines @()
        $null -eq $hosts | Should -BeFalse
        @($hosts).Count | Should -Be 0
    }
}

Describe "Test-OriginArmed" {
    BeforeEach { Reset-OriginArmedHosts }
    AfterAll   { Reset-OriginArmedHosts }

    It "is true for an armed hostname, whatever its case" {
        Mock Get-OriginArmedHosts { return , @('example.test', 'www.example.test') }
        Test-OriginArmed -HostName 'WWW.example.test'   | Should -BeTrue
        Test-OriginArmed -HostName 'other.example.test' | Should -BeFalse
    }

    It "is false for no hostname at all" {
        Mock Get-OriginArmedHosts { return , @('example.test') }
        Test-OriginArmed -HostName ''     | Should -BeFalse
        Test-OriginArmed -HostName $null  | Should -BeFalse
    }

    It "is false when no edge project is configured, without asking the server" {
        Mock Get-OriginRequestScriptPath { $null }
        Mock Get-Ec2SshOpts { throw "ssh must not be reached when there is nothing to ask" }
        Test-OriginArmed -HostName 'www.example.test' | Should -BeFalse
    }
}

Describe "Get-OriginRequestScriptPath" {
    It "looks under the edge's remote path, in bin/" {
        Mock Get-ZEdgeProject { [pscustomobject]@{ Key = 'edge'; Config = [pscustomobject]@{ remote = [pscustomobject]@{ path = '/srv/edge/' } } } }
        Get-OriginRequestScriptPath | Should -Be '/srv/edge/bin/origin-request.sh'
    }

    It "has nothing to ask through when no edge project is configured" {
        Mock Get-ZEdgeProject { $null }
        Get-OriginRequestScriptPath | Should -BeNullOrEmpty
    }
}

Describe "Get-OriginRequestCommand" {
    BeforeAll {
        Mock Get-OriginRequestScriptPath { '/srv/edge/bin/origin-request.sh' }
    }

    It "asks for the body by default" {
        Get-OriginRequestCommand -HostName 'www.example.test' -Path '/build-version.json' |
            Should -Be "bash '/srv/edge/bin/origin-request.sh' 'www.example.test' '/build-version.json'"
    }

    It "passes the mode through" {
        Get-OriginRequestCommand -HostName 'example.test' -Path '/' -Mode status |
            Should -Be "bash '/srv/edge/bin/origin-request.sh' --status 'example.test' '/'"
        Get-OriginRequestCommand -HostName 'example.test' -Path '/x' -Mode include |
            Should -Be "bash '/srv/edge/bin/origin-request.sh' --include 'example.test' '/x'"
    }

    It "refuses a hostname that could be more than a hostname" {
        { Get-OriginRequestCommand -HostName "example.test'; id; '" -Path '/' } | Should -Throw
        { Get-OriginRequestCommand -HostName 'example.test evil' -Path '/' }    | Should -Throw
    }

    It "refuses a path that could be more than a path" {
        { Get-OriginRequestCommand -HostName 'example.test' -Path "/a'b" }      | Should -Throw
        { Get-OriginRequestCommand -HostName 'example.test' -Path '/a b' }      | Should -Throw
        { Get-OriginRequestCommand -HostName 'example.test' -Path '/$(id)' }    | Should -Throw
        { Get-OriginRequestCommand -HostName 'example.test' -Path 'no-slash' }  | Should -Throw
    }
}

Describe "ConvertFrom-OriginInclude" {
    It "takes a response apart" {
        $lines = @("HTTP/1.1 200 OK`r", "Content-Type: application/json`r", "Access-Control-Allow-Origin: *`r", "`r", '{"commits": 4235}')
        $r = ConvertFrom-OriginInclude -Lines $lines
        $r.Status | Should -Be 200
        $r.Headers['access-control-allow-origin'] | Should -Be '*'
        ($r.Body | ConvertFrom-Json).commits | Should -Be 4235
    }

    It "keeps a body that has blank lines in it" {
        $r = ConvertFrom-OriginInclude -Lines @('HTTP/1.1 200 OK', 'X-A: 1', '', 'one', '', 'three')
        $r.Body | Should -Be "one`n`nthree"
    }

    It "reports no status when the origin gave no answer" {
        $r = ConvertFrom-OriginInclude -Lines @()
        $r.Status | Should -Be 0
        $r.Body   | Should -Be ''
    }

    It "reads the final response when an interim one came first" {
        $r = ConvertFrom-OriginInclude -Lines @('HTTP/1.1 100 Continue', 'X-A: 1', '', 'HTTP/1.1 404 Not Found', 'X-B: 2', '', 'gone')
        $r.Status | Should -Be 404
        $r.Headers.ContainsKey('X-A') | Should -BeFalse
        $r.Headers['x-b'] | Should -Be '2'
        $r.Body | Should -Be 'gone'
    }
}

Describe "Get-OriginStatus" {
    It "reads the code the server prints" {
        Mock Invoke-OriginRequest { [pscustomobject]@{ ExitCode = 0; Lines = @('200') } }
        Get-OriginStatus -HostName 'www.example.test' | Should -Be 200
    }

    It "is 0 when the origin gave no answer" {
        Mock Invoke-OriginRequest { [pscustomobject]@{ ExitCode = 52; Lines = @('000') } }
        Get-OriginStatus -HostName 'www.example.test' | Should -Be 0
        Mock Invoke-OriginRequest { throw "ssh failed" }
        Get-OriginStatus -HostName 'www.example.test' | Should -Be 0
    }
}

Describe "the tools that ask a site directly" {
    It "the online check asks on the server before it can decide a site is down" {
        $fn = Get-FunctionText -File 'zec2online.ps1' -Name 'Test-HttpOnline'
        $fn | Should -Match 'Test-OriginArmed -HostName \$HostHeader'
        $fn.IndexOf('Test-OriginArmed') | Should -BeLessThan $fn.IndexOf('Test-NetConnection')
        $fn.IndexOf('Test-OriginArmed') | Should -BeLessThan $fn.IndexOf('Invoke-WebRequest')
    }

    It "the reachability check asks on the server before its direct GET" {
        $fn = Get-FunctionText -File 'zec2.ps1' -Name 'Test-Zec2Reachability'
        $fn | Should -Match 'Test-OriginArmed -HostName \$HostHeader'
        $fn.IndexOf('Test-OriginArmed') | Should -BeLessThan $fn.IndexOf('Invoke-WebRequest')
    }

    It "the repair smoke test asks on the server before its direct GET" {
        $text = Get-FileText -File 'zrepair.ps1'
        $text | Should -Match 'Test-OriginArmed -HostName \$proj\.domain'
        $text.IndexOf('Test-OriginArmed') | Should -BeLessThan $text.IndexOf('Invoke-WebRequest')
    }

    It "every changed script still parses" {
        foreach ($file in 'ZHelpers.ps1', 'zec2online.ps1', 'zec2.ps1', 'zrepair.ps1') {
            $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile(
                (Join-Path $script:ScriptsDir $file), [ref]$null, [ref]$errs)
            @($errs).Count | Should -Be 0 -Because "$file has a syntax error"
        }
    }
}
