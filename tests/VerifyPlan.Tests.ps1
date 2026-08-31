# Deploy-verification planning (#101).
#
#   Invoke-Pester .\tests
#
# The wrong-vhost failure was never about parsing a response - it was about
# WHICH channel got asked. So the channel-selection rules live in a pure
# function (Get-VerifyAttempts) and are pinned here, where they can be tested
# without an EC2 box: a project with no domain must never produce an edge
# attempt, because an edge request with no Host header can only reach the
# default vhost - which is a different product. That exact gap read evo.ehs's
# build number during evo-ai deploys twice on 2026-08-31 alone.
#
# ZHelpers.ps1 is dot-sourced rather than zdeploy.ps1: zdeploy executes its
# main flow on load, helpers only define functions.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) "ZHelpers.ps1")

    function New-Proj {
        param($Verify = $null, $Domain = $null, $Deploy = $null)
        $p = [pscustomobject]@{}
        if ($null -ne $Verify) { $p | Add-Member verify ([pscustomobject]$Verify) }
        if ($null -ne $Domain) { $p | Add-Member domain $Domain }
        if ($null -ne $Deploy) { $p | Add-Member deploy ([pscustomobject]$Deploy) }
        return $p
    }
}

Describe "Get-VerifyAttempts" {

    It "puts the docker-network read first when configured" {
        $proj = New-Proj -Verify @{ viaProxy = "evo_edge_proxy"; upstream = "app:80"; port = 8005 } -Domain "x.example"
        $attempts = Get-VerifyAttempts -Proj $proj -ExecCmd "docker exec ..."
        $attempts[0].Kind | Should -Be 'exec'
        ($attempts | ForEach-Object Kind) | Should -Be @('exec', 'port', 'edge')
    }

    It "never asks the edge for a project with no domain (the #101 trap)" {
        # The shape that hit #101: viaProxy + port, no domain. The old code
        # fell back to the bare IP here and read another product's counter.
        $proj = New-Proj -Verify @{ viaProxy = "evo_edge_proxy"; upstream = "deploy-app-1:8000"; port = 8005; path = "/health" }
        $attempts = Get-VerifyAttempts -Proj $proj -ExecCmd "docker exec ..."
        ($attempts | ForEach-Object Kind) | Should -Not -Contain 'edge'
    }

    It "returns an empty plan when nothing trustworthy exists" {
        # No verify config, no domain: the caller must SKIP, not guess.
        $attempts = Get-VerifyAttempts -Proj (New-Proj) -ExecCmd ""
        $attempts.Count | Should -Be 0
    }

    It "keeps the edge for a project with a domain, with its Host header" {
        $proj = New-Proj -Domain "jwks.example"
        $attempts = Get-VerifyAttempts -Proj $proj -ExecCmd ""
        $attempts.Count | Should -Be 1
        $attempts[0].Kind | Should -Be 'edge'
        $attempts[0].HostHeader | Should -Be "jwks.example"
    }

    It "prefers deploy.verifyHost over domain for the edge Host header" {
        $proj = New-Proj -Domain "old.example" -Deploy @{ verifyHost = "new.example" }
        $attempts = Get-VerifyAttempts -Proj $proj -ExecCmd ""
        $attempts[0].HostHeader | Should -Be "new.example"
    }

    It "carries the verify path into the port attempt, defaulting sensibly" {
        $proj = New-Proj -Verify @{ port = 8005; path = "/health" }
        (Get-VerifyAttempts -Proj $proj -ExecCmd "")[0].Path | Should -Be "/health"
        $proj2 = New-Proj -Verify @{ port = 9000 }
        (Get-VerifyAttempts -Proj $proj2 -ExecCmd "")[0].Path | Should -Be "/api/build-version"
    }

    It "survives the PS 5.1 one-element unroll" {
        # A single attempt must still come back as something with .Count and
        # index access - the pipeline trap that deadlocked ztests day 2.
        $proj = New-Proj -Verify @{ port = 8005 }
        $attempts = Get-VerifyAttempts -Proj $proj -ExecCmd ""
        $attempts.Count | Should -Be 1
        $attempts[0].Kind | Should -Be 'port'
    }
}

Describe "Get-VerifyTimeout" {

    It "uses the caller's default when the project says nothing" {
        Get-VerifyTimeout -Proj (New-Proj) -DefaultSec 30 | Should -Be 30
    }

    It "lets a slow-booting project widen its own window" {
        # An app that runs database migrations in its entrypoint exceeds
        # 30s on every deploy that ships one, and a warning that fires on
        # routine success trains people to ignore the real one.
        $proj = New-Proj -Verify @{ viaProxy = "p"; upstream = "u"; timeoutSeconds = 120 }
        Get-VerifyTimeout -Proj $proj -DefaultSec 30 | Should -Be 120
    }
}
