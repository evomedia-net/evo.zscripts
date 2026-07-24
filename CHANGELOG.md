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
