# How zec2 and zec2online read a project's live build (#203, #269).
#
#   Invoke-Pester .\tests
#
# Two defects in one piece of code.
#
# #203: the vite branch of both tools had only the public probe. A site whose
# edge does not publish /build-version.json answers 404 for it, so for that
# site the read could never succeed, and the message sent the operator to a
# README section that could not help. zdeploy has read that stamp inside the
# container all along.
#
# #269: once a site's origin was armed, that same public probe was refused,
# and each run left two lines in the edge's gate log - the log that is meant
# to record attempts to reach the origin around CloudFront.
#
# These tests hold:
#   * the pure parts: the command that reads a stamp in a container, the label
#     out of either JSON shape, and which sentence is printed when nothing
#     could be read;
#   * the wiring, read with the parser because both scripts run on load -
#     each tool asks on the server first and decides whether the hostname is
#     armed before its one direct request.

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

    function New-Proj {
        param([string]$Kind = 'vite', [string]$Container = 'site')
        $remote = [pscustomobject]@{ containerName = $Container }
        return [pscustomobject]@{ kind = $Kind; domain = 'www.example.test'; remote = $remote }
    }
}

Describe "Get-ContainerStampCommand" {
    It "reads the stamp inside the container a vite project names" {
        Get-ContainerStampCommand -Proj (New-Proj -Container 'mysite') |
            Should -Be 'sudo docker exec mysite cat /usr/share/nginx/html/build-version.json 2>/dev/null'
    }

    It "is the command zdeploy's own check runs" {
        # Two definitions of where a static build's stamp lives would let the
        # deploy pass on a build the health check cannot read.
        $deploy = Get-FunctionText -File 'zdeploy.ps1' -Name 'Wait-VerifyStaticBuild'
        $deploy | Should -Match ([regex]::Escape('cat /usr/share/nginx/html/build-version.json 2>/dev/null'))
    }

    It "has nothing to offer a project that names no container" {
        Get-ContainerStampCommand -Proj (New-Proj -Container '') | Should -BeNullOrEmpty
        Get-ContainerStampCommand -Proj ([pscustomobject]@{ kind = 'vite'; domain = 'x.example.test' }) | Should -BeNullOrEmpty
    }

    It "is for vite builds only: <Kind>" -ForEach @(
        @{ Kind = 'python' }
        @{ Kind = 'nextjs' }
        @{ Kind = 'static' }
        @{ Kind = 'edge' }
    ) {
        Get-ContainerStampCommand -Proj (New-Proj -Kind $Kind) | Should -BeNullOrEmpty
    }

    It "refuses a name that could be more than a container name: <Name>" -ForEach @(
        @{ Name = 'site; id' }
        @{ Name = 'site $(id)' }
        @{ Name = '-rf' }
        @{ Name = 'a b' }
    ) {
        Get-ContainerStampCommand -Proj (New-Proj -Container $Name) | Should -BeNullOrEmpty
    }
}

Describe "Get-LabelFromStampText" {
    It "reads a version endpoint's answer as it always was read" {
        Get-LabelFromStampText '{"build_version":"v0.0.1.0.115"}' | Should -Be 'v0.0.1.0.115'
        Get-LabelFromStampText '{"version":"0.3.1"}'             | Should -Be '0.3.1'
    }

    It "reads a build-version.json in the object form" {
        Get-LabelFromStampText '{ "major": 1, "rc": 0, "beta": 0, "alpha": 0, "build": 208 }' | Should -Be 'v1.0.0.0.208'
    }

    It "reads a legacy two-part stamp" {
        Get-LabelFromStampText '{"productVersion":"1.2","buildNumber":7}' | Should -Be 'v1.2.7'
    }

    It "gives nothing for text that is not a stamp: <Text>" -ForEach @(
        @{ Text = '' }
        @{ Text = '   ' }
        @{ Text = '<html><title>404 Not Found</title></html>' }
        @{ Text = '{"something":"else"}' }
        @{ Text = 'cat: /usr/share/nginx/html/build-version.json: No such file or directory' }
    ) {
        Get-LabelFromStampText $Text | Should -BeNullOrEmpty
    }
}

Describe "Get-OriginBuildLabel" {
    It "reads the label out of what the server-side request printed" {
        Mock Invoke-OriginRequest { [pscustomobject]@{ ExitCode = 0; Lines = @('{', '  "version": "v1.0.0.0.9"', '}') } }
        Get-OriginBuildLabel -HostName 'www.example.test' -Path '/build-version.json' | Should -Be 'v1.0.0.0.9'
    }

    It "is nothing when the origin does not serve the file" {
        Mock Invoke-OriginRequest { [pscustomobject]@{ ExitCode = 22; Lines = @() } }
        Get-OriginBuildLabel -HostName 'www.example.test' -Path '/build-version.json' | Should -BeNullOrEmpty
    }

    It "is nothing, not an exception, when the server cannot be asked" {
        Mock Invoke-OriginRequest { throw "no edge project" }
        Get-OriginBuildLabel -HostName 'www.example.test' -Path '/build-version.json' | Should -BeNullOrEmpty
    }
}

Describe "Get-LiveBuildUnreadReason" {
    It "says the server-side read came back empty when there was one" {
        Get-LiveBuildUnreadReason -OnServer $true -Armed $true -NotPublished $false | Should -Match 'read on the server returned nothing'
    }

    It "says an armed hostname has no read on the server, and how to give it one" {
        $line = Get-LiveBuildUnreadReason -OnServer $false -Armed $true -NotPublished $false
        $line | Should -Match 'refuses direct requests'
        $line | Should -Match 'remote\.containerName'
    }

    It "says a closed endpoint is closed, not that the setup is broken" {
        $line = Get-LiveBuildUnreadReason -OnServer $false -Armed $false -NotPublished $true
        $line | Should -Match 'not published at the edge'
        $line | Should -Not -Match 'README'
    }

    It "keeps the README advice for the case it fits" {
        Get-LiveBuildUnreadReason -OnServer $false -Armed $false -NotPublished $false | Should -Match 'Enabling deploy verification'
    }
}

Describe "the two tools that read a live build" {
    It "<File> <Name> reads on the server first, for a vite build too" -ForEach @(
        @{ File = 'zec2.ps1';       Name = 'Show-Zec2LiveVersion' }
        @{ File = 'zec2online.ps1'; Name = 'Get-RemoteVersionLabel' }
    ) {
        $text = Get-FunctionText -File $File -Name $Name
        $text | Should -Match 'Get-ServerSideVersionCommand'
        $text | Should -Match 'Get-ContainerStampCommand'
        $text.IndexOf('Get-ContainerStampCommand') | Should -BeLessThan $text.IndexOf('Invoke-RestMethod')
    }

    It "<File> <Name> decides whether the hostname is armed before its one direct request" -ForEach @(
        @{ File = 'zec2.ps1';       Name = 'Show-Zec2LiveVersion' }
        @{ File = 'zec2online.ps1'; Name = 'Get-RemoteVersionLabel' }
    ) {
        $text = Get-FunctionText -File $File -Name $Name
        ([regex]::Matches($text, 'Invoke-RestMethod')).Count | Should -Be 1
        $text.IndexOf('Test-OriginArmed')     | Should -BeGreaterThan -1
        $text.IndexOf('Test-OriginArmed')     | Should -BeLessThan $text.IndexOf('Invoke-RestMethod')
        $text.IndexOf('Get-OriginBuildLabel') | Should -BeLessThan $text.IndexOf('Invoke-RestMethod')
    }

    It "every changed script still parses" {
        foreach ($f in 'ZHelpers.ps1', 'zec2.ps1', 'zec2online.ps1') {
            $errs = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:ScriptsDir $f), [ref]$null, [ref]$errs)
            @($errs).Count | Should -Be 0 -Because "$f must parse"
        }
    }
}
