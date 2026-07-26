<!--
Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
Created by Kelly Michels · dev@evomedia.net
Licensed under the MIT License. See LICENSE.
-->

# Changelog

Notable changes to the Evomedia.net Token Savers.

## Unreleased

### Fixed
- **`zdeploy` no longer deletes operator-managed files on deploy** (#2) —
  the project-directory replacement preserved only `./.env`, silently
  destroying every other server-side file (`.env.db`, staged signing
  keys, certs) on every deploy. All `.env*` files at the project root are
  now preserved by default, plus anything listed in the new
  `deploy.preserve` array (files or directories); the vite kind, which
  previously preserved nothing, gets the same protection. Found the hard
  way: a first production deploy of an auth service wiped its staged DB
  credentials and RSA signing keys.

### Added
- **Test suite (Pester)** — the toolkit now has automated coverage of its own
  pure logic: `Get-ArchiveExcludes` (including the deploy-vs-backup rule that
  keeps `.env`/`uploads` out of deploys but *in* backups), config and project
  lookups, `remote.composeDir` fallback, EC2 target composition, and build-label
  formatting. Run with `Invoke-Pester .\tests` (Pester 5+). Verified by mutation
  testing — reintroducing each historical bug turns the suite red.
- **`ZCONFIG` environment variable (PowerShell)** — overrides the path to
  `zconfig.json`, matching the bash port, which has always honored it. Closes a
  parity gap and gives the test suite a seam for injecting a fixture config.
- **`zec2_rotatekeys` — safely rotate/reset server-side secrets** — a new
  tool for when a secret leaks or a deploy overwrites a production `.env`
  with dev values. `-Rotate KEY` regenerates a key **on the server**
  (`openssl rand -hex 32`) so the new value never leaves the box; `-Set KEY`
  takes an operator-known value (e.g. `DATABASE_URL`, `ADMIN_EMAIL`) from a
  masked prompt and streams it over SSH stdin — never a command argument,
  never echoed. Backs the server `.env` up to a timestamped `.bak` first,
  updates the key atomically (matches or appends), auto-detects
  `backend/.env` from `deploy.preserve`, and with `-Restart` **recreates**
  the container (`up -d --force-recreate`, so the new values actually load —
  a plain restart keeps the old environment). `-WhatIf` previews the plan
  without touching anything.
- **`zkill all`** — `zkill` now accepts `all`, stopping the dev server of
  every project that has a `ports.dev` (edge/docker stacks with no local dev
  server are skipped). Brings it in line with `zdeploy all` / `zbackup all`;
  the one-shot "stop everything I've got running locally". Ported to both the
  PowerShell and bash versions.
- **`zdeploy` server-side health verification (`verify` block)** — projects
  not published through the edge proxy can declare
  `"verify": { "port": ..., "path": "/health", "expect": "..." }` and the
  deploy is checked from the server itself (`curl localhost:<port><path>`
  over SSH) instead of hitting the public IP. Fixes a false PASS where the
  proxy's default vhost answered for apps that never started; projects
  with neither `domain` nor `verify` are now reported as NOT verified.
- **`zdeploy` optional `deploy.gitPull`** — `git pull --ff-only` in the
  project root before zipping. `zdeploy` zips the working tree and doesn't
  otherwise pull, so a checkout left behind `origin` after a merged PR would
  deploy stale code while still bumping the build number — success that
  changes nothing. A failed pull aborts the deploy instead.
- **Per-project `start` config block** — `zstart` honors optional pre-start
  steps from `zconfig.json`: `"gitPull": true` runs `git pull --ff-only` in
  the project root before starting (never boot a stale checkout), and
  `"env": { ... }` sets environment variables for the dev-server process.
  Example added to `zconfig.example.json`.
- **Switch-style argument tolerance** — a leading dash on a project key is
  ignored everywhere (`zdeploy -myapp` == `zdeploy myapp`), for hands that
  grew up on per-project switches.

### Changed
- **`zbackup` / `zbackup_and_sync` require an explicit target** — running
  them bare now shows usage instead of quietly backing up every project;
  `all` does what bare invocation used to (matching `zdeploy`). The
  scheduled task created by `setup_backup_schedule.ps1` passes `all` —
  re-run it if your task was registered before this change.
- **`zbackup` parses more `DATABASE_URL` styles** — double/single-quoted
  values (Prisma convention), `postgres://` and `postgresql+driver://`
  schemes, and URLs without an explicit port (defaults to 5432) all work;
  previously these skipped the Postgres dump with "Could not parse
  DATABASE_URL".
- **`zkill` / port cleanup kills the whole process tree** — listeners on a
  project's port are now terminated children-first. Auto-reloading servers
  (uvicorn/watchfiles, nodemon) spawn workers that inherit the listening
  socket; killing only the parent left orphans serving stale code.
- **`zbackup` finds `DATABASE_URL` in `backend\.env` too** — projects with a
  frontend/backend split get their Postgres dump bundled without needing a
  root-level `.env`.

## 1.0.0

Initial public release: `zstart` / `zkill` / `zrestart` (local dev servers),
`zdeploy` (zip → upload → compose build → live build-version verification,
with handlers for python / vite / nextjs / edge / docker project kinds),
`zec2` / `zec2online` / `zrepair` (health checks and recovery), `zbackup` /
`zbackup_ec2` / `zsync` (local, server-side, and offsite backups), all driven
by a single gitignored `zconfig.json`.
