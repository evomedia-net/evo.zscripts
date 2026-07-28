<!--
Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
Created by Kelly Michels · dev@evomedia.net
Licensed under the MIT License. See LICENSE.
-->

# zscripts Token Savers

When an AI coding agent orchestrates your infrastructure — starting dev servers, deploying to EC2, diagnosing 502s — it spends hundreds to thousands of tokens per operation on SSH plumbing, Docker output, and retry logic. Those tokens should go to code.

Token Savers gives you short, one-word commands to run those parts yourself: `zdeploy myapp`, `zrepair myapp`, `zstart myapp`. You handle the deterministic infrastructure; your agent handles code. **Running these scripts manually instead of asking your agent to orchestrate them keeps measured script output out of your agent's context window — ~26,500 tokens per active development day at a typical run cadence.** Per-run figures are measured; the daily total applies typical run counts. See [TOKEN_SAVINGS.md](TOKEN_SAVINGS.md) for the numbers and method.

Every command is a tiny PowerShell script driven by a single JSON config file. The project key you define in that config **is** the command argument — add `myapp` to the config and `zstart myapp`, `zdeploy myapp`, `zbackup myapp` all just work, no script edits needed.

**Requirements:** Windows, PowerShell 5.1+, OpenSSH client (`ssh`/`scp`, ships with Windows 10/11), and Docker + docker compose on the remote host for the deploy scripts.

---

## Install

No installer. Clone the repo and add the folder to your `PATH`:

```powershell
git clone https://github.com/kellymichels/zscripts-token-savers.git C:\tools\zscripts

# Add to your user PATH (new terminals pick it up automatically)
[Environment]::SetEnvironmentVariable(
    "Path",
    [Environment]::GetEnvironmentVariable("Path", "User") + ";C:\tools\zscripts",
    "User"
)
```

Open a new terminal and every command below works from any directory. The `.cmd` wrappers invoke PowerShell with `-ExecutionPolicy Bypass`, so no execution-policy changes are needed — `zstart myapp` just works from cmd, PowerShell, or a VS Code terminal.

---

## Configure

All machine-specific values (server IP, SSH user and key, folder paths, project definitions) live in **one file**: `zconfig.json`. It is gitignored — your secrets never leave your machine.

```powershell
cd C:\tools\zscripts
copy zconfig.example.json zconfig.json
notepad zconfig.json
```

The example config ships with sample projects named by their kind — `pyapp`, `viteapp`, `nextapp`, `edge`, `analytics`. **Rename the keys to your own project names**; the key is what you type as the command argument. Add as many projects as you like — no script edits ever needed.

Set the `ZCONFIG` environment variable to point at a config somewhere else — handy for a second machine profile, or for running against a scratch config without touching your real one.

### Config reference

```jsonc
{
  "ec2": {
    "ip":        "203.0.113.10",                      // your server's public IP
    "user":      "youruser",                          // SSH user on the server
    "pemKey":    "C:\\Users\\You\\.ssh\\key.pem",     // path to your SSH private key
    "stackRoot": "/home/youruser/stack"               // parent dir for all deployed projects
  },
  "paths": {
    "temp":            "C:\\dev\\temp",               // deploy zips staged here (auto-deleted)
    "backupsLocal":    "C:\\dev\\backups\\projects",  // zbackup output
    "backupsEc2":      "C:\\dev\\backups\\ec2",       // zbackup_ec2 output
    "scriptsRoot":     "C:\\tools\\zscripts",         // this folder
    "oneDriveBackups": ""                             // zsync destination ("" disables)
  },
  "projects": {
    "myapp": {
      "label":       "My App",                        // display name in output
      "kind":        "python",                        // python | vite | nextjs | edge | docker
      "localRoot":   "C:\\dev\\myapp",                // project folder on this machine
      "startModule": "myapp.main",                    // python kind: runs "python -m myapp.main"
   // "startApp":    "app.main:app",                  //   ...or, for ASGI/FastAPI: uvicorn app.main:app --port <dev> --reload
      "install":     "-e .",                          // optional: pip args `zsetup` uses (auto-detects "-e ." / "-r requirements.txt")
      "ports":       { "dev": 8080, "prod": 3000 },   // local dev port / direct server port
      "domain":      "www.myapp.com",                 // public domain (health checks + verification)
      "start": {                                      // optional zstart pre-steps
        "gitPull": true,                              //   git pull --ff-only before starting
        "env":     { "MYAPP_DEBUG": "1" }             //   env vars for the dev server process
      },
      "db":          { "user": "dbuser", "name": "dbname" },  // optional: enables db dump/wait steps
      "migrations":  "prisma",                        // optional: run prisma migrate on deploy
      "remote": {
        "path":       "/home/youruser/stack/myapp",   // deploy target on the server
        "composeDir": "/home/youruser/stack/myapp/docker",  // optional: if compose isn't at path root
        "appService": "app",                          // optional: compose service name override
        "containerName": "myapp"                      // optional (vite): container to read build-version from
      },
      "deploy": {
        "zipName": "MyAppDeploy.zip",                 // optional: defaults to <key>Deploy.zip
        "gitPull": true,                              // optional: git pull --ff-only before zipping
        "exclude": ["docs", "big-data-folder"]        // optional: extra top-level dirs/files to skip
      }
    }
  }
}
```

Optional blocks do real work:

- **`install`** — how `zsetup` installs a python project's dependencies into its `.venv`: the pip args, e.g. `"-e ."`, `"-e backend"` (deps in a subfolder), or `"-r requirements.txt"`. Omit it and `zsetup` auto-detects a root `pyproject.toml`/`setup.py` (`-e .`) or `requirements.txt` (`-r requirements.txt`). `zstart` never installs — run `zsetup <key>` once, then `zstart <key>`.
- **`start`** — pre-start steps for `zstart`: `gitPull: true` runs `git pull --ff-only` in the project root first (never starts a stale checkout), and `env` sets environment variables for the dev-server process (feature flags, reload switches).
- **`db`** — deploys wait for `pg_isready` and `zbackup_ec2` pulls a `pg_dump`, both against the compose service named `db`. Omit it and those steps are skipped cleanly.
- **`deploy.gitPull`** — `git pull --ff-only` in the project root before zipping, so a merged PR actually ships. Since `zdeploy` zips your working tree, a checkout left behind `origin` would otherwise deploy stale code *and still bump the build number* — a silent no-op that looks like success. A failed pull (dirty tree that conflicts, diverged history) aborts the deploy rather than shipping uncertain code.
- **`migrations": "prisma"`** — runs `npx prisma migrate deploy` inside the app container after each deploy.
- **Compose service-name conventions** — handlers assume the app service is named `app` (python) or `web` (nextjs) and the database service `db`. Override the app service with `remote.appService`.
- **Edge extras** — an `edge`-kind project can set `proxyContainer` (the nginx container's name, used for reloads and stale-container cleanup) and `certsSource` (a host path with TLS certs, mounted read-only when validating `nginx.conf`).

---

## Commands

The `.cmd` wrappers are the everyday interface. Every command takes one or more project keys from your config; several also accept `all`. A leading dash is tolerated (`zdeploy -myapp` works the same as `zdeploy myapp`) for anyone with switch-style muscle memory.

| Command | What it does |
|---|---|
| `zsetup <key> ...` | Create the project's Python venv + install deps (or `npm install` for node) |
| `zstart <key> ...` | Start local dev server(s) |
| `zstartd <key> ...` | Same, detached (new window, returns immediately) |
| `zkill <key> ... \| all` | Kill local dev server(s) by port |
| `zrestart <key> ...` | Kill + start in one step |
| `zrestartd <key> ...` | Kill + start detached |
| `zdeploy <key> ... \| all` | Zip → upload → rebuild → verify a project on the server |
| `zec2 [<key> ...]` | Quick reachability check (TCP + HTTP + live build version) |
| `zec2online [<key> ...]` | Deep health check; auto-starts downed stacks, streams diagnostics |
| `zrepair <key> ...` | Audit + repair compose/proxy state on the server |
| `zec2_rotatekeys <key>` | Rotate/reset secret keys in a project's server-side `.env` (values generated server-side; never printed) |
| `zbackup <key> ... \| all` | Zip local project sources (+ DB dump) to the backups folder |
| `zbackup_ec2 [<key> ...]` | Pull DB dumps + server-side data files down from the server |
| `zsync [<key>]` | Copy new backups offsite (or build + mirror a vite dist) |
| `zstart_docker` | Run a local docker compose stack from `scriptsRoot\docker\` |
| `zchecksums [-Update]` | Verify every script against `CHECKSUMS.txt` (SHA-256) |

### Local development

#### `zstart` — start dev servers

```
zstart <project> [<project> ...] [-Port N] [-BindHost <host>] [-Detached]
```

Starts each project's dev server using the handler for its `kind`: **python** runs `python -m <startModule>` — or, for an ASGI/FastAPI app, `uvicorn <startApp>` (e.g. `app.main:app`) with the dev port and `--reload` — preferring the project's `.venv`; **vite** runs `npm run dev -- --host --port`, **nextjs** runs `npm run dev` with `PORT` set. Runs `npm install` automatically if `node_modules` is missing. A project's optional `start` config block runs first — `gitPull` fast-forwards the checkout and `env` sets process environment variables. Two more opt-in conveniences: if the project has a `motd/` folder of `.txt` files, one is shown (rotating) at startup; if it has `scripts/build_version_tool.py`, the build number is bumped on each start.

```powershell
zstart viteapp                     # dev server on its configured port
zstart pyapp -Port 9000            # override the port
zstart viteapp -BindHost 0.0.0.0   # expose on the LAN
zstartd nextapp                    # detached: window opens, prompt returns
```

#### `zkill` — stop dev servers

```
zkill <project> [<project> ...] | all  [-Port N] [-KillAll]
```

Finds whatever is LISTENING on each project's dev port and kills it — along with its whole process tree, children first. That matters for auto-reloading servers (uvicorn/watchfiles, nodemon): their worker processes inherit the listening socket and would otherwise survive as orphans, serving stale code. `-KillAll` also hunts down stray `node`/`python`/`next-server` processes whose command line references the project folder. `all` targets every project that has a dev port — the one-shot "stop everything I've got running locally".

```powershell
zkill viteapp                # free the port
zkill pyapp viteapp nextapp  # nuke everything
zkill all                    # stop every project's dev server
zkill nextapp -KillAll       # also kill orphaned runtime processes
```

#### `zrestart` — kill then start

```
zrestart <project> [<project> ...] [-Port N] [-KillAll] [-NoRestart] [-Detached] [-BindHost <host>]
```

The "it's wedged, bounce it" command: kill phase, then start phase with the same flags. `-NoRestart` makes it kill-only; `zrestartd` restarts detached.

### Server deployment & operations

#### `zdeploy` — deploy to the server

```
zdeploy <project> [<project> ...] [-Note "message"]
zdeploy all [-Note "message"]
```

The core workflow, per project kind (projects with `deploy.gitPull` first `git pull --ff-only` so a merged PR isn't left behind):

- **python / vite / nextjs** — zip the local source (excluding `.git`, `node_modules`, envs, archives, junk, plus anything in `deploy.exclude`), free disk space on the server (docker prune; aborts if under 1.5 GB free), `scp` the zip up, unzip into `remote.path` preserving all server-side `.env*` files plus anything listed in `deploy.preserve` (staged keys, certs, seed data — files or directories), `docker compose build` + `up -d`, then **verify the live site reports the new build version** (see [Enabling deploy verification](#enabling-deploy-verification)). nextjs additionally waits for Postgres (`db` block) and applies migrations (`migrations` field). Zips are always deleted locally afterward.
- **edge** — uploads *every top-level file* in the edge folder (nginx.conf, compose, css, htpasswd, …), validates the new config with `nginx -t` before switching over, then recreates the proxy.
- **docker** — uploads the compose folder's files, `docker compose pull` + `up -d`. For stacks that run stock images (analytics, mail, etc.).

`all` deploys every project — edge kinds first, then the rest in config order — and stops at the first failure.

```powershell
zdeploy viteapp
zdeploy pyapp -Note "fix billing banner"
zdeploy all -Note "weekly release"
```

#### `zec2` — reachability check

```
zec2 [<project> ...]        # no args = every project with a domain
```

For each project: TCP connect, then an HTTP GET with the project's `domain` as the Host header, then the live build version. Fast "is it up?" answer with firewall hints when it isn't.

#### `zec2online` — health check with auto-recovery

```
zec2online [<project> ...]  # no args = every project with a domain
```

The heavier sibling: verifies each app over HTTP, compares the **local** build version against what the **server** is actually serving (a mismatch means "redeploy?" — or a stale cache), and if a site is down it SSHes in, runs `docker compose up -d` for the app and the edge proxy, waits up to 30 s, and streams compose logs and system diagnostics if recovery fails.

#### `zrepair` — fix server routing

```
zrepair <project> [<project> ...]
```

Validates the edge proxy's nginx config (if an edge project is defined), shows each stack's compose status, starts anything that's down, and smoke-tests the live domain. For the "deploy succeeded but the site 502s" class of problem.

#### `zstop.ps1` — stop server stacks

```
zstop <project> [<project> ...]
```

`docker compose down` for the selected stacks on the server. Data volumes are preserved; `zdeploy <project>` brings a stack back. (PowerShell script only, no `.cmd` wrapper.)

#### `zec2_rotatekeys` — rotate server-side secrets

```
zec2_rotatekeys <project> [-Rotate KEY,KEY] [-Set KEY,KEY] [-EnvFile rel/path] [-Restart] [-WhatIf]
```

For when a secret leaks or a deploy overwrites a production `.env` with dev values: rotate or reset keys in a project's **server-side** `.env` without the values ever passing through this machine's shell history, a command argument, or your screen. `-Rotate` keys are regenerated **on the server** with `openssl rand -hex 32` — the new value is written straight into the `.env` there and never leaves the box. `-Set` keys are typed into a masked prompt and streamed to the server over SSH stdin (never a command argument, never echoed), for operator-known values like `DATABASE_URL` or `ADMIN_EMAIL`. The current server `.env` is copied to a timestamped `.bak` before any change; the KEY line is updated atomically, matching an existing key or appending it. The env file is auto-detected from the project's `deploy.preserve` (first `*.env`) or defaults to `.env` — override with `-EnvFile backend/.env`. Nothing touches the running app unless you pass `-Restart`, which **recreates** the container (`docker compose up -d --force-recreate <svc>`) so it actually reloads the new `.env` — a plain `restart` would keep the old environment. Being high-impact, it confirms before writing; `-WhatIf` prints the exact plan and changes nothing.

```powershell
# Preview only — see exactly what would change, change nothing:
zec2_rotatekeys pyapp -Rotate JWT_SECRET -Set DATABASE_URL,ADMIN_EMAIL -WhatIf

# Regenerate the JWT secret, restore the operator-known values, then restart:
zec2_rotatekeys pyapp -Rotate JWT_SECRET -Set DATABASE_URL,ADMIN_EMAIL,ADMIN_PASSWORD -Restart
```

### Backups

#### `zbackup` — local backups

```
zbackup <project> [<project> ...] [-Tag "label"]
zbackup all                                # every project + this scripts folder
zbackup scripts                            # just this scripts folder ('scripts' is reserved)
```

Zips each project's source into `paths.backupsLocal\<key>\<timestamp>_<key>[_tag].zip`. If the project's `.env` declares a `DATABASE_URL`, a Postgres dump is bundled into the zip automatically — quoted values (Prisma-style), `postgres://`/`postgresql+driver://` schemes, and URLs without an explicit port all parse. `backend\.env` is checked too, for frontend/backend split projects. `-Tag` labels the archive — handy before risky changes.

```powershell
zbackup all                      # everything
zbackup pyapp -Tag "pre-migration"
```

#### `zbackup_ec2` — pull backups from the server

```
zbackup_ec2 [<project> ...]     # no args = every project with a remote.path
```

For projects with a `db` block, runs `pg_dump` inside the server's db container. Also zips server-side data dirs (`uploads/`, `archive/`, `dist/`) when present, then downloads everything to `paths.backupsEc2` and cleans up the remote temp files.

#### `zsync` — sync backups offsite

```
zsync                                       # new backup files -> paths.oneDriveBackups
zsync <viteproject> -Destination <path>     # npm run build, then mirror dist/ to path
```

The no-args mode copies only files that don't already exist at the destination (never overwrites, never deletes). The project mode is for mirroring a static build; it also honors `$env:ZSYNC_DEST`.

#### `zbackup_and_sync.ps1` — both in one

```
zbackup_and_sync.ps1 <project> [<project> ...] | all
```

Runs `zbackup`, then `zsync`. This is what the scheduled task calls (with `all`).

#### `setup_backup_schedule.ps1` — nightly automation

Run **as Administrator** once. Creates a Windows Scheduled Task that runs `zbackup_and_sync.ps1 all` daily at 2:00 AM.

### Utilities

#### `zstart_docker` — local compose stack

```
zstart_docker [-Build] [-Attached] [-Solo]
```

Brings up a docker compose stack from `scriptsRoot\docker\docker-compose.yml` (or `docker-compose.solo.yml` with `-Solo`). Checks that Docker Desktop is actually running and tells you how to unwedge it if not.

#### `zsetup_mail.ps1` — provision mail accounts

```
zsetup_mail.ps1 -domain yourdomain.com [-mailHost mail.yourdomain.com]
```

Creates `admin@` and `noreply@` mailboxes (with generated passwords) in a docker-mailserver container on the server, then prints the exact DNS records (MX, SPF, A) and SMTP/IMAP settings to plug into your app.

#### `ZHelpers.ps1` — shared library

Not run directly. Dot-sourced by the other scripts; provides config loading (`Get-ZConfig`, `Get-ZProject`), SSH helpers (`Invoke-Ec2Step`), the deploy/backup archiver (`New-ProjectArchive`), and process-kill helpers. Extend here if you're adding your own scripts.

---

## Enabling deploy verification

**Why not just check for HTTP 200?** Because a 200 proves nothing — a stale cached build serves 200 all day. These scripts verify a deploy by comparing **build numbers**: your app exposes its build version, the deploy expects to see the *new* number live, and a mismatch means the upload or Docker build failed (or you're looking at a cached build).

It's optional — deploys still work without it, ending in a WARNING instead of a PASS — but it's the difference between "the server answered" and "the code I just shipped is actually running."

### 1. Add a version file to your project

```json
// build-version.json  (vite: in public/ · nextjs: in public/ · python: project root)
{ "productVersion": "1.0", "buildNumber": 42 }
```

### 2. Bump it during the server-side Docker build

The convention: each deploy's Docker build increments `buildNumber` by one, so the deploy script expects **local buildNumber + 1** to show up live. One line in your Dockerfile does it:

```dockerfile
RUN node -e "const f='public/build-version.json',v=require('./'+f);v.buildNumber++;require('fs').writeFileSync(f,JSON.stringify(v))"
```

### 3. Expose it

**Vite / static sites** — nothing to do: `public/build-version.json` is served at `/build-version.json`, which is where verification looks. (If your edge proxy blocks it from outside, set `remote.containerName` in config and verification reads it inside the container instead.)

**Next.js** — add an API route at `/api/build-version`:

```ts
// app/api/build-version/route.ts
import { NextResponse } from "next/server";
import bv from "@/public/build-version.json";

export async function GET() {
  return NextResponse.json({ build_version: `v${bv.productVersion}.${bv.buildNumber}` });
}
```

**Python (FastAPI shown; any framework works)** — expose `/api/build-version`:

```python
import json, pathlib

@app.get("/api/build-version")
def build_version():
    bv = json.loads(pathlib.Path("build-version.json").read_text())
    return {"build_version": f"v{bv['productVersion']}.{bv['buildNumber']}"}
```

Python projects can go further with a `scripts/build_version_tool.py` supporting `get` / `set` / `bump` subcommands — if present, `zdeploy` bumps the version inside the running container, records it, and `zstart` bumps on every dev start.

### Alternative: server-side health check (`verify` block)

Not every stack is published through the edge proxy — internal APIs, apps whose host port the firewall blocks, services waiting on a DNS record. For those, the old fallback (`GET http://<server-ip>/`) was worse than nothing: the edge proxy's *default vhost* answers with a 200 and the deploy "passes" even if your app never started.

Give the project a `verify` block instead, and `zdeploy` checks the app **from the server itself** over SSH:

```json
"verify": { "port": 8005, "path": "/health", "expect": "\"status\":\"ok\"" }
```

`port` is the host port the app publishes on the server; `path` defaults to `/`; `expect` is an optional substring the response must contain (an app version string makes this equivalent to build-number verification). Python-kind projects use `verify` automatically when there's no `build_version_tool.py` — and projects with *neither* a `domain` nor a `verify` block are now honestly reported as **NOT verified** instead of green-lighting the proxy's default page.

`zec2` and `zec2online` use these same endpoints to show what's live and flag local/server version drift.

---

## Adding a new project

1. Add a key under `projects` in `zconfig.json` — copy the sample of the matching `kind` and rename it.
2. That's it: `zstart`, `zkill`, `zrestart`, `zbackup`, `zdeploy`, `zec2`, `zec2online`, `zrepair`, `zstop` all accept the new key immediately.
3. A project whose deploy doesn't fit the python/vite/nextjs/edge/docker patterns needs its own `Invoke-<Kind>Deploy` function in `zdeploy.ps1` — copy an existing handler; they're all variations on zip → upload → compose up → verify.

## Verifying what you downloaded

`CHECKSUMS.txt` holds a SHA-256 for every `.ps1` and `.cmd` in the repo. Check them before running anything:

```powershell
zchecksums
```

Or with the standard tool on Linux/macOS/WSL — the manifest is `sha256sum` format:

```bash
sha256sum -c CHECKSUMS.txt
```

The hashes are identical on every platform: `.gitattributes` pins `.ps1`/`.cmd` to CRLF everywhere, so a file is byte-for-byte the same whether you cloned on Windows or Linux.

`zchecksums` flags three things — a file whose contents changed, a listed file that's gone, and a script on disk that **isn't** in the manifest (so something added quietly still gets noticed). It exits non-zero on any of them.

If you edit a script yourself, regenerate and commit the manifest with it:

```powershell
zchecksums -Update
```

**What this does and doesn't prove.** `CHECKSUMS.txt` lives in the same repo as the scripts, so anyone who could alter a script could alter the manifest too. It's an integrity check, not a signature: it reliably catches a truncated clone, a local edit you forgot about, or a file added outside a commit. It does *not* prove the code came from this project — for that you'd need a signature or a hash published outside this repo.

## Tests

The toolkit has its own [Pester](https://pester.dev) suite covering the pure logic — the exclude lists, config lookups, and version-label formatting that the deploy and backup paths depend on:

```powershell
Invoke-Pester .\tests
```

Needs Pester 5+ (`Install-Module Pester -Scope CurrentUser`); Windows ships 3.x, which won't run these. The suite injects a fixture config through `ZCONFIG`, so it never reads your real `zconfig.json` and runs fine on a machine that has never been configured.

The high-value case is the deploy-vs-backup split: **deploys must exclude `.env` files and `uploads/`, backups must keep them.** Get that backwards in either direction and you either ship secrets to production or quietly write backups that can't restore — neither fails loudly at runtime.

## Troubleshooting

- **"zconfig.json not found"** — you haven't copied `zconfig.example.json` yet. Every script tells you this and exits.
- **"Unknown project key"** — the argument doesn't match a key in `zconfig.json`; the error lists the valid keys.
- **"PEM key not found"** — fix `ec2.pemKey` in `zconfig.json`.
- **Deploy aborts with "less than 1.5 GB free"** — the server's disk is full even after auto-pruning. Grow the volume, or SSH in and run `sudo docker system prune -af`.
- **Deploy ends with a version WARNING** — the new build isn't what's being served: check the Docker build output, and see [Enabling deploy verification](#enabling-deploy-verification) if you haven't set it up.
- **Port already in use when starting** — `zkill <project>` first, or just use `zrestart`.

## License

[MIT](LICENSE)
