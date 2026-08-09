# Evomedia.net Token Savers — https://github.com/evomedia-net/evo.zscripts
# Created by Kelly Michels · dev@evomedia.net
# Licensed under the MIT License. See LICENSE.

# NewProjectArchive.Tests.ps1 - Pester 5 suite for the archive builder.
#
#   Invoke-Pester .\tests
#
# Where the ZHelpers suite checks that Get-ArchiveExcludes returns the right
# *list*, this one checks the zip that actually gets built and shipped. A name
# can be on the exclude list and still end up in the archive; only opening the
# zip proves otherwise.
#
# Every test builds a real temp source tree, zips it, and inspects the entries.
# No config is read, so this file is independent of ZCONFIG and zconfig.json.

BeforeAll {
    . (Join-Path (Split-Path -Parent $PSScriptRoot) "ZHelpers.ps1")

    # Build a source tree from a list of relative paths. A path ending in '/'
    # becomes an (empty) directory; anything else becomes a file with content.
    function New-TestTree {
        param([string[]]$Paths)
        $root = Join-Path ([IO.Path]::GetTempPath()) ("zarc-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        foreach ($p in $Paths) {
            $full = Join-Path $root ($p -replace '/', '\')
            if ($p.EndsWith('/')) {
                New-Item -ItemType Directory -Path $full -Force | Out-Null
            } else {
                $dir = Split-Path -Parent $full
                if ($dir -and -not (Test-Path -LiteralPath $dir)) {
                    New-Item -ItemType Directory -Path $dir -Force | Out-Null
                }
                "content of $p" | Set-Content -LiteralPath $full -Encoding UTF8
            }
        }
        return $root
    }

    # Relative entry paths inside a zip, forward-slashed as stored.
    function Get-ZipEntries {
        param([string]$ZipPath)
        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
        $zip = [IO.Compression.ZipFile]::OpenRead($ZipPath)
        try { return @($zip.Entries | ForEach-Object { $_.FullName }) }
        finally { $zip.Dispose() }
    }

    # Build a tree, archive it, return the entry list. Cleans up after itself.
    function Get-ArchivedEntries {
        param([string[]]$Paths, [string[]]$TopLevelExclude = @(), [switch]$IncludeScriptFiles, [string[]]$ExtraFiles = @())
        $root = New-TestTree -Paths $Paths
        $zip  = Join-Path ([IO.Path]::GetTempPath()) ("zarc-" + [guid]::NewGuid().ToString("N") + ".zip")
        try {
            $splat = @{ SourcePath = $root; DestinationZip = $zip; TopLevelExclude = $TopLevelExclude; ExtraFiles = $ExtraFiles }
            if ($IncludeScriptFiles) { $splat.IncludeScriptFiles = $true }
            New-ProjectArchive @splat 6>$null
            return Get-ZipEntries -ZipPath $zip
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "New-ProjectArchive - basic packaging" {
    It "includes ordinary project files" {
        $e = Get-ArchivedEntries -Paths @("app.py", "readme.md")
        $e | Should -Contain "app.py"
        $e | Should -Contain "readme.md"
    }

    It "preserves nested structure with forward slashes (zip convention)" {
        $e = Get-ArchivedEntries -Paths @("src/lib/util.py")
        $e | Should -Contain "src/lib/util.py"
    }

    It "throws when the source directory does not exist" {
        { New-ProjectArchive -SourcePath (Join-Path ([IO.Path]::GetTempPath()) "definitely-not-here-$([guid]::NewGuid())") `
                             -DestinationZip (Join-Path ([IO.Path]::GetTempPath()) "x.zip") } | Should -Throw
    }

    It "throws rather than shipping an empty archive when everything is filtered out" {
        # A tree of nothing but junk must fail loudly - a silently empty deploy
        # zip would unpack to nothing on the server.
        { Get-ArchivedEntries -Paths @("debug.log", "notes.bak") } | Should -Throw
    }

    It "overwrites an existing zip at the destination" {
        $root = New-TestTree -Paths @("app.py")
        $zip  = Join-Path ([IO.Path]::GetTempPath()) ("zarc-" + [guid]::NewGuid().ToString("N") + ".zip")
        try {
            "stale placeholder" | Set-Content -LiteralPath $zip -Encoding UTF8
            New-ProjectArchive -SourcePath $root -DestinationZip $zip 6>$null
            (Get-ZipEntries -ZipPath $zip) | Should -Contain "app.py"
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
        }
    }

    It "creates the destination directory when it does not exist" {
        $root = New-TestTree -Paths @("app.py")
        $sub  = Join-Path ([IO.Path]::GetTempPath()) ("zarc-out-" + [guid]::NewGuid().ToString("N"))
        $zip  = Join-Path $sub "nested\deploy.zip"
        try {
            New-ProjectArchive -SourcePath $root -DestinationZip $zip 6>$null
            Test-Path -LiteralPath $zip | Should -BeTrue
        }
        finally {
            Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $sub -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

Describe "New-ProjectArchive - TopLevelExclude" {
    It "drops an excluded top-level file" {
        $e = Get-ArchivedEntries -Paths @("app.py", ".env") -TopLevelExclude @(".env")
        $e | Should -Contain "app.py"
        $e | Should -Not -Contain ".env"
    }

    It "drops an excluded top-level directory and everything under it" {
        $e = Get-ArchivedEntries -Paths @("app.py", "uploads/photo.png", "uploads/deep/scan.png") -TopLevelExclude @("uploads")
        $e | Should -Contain "app.py"
        @($e | Where-Object { $_ -like "uploads/*" }).Count | Should -Be 0
    }

    # This is the documented (and surprising) semantic: the exclude list matches
    # TOP-LEVEL names only. A nested backend/.env is NOT caught by excluding
    # ".env" - the server-side copy is what protects it on deploy (deploy.preserve).
    # Pinning it here so a future change to that behaviour is a deliberate choice
    # rather than an accident.
    It "does NOT exclude a nested file that merely shares an excluded name" {
        $e = Get-ArchivedEntries -Paths @("app.py", "backend/.env") -TopLevelExclude @(".env")
        $e | Should -Contain "backend/.env"
    }

    It "excludes several names at once" {
        $e = Get-ArchivedEntries -Paths @("app.py", ".env", "docs/guide.md", "archive/old.txt") `
                                 -TopLevelExclude @(".env", "docs", "archive")
        $e | Should -Be @("app.py")
    }

    It "is unaffected by an exclude naming something that isn't there" {
        $e = Get-ArchivedEntries -Paths @("app.py") -TopLevelExclude @("nonexistent", "also-missing")
        $e | Should -Contain "app.py"
    }
}

Describe "New-ProjectArchive - recursive junk pruning" {
    # NOTE: capture the -ForEach value into a named variable before any
    # Where-Object. Inside a pipeline scriptblock $_ rebinds to the pipeline
    # item, shadowing Pester's value - an assertion written as
    # `$_ -like "*/$_/*"` silently matches nothing and the test passes while
    # checking nothing at all.
    It "prunes nested junk directory '<_>' (TopLevelExclude cannot reach it)" -ForEach @(".git", "node_modules", "__pycache__", ".pytest_cache", ".mypy_cache", ".tox", ".next", ".turbo", "coverage", "htmlcov", ".idea", ".vscode") {
        $junkDir = $_
        $e = Get-ArchivedEntries -Paths @("app.py", "src/$junkDir/junk.txt")
        $e | Should -Not -Contain "src/$junkDir/junk.txt"
        @($e | Where-Object { $_ -like "*/$junkDir/*" }).Count | Should -Be 0
        $e | Should -Contain "app.py"
    }

    It "prunes top-level junk directory '<_>' even with no TopLevelExclude" -ForEach @(".git", "node_modules", "__pycache__", ".idea", ".vscode", "coverage") {
        $junkDir = $_
        $e = Get-ArchivedEntries -Paths @("app.py", "$junkDir/junk.txt")
        $e | Should -Not -Contain "$junkDir/junk.txt"
        $e | Should -Contain "app.py"
    }

    It "prunes a junk directory nested several levels deep" {
        $e = Get-ArchivedEntries -Paths @("app.py", "a/b/c/node_modules/pkg/index.js")
        @($e | Where-Object { $_ -like "*node_modules*" }).Count | Should -Be 0
        $e | Should -Contain "app.py"
    }

    It "keeps a file whose name merely contains a junk directory name" {
        $e = Get-ArchivedEntries -Paths @("app.py", "src/node_modules_notes.md")
        $e | Should -Contain "src/node_modules_notes.md"
    }

    It "keeps a directory whose name merely starts with a junk directory name" {
        $e = Get-ArchivedEntries -Paths @("app.py", "coverage-reports/summary.md")
        $e | Should -Contain "coverage-reports/summary.md"
    }
}

Describe "New-ProjectArchive - file filters" {
    It "skips junk extension '<_>'" -ForEach @(".log", ".tmp", ".bak", ".old", ".orig", ".rej", ".swp", ".pyc", ".pyo", ".tsbuildinfo", ".db", ".sqlite", ".sqlite3") {
        $e = Get-ArchivedEntries -Paths @("app.py", "artifact$_")
        $e | Should -Not -Contain "artifact$_"
        $e | Should -Contain "app.py"
    }

    It "skips nested archive '<_>' (no zips inside zips)" -ForEach @(".zip", ".tar", ".gz", ".7z", ".rar", ".iso", ".jar") {
        $e = Get-ArchivedEntries -Paths @("app.py", "bundle$_")
        $e | Should -Not -Contain "bundle$_"
    }

    It "skips OS junk file '<_>'" -ForEach @(".DS_Store", "Thumbs.db", "desktop.ini") {
        $e = Get-ArchivedEntries -Paths @("app.py", "src/$_")
        $e | Should -Not -Contain "src/$_"
    }

    It "keeps a source file whose extension is not filtered" {
        $e = Get-ArchivedEntries -Paths @("app.py", "styles.css", "index.html", "data.json")
        foreach ($f in @("app.py", "styles.css", "index.html", "data.json")) { $e | Should -Contain $f }
    }

    It "keeps an archive inside vendor/ - a vendored tarball is a build input" {
        # Dockerfiles COPY vendor/ wholesale; dropping the tarball there fails
        # the image build on the server, far from the filter that ate it.
        $e = Get-ArchivedEntries -Paths @("app.py", "vendor/sdk-1.0.0.tgz")
        $e | Should -Contain "vendor/sdk-1.0.0.tgz"
    }

    It "keeps an archive in a nested vendor/ directory" {
        $e = Get-ArchivedEntries -Paths @("app.py", "packages/api/vendor/sdk.tgz")
        $e | Should -Contain "packages/api/vendor/sdk.tgz"
    }

    It "still skips an archive outside vendor/ (the exemption is not global)" {
        $e = Get-ArchivedEntries -Paths @("app.py", "assets/bundle.tgz")
        $e | Should -Not -Contain "assets/bundle.tgz"
    }
}

Describe "New-ProjectArchive - IncludeScriptFiles" {
    It "skips <_> by default (local scripts are not part of a deploy)" -ForEach @(".ps1", ".cmd", ".bat") {
        $e = Get-ArchivedEntries -Paths @("app.py", "helper$_")
        $e | Should -Not -Contain "helper$_"
    }

    It "includes <_> when -IncludeScriptFiles is set (backing up the scripts folder itself)" -ForEach @(".ps1", ".cmd", ".bat") {
        $e = Get-ArchivedEntries -Paths @("app.py", "helper$_") -IncludeScriptFiles
        $e | Should -Contain "helper$_"
    }
}

Describe "New-ProjectArchive - ExtraFiles" {
    It "adds a file from outside the source tree at the archive root" {
        $extraDir = Join-Path ([IO.Path]::GetTempPath()) ("zarc-extra-" + [guid]::NewGuid().ToString("N"))
        New-Item -ItemType Directory -Path $extraDir -Force | Out-Null
        $extra = Join-Path $extraDir "dump.sql"
        "-- pg_dump output" | Set-Content -LiteralPath $extra -Encoding UTF8
        try {
            # This is how zbackup bundles a Postgres dump alongside the source.
            $e = Get-ArchivedEntries -Paths @("app.py") -ExtraFiles @($extra)
            $e | Should -Contain "dump.sql"
            $e | Should -Contain "app.py"
        }
        finally { Remove-Item -LiteralPath $extraDir -Recurse -Force -ErrorAction SilentlyContinue }
    }

    It "ignores an ExtraFiles entry that does not exist" {
        { Get-ArchivedEntries -Paths @("app.py") -ExtraFiles @("C:\definitely\not\here.sql") } | Should -Not -Throw
    }
}

Describe "New-ProjectArchive - realistic deploy shape" {
    It "produces a clean python deploy zip: source in, secrets and cruft out" {
        # The end-to-end shape of what zdeploy ships for a python project,
        # using the real exclude list rather than a hand-written one.
        $proj = [pscustomobject]@{
            kind   = "python"
            deploy = [pscustomobject]@{ exclude = @("docs") }
        }
        $excl = Get-ArchiveExcludes -Project $proj

        $e = Get-ArchivedEntries -TopLevelExclude $excl -Paths @(
            "app/main.py",
            "app/models.py",
            "requirements.txt",
            ".env",                      # secret - excluded on deploy
            ".env.production",           # secret - excluded on deploy
            "uploads/user-file.png",     # user data - excluded on deploy
            "docs/design.md",            # project's own deploy.exclude
            ".venv/Lib/site.py",         # virtualenv
            "__pycache__/main.pyc",      # bytecode
            "src/__pycache__/deep.pyc",  # nested bytecode (recursive prune)
            ".git/config",               # vcs
            "debug.log"                  # junk extension
        )

        $e | Should -Contain "app/main.py"
        $e | Should -Contain "app/models.py"
        $e | Should -Contain "requirements.txt"

        foreach ($unwanted in @(".env", ".env.production", "debug.log")) {
            $e | Should -Not -Contain $unwanted
        }
        foreach ($prefix in @("uploads/", "docs/", ".venv/", "__pycache__/", ".git/")) {
            @($e | Where-Object { $_ -like "$prefix*" }).Count | Should -Be 0
        }
        @($e | Where-Object { $_ -like "*__pycache__*" }).Count | Should -Be 0
    }

    It "keeps secrets and uploads in a BACKUP of the same tree" {
        # Same source, -ForBackup excludes: a backup that dropped .env or
        # uploads would not be a restore point.
        $proj = [pscustomobject]@{ kind = "python" }
        $excl = Get-ArchiveExcludes -Project $proj -ForBackup

        $e = Get-ArchivedEntries -TopLevelExclude $excl -Paths @(
            "app/main.py", ".env", "uploads/user-file.png", ".venv/Lib/site.py"
        )

        $e | Should -Contain ".env"
        $e | Should -Contain "uploads/user-file.png"
        @($e | Where-Object { $_ -like ".venv/*" }).Count | Should -Be 0   # still no virtualenv
    }
}
