# What an edge or static deploy must not carry to the server, how the edge
# deploy validates the new config, and what it proves before it is done.
#
#   Invoke-Pester .\tests
#
# The edge and static handlers are the odd ones out among the deploy kinds:
# they scp the project straight onto the box rather than shipping a zip, so
# every top-level directory ships unless a skip list names it. A Claude Code
# worktree under .claude/worktrees is a second complete copy of the repo.
#
# ZHelpers.ps1 is dot-sourced rather than zdeploy.ps1: zdeploy executes its
# main flow on load, helpers only define functions. The checks that zdeploy
# calls the helpers read its source as text.

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    . (Join-Path $script:Root "ZHelpers.ps1")
    $script:Zdeploy = Get-Content -Raw (Join-Path $script:Root 'zdeploy.ps1')
    function Get-Handler([string]$Name) {
        [regex]::Match($script:Zdeploy, "(?s)function $Name \{.*?\r?\n\}").Value
    }
}

Describe 'Get-EdgeSkipDirs - what never leaves this machine' {

    It 'keeps local state and tooling off the proxy box: <Dir>' -ForEach @(
        @{ Dir = '.claude' }        # Claude Code worktrees: a whole second checkout
        @{ Dir = '.git' }
        @{ Dir = '.pytest_cache' }
        @{ Dir = 'nginx-logs' }     # the server writes these; a local copy would bury them
    ) {
        Get-EdgeSkipDirs | Should -Contain $Dir
    }

    It 'still ships the content the proxy actually serves: <Dir>' -ForEach @(
        @{ Dir = 'fonts' }
        @{ Dir = 'vendor' }
        @{ Dir = 'snippets' }
    ) {
        # Skipping these is how self-hosted scripts and fonts silently never
        # reach the server and the pages render without them.
        Get-EdgeSkipDirs | Should -Not -Contain $Dir
    }

    It 'is the list the edge deploy uses' {
        Get-Handler 'Invoke-EdgeDeploy' | Should -Match '\$skipDirs = Get-EdgeSkipDirs'
    }
}

Describe 'Get-StaticSkipDirs - what a static site never ships' {

    It 'leaves local tooling and dependencies at home: <Dir>' -ForEach @(
        @{ Dir = '.claude' }        # worktrees, and settings.local.json's approved commands
        @{ Dir = '.git' }
        @{ Dir = '.pytest_cache' }
        @{ Dir = 'node_modules' }
    ) {
        Get-StaticSkipDirs | Should -Contain $Dir
    }

    It 'is the list the static deploy uses' {
        Get-Handler 'Invoke-StaticDeploy' | Should -Match '\$skipDirs = Get-StaticSkipDirs'
    }
}

Describe 'Get-EdgeValidateMounts - nginx -t sees the directories the proxy will' {

    # The validate step once mounted nginx.conf and the certificates and
    # nothing else. That held while every include was a wildcard; a literal
    # include (a shared snippets/ file) failed `nginx -t` on a config the proxy
    # loads fine, after the upload and before compose up.

    BeforeAll {
        $script:Edge = Join-Path $TestDrive 'edge'
        foreach ($d in 'snippets', 'origin-verify', 'fonts') {
            New-Item -ItemType Directory -Path (Join-Path $script:Edge $d) -Force | Out-Null
        }
        Set-Content -LiteralPath (Join-Path $script:Edge 'nginx.conf') -Value 'events {}'
        Set-Content -LiteralPath (Join-Path $script:Edge 'robots.txt') -Value 'User-agent: *'
        $script:Compose = Join-Path $script:Edge 'docker-compose.yml'
        @(
            'services:'
            '  proxy:'
            '    volumes:'
            '      - ./nginx.conf:/etc/nginx/nginx.conf:ro'
            '      - /srv/certs/:/etc/letsencrypt/:ro'
            '      - ./fonts:/etc/nginx/fonts:ro'
            '      - ./snippets:/etc/nginx/snippets:ro'
            '      - ./.htpasswd:/etc/nginx/.htpasswd:ro'
            '      - ./origin-verify:/etc/nginx/origin-verify:ro'
            '      - ./robots.txt:/etc/nginx/robots.txt:ro'
            '      - ./nginx-logs:/var/log/nginx'
            '      - ./vendor:/etc/nginx/vendor:ro'
        ) | Set-Content -LiteralPath $script:Compose
        $script:Mounts = @(Get-EdgeValidateMounts -ComposeFile $script:Compose -LocalRoot $script:Edge -RemotePath '/srv/stack/edge')
    }

    It 'mounts the directory a literal include needs, where the proxy has it' {
        $script:Mounts | Should -Contain '-v /srv/stack/edge/snippets:/etc/nginx/snippets:ro'
    }

    It 'mounts every other /etc/nginx directory the compose file does: <Dir>' -ForEach @(
        @{ Dir = 'fonts' }
        @{ Dir = 'origin-verify' }
    ) {
        $script:Mounts | Should -Contain "-v /srv/stack/edge/${Dir}:/etc/nginx/${Dir}:ro"
    }

    It 'never mounts a file: a missing source would become a root-owned directory on the box' {
        ($script:Mounts -join ' ') | Should -Not -Match 'nginx\.conf|robots\.txt|htpasswd'
    }

    It 'leaves the certificates to certsSource and ignores mounts outside /etc/nginx' {
        ($script:Mounts -join ' ') | Should -Not -Match 'letsencrypt|nginx-logs'
    }

    It 'skips a directory the compose file names but the checkout does not have' {
        # vendor/ is in the compose file above and not on disk.
        ($script:Mounts -join ' ') | Should -Not -Match 'vendor'
    }

    It 'returns nothing for a compose file that mounts no /etc/nginx directory' {
        $bare = Join-Path $TestDrive 'bare-compose.yml'
        @('services:', '  proxy:', '    volumes:', '      - ./nginx.conf:/etc/nginx/nginx.conf:ro') | Set-Content -LiteralPath $bare
        @(Get-EdgeValidateMounts -ComposeFile $bare -LocalRoot $script:Edge -RemotePath '/srv/stack/edge').Count | Should -Be 0
    }

    It 'is what the validate step in zdeploy actually uses' {
        $script:Zdeploy | Should -Match 'Get-EdgeValidateMounts -ComposeFile'
        # The mounts land between the certificates and the image name.
        $script:Zdeploy | Should -Match '\$\{certMount\}\$\{dirMounts\}nginx:1\.27-alpine nginx -t'
    }
}

Describe 'Get-EdgeVerifyVerdict - what an edge deploy proves before it is called done' {

    # The proxy serves no stamp, its own included, so the deploy reads the
    # stamp back from the deploy directory and asks docker when the proxy
    # last started. Each case feeds the verdict what ssh would have returned.

    BeforeAll {
        $script:Began  = '2026-10-27T03:50:00Z'
        $script:After  = '2026-10-27T03:51:40.123456789Z'   # docker's nanoseconds
        $script:Before = '2026-10-26T22:00:12.000000000Z'
        $script:Stamp  = '{' + "`n" + '    "version":  "v1.0.0.0.3"' + "`n" + '}'
    }

    It 'passes when the box carries the expected release and the proxy started after the deploy began' {
        $v = Get-EdgeVerifyVerdict -ExpectedLabel 'v1.0.0.0.3' -RemoteStampJson $script:Stamp -ContainerStartedAt $script:After -DeployStartedAt $script:Began -CheckContainer
        $v.Ok | Should -BeTrue
        $v.RemoteLabel | Should -Be 'v1.0.0.0.3'
        $v.Problems | Should -BeNullOrEmpty
    }

    It 'reads the legacy productVersion/buildNumber stamp the README documents' {
        $v = Get-EdgeVerifyVerdict -ExpectedLabel 'v1.0.42' -RemoteStampJson '{ "productVersion": "1.0", "buildNumber": 42 }'
        $v.Ok | Should -BeTrue
        $v.RemoteLabel | Should -Be 'v1.0.42'
    }

    It 'fails when the upload did not land the stamp' {
        $v = Get-EdgeVerifyVerdict -ExpectedLabel 'v1.0.0.0.3' -RemoteStampJson '' -ContainerStartedAt $script:After -DeployStartedAt $script:Began -CheckContainer
        $v.Ok | Should -BeFalse
        ($v.Problems -join ' ') | Should -Match 'did not land the stamp'
    }

    It 'fails, naming both labels, when the box carries a different release' {
        $v = Get-EdgeVerifyVerdict -ExpectedLabel 'v1.0.0.0.3' -RemoteStampJson '{"version":"v1.0.0.0.2"}' -ContainerStartedAt $script:After -DeployStartedAt $script:Began -CheckContainer
        $v.Ok | Should -BeFalse
        ($v.Problems -join ' ') | Should -Match 'carries v1\.0\.0\.0\.2, expected v1\.0\.0\.0\.3'
    }

    It 'never reads an error page or a shell error as a version: <Body>' -ForEach @(
        @{ Body = '<html><body>502</body></html>' }
        @{ Body = 'cat: build-version.json: No such file or directory' }
        @{ Body = '{"keys":[{"kty":"RSA"}]}' }
    ) {
        $v = Get-EdgeVerifyVerdict -ExpectedLabel 'v1.0.0.0.3' -RemoteStampJson $Body -ContainerStartedAt $script:After -DeployStartedAt $script:Began -CheckContainer
        $v.Ok | Should -BeFalse
        $v.RemoteLabel | Should -BeNullOrEmpty
    }

    It 'fails when the proxy container predates the deploy: compose up did not recreate it' {
        $v = Get-EdgeVerifyVerdict -ExpectedLabel 'v1.0.0.0.3' -RemoteStampJson $script:Stamp -ContainerStartedAt $script:Before -DeployStartedAt $script:Began -CheckContainer
        $v.Ok | Should -BeFalse
        ($v.Problems -join ' ') | Should -Match 'was not recreated'
    }

    It 'fails when docker cannot say when the proxy started' {
        $v = Get-EdgeVerifyVerdict -ExpectedLabel 'v1.0.0.0.3' -RemoteStampJson $script:Stamp -ContainerStartedAt '' -DeployStartedAt $script:Began -CheckContainer
        $v.Ok | Should -BeFalse
        ($v.Problems -join ' ') | Should -Match 'cannot tell when the proxy container started'
    }

    It 'fails when the deploy never recorded its own start, rather than passing a check it cannot make' {
        $v = Get-EdgeVerifyVerdict -ExpectedLabel 'v1.0.0.0.3' -RemoteStampJson $script:Stamp -ContainerStartedAt $script:After -DeployStartedAt '' -CheckContainer
        $v.Ok | Should -BeFalse
        ($v.Problems -join ' ') | Should -Match 'did not record when it began'
    }

    It 'checks only the stamp when the project names no proxy container' {
        $v = Get-EdgeVerifyVerdict -ExpectedLabel 'v1.0.0.0.3' -RemoteStampJson $script:Stamp
        $v.Ok | Should -BeTrue
    }

    It 'reads docker''s nine fractional digits, a never-started container, and nothing else' {
        (ConvertTo-UtcInstant '2026-10-27T03:51:40.123456789Z').UtcDateTime | Should -Be ([datetime]::new(2026, 10, 27, 3, 51, 40, [DateTimeKind]::Utc))
        # docker inspect reports this StartedAt for a container that has never run.
        (ConvertTo-UtcInstant '0001-01-01T00:00:00Z') | Should -Not -BeNullOrEmpty
        (ConvertTo-UtcInstant 'not a time') | Should -BeNullOrEmpty
        (ConvertTo-UtcInstant '') | Should -BeNullOrEmpty
    }

    It 'is what the edge deploy in zdeploy runs: the stamp read before the upload, the verdict after the record step' {
        $handler = Get-Handler 'Invoke-EdgeDeploy'
        $handler | Should -Not -BeNullOrEmpty
        $read   = $handler.IndexOf("Read-JsonBuildVersion -FilePath (Join-Path `$root 'build-version.json')")
        $upload = $handler.IndexOf('>> uploading')
        $record = $handler.IndexOf('record deploy stamp')
        $verify = $handler.IndexOf('Wait-VerifyEdgeBuild')
        $read   | Should -BeGreaterThan -1
        $upload | Should -BeGreaterThan -1
        $record | Should -BeGreaterThan -1
        $verify | Should -BeGreaterThan -1
        $read   | Should -BeLessThan $upload
        $verify | Should -BeGreaterThan $record
        $script:Zdeploy | Should -Match 'function Wait-VerifyEdgeBuild'
        $script:Zdeploy | Should -Match 'Get-EdgeVerifyVerdict -ExpectedLabel'
    }
}
