# How a docker stack gets its images, and the deploy that shipped nothing.
#
#   Invoke-Pester .\tests
#
# `docker compose pull` is right for a stack of published images - Prometheus,
# Grafana, docker-mailserver - and wrong for one built from a Dockerfile in the
# tree, where there is nothing to pull.
#
# The trap is what happens after. `docker compose up -d` builds only when the
# image is MISSING, so the first deploy of a build-from-source stack works and
# every one after it uploads the new code, starts the OLD image, and reports
# success. Green deploy, healthy container, and the change is not in it. That
# is the failure this helper exists to prevent, and it is worse than an error
# because nothing about it looks wrong.
#
# ZHelpers.ps1 is dot-sourced rather than zdeploy.ps1: zdeploy executes its
# main flow on load, helpers only define functions.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) "ZHelpers.ps1")

    function New-Proj { param($Build)
        if ($null -eq $Build) { return [pscustomobject]@{ deploy = [pscustomobject]@{ gitPull = $true } } }
        return [pscustomobject]@{ deploy = [pscustomobject]@{ build = $Build } }
    }
}

Describe 'Get-DockerImageStep - build here, or pull from a registry' {

    It 'pulls by default, so every existing docker stack is unaffected' {
        $step = Get-DockerImageStep -Proj (New-Proj $null) -RemotePath '/home/u/stack/x'
        $step.Command | Should -BeLike '*docker compose pull*'
        $step.Command | Should -Not -BeLike '*build*'
    }

    It 'pulls for a project with no deploy block at all' {
        $step = Get-DockerImageStep -Proj ([pscustomobject]@{}) -RemotePath '/home/u/stack/x'
        $step.Command | Should -BeLike '*docker compose pull*'
    }

    It 'builds when the project asks to be built' {
        $step = Get-DockerImageStep -Proj (New-Proj $true) -RemotePath '/home/u/stack/x'
        $step.Command | Should -BeLike '*docker compose build*'
        $step.Command | Should -Not -BeLike '*compose pull*'
    }

    It 'still pulls when build is explicitly false' {
        $step = Get-DockerImageStep -Proj (New-Proj $false) -RemotePath '/home/u/stack/x'
        $step.Command | Should -BeLike '*docker compose pull*'
    }

    It 'refreshes the base image on a build, so a rebuild is not pinned to the first one' {
        $step = Get-DockerImageStep -Proj (New-Proj $true) -RemotePath '/home/u/stack/x'
        $step.Command | Should -BeLike '*--pull*'
    }

    It 'runs in the project directory: <Build>' -ForEach @(
        @{ Build = $true }
        @{ Build = $false }
    ) {
        $step = Get-DockerImageStep -Proj (New-Proj $Build) -RemotePath '/home/u/stack/ablecamera'
        $step.Command | Should -BeLike 'cd /home/u/stack/ablecamera &&*'
    }

    It 'labels the step with what it actually does: <Build>' -ForEach @(
        @{ Build = $true;  Expected = 'docker compose build' }
        @{ Build = $false; Expected = 'docker compose pull' }
    ) {
        (Get-DockerImageStep -Proj (New-Proj $Build) -RemotePath '/x').Label | Should -Be $Expected
    }
}

Describe 'the docker deploy uses it' {

    It 'no longer hardcodes compose pull' {
        $text = Get-Content -Raw (Join-Path (Split-Path -Parent $PSScriptRoot) "zdeploy.ps1")
        $body = $text.Substring($text.IndexOf('function Invoke-DockerDeploy'))
        $body = $body.Substring(0, $body.IndexOf('function Invoke-ZTokensPublish'))
        $body | Should -Match 'Get-DockerImageStep'
        $body | Should -Not -Match '"docker compose pull"'
    }
}
