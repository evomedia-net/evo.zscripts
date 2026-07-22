<!--
Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
Created by Kelly Michels · dev@evomedia.net
Licensed under the MIT License. See LICENSE.
-->

# Token Savers — bash port (Linux / macOS / WSL)

Native bash versions of the z-scripts. Same commands, same `zconfig.json` schema,
same behavior — no PowerShell required.

## Requirements

- bash 3.2+ (the stock macOS bash works), `jq`, `curl`, `zip`, OpenSSH (`ssh`/`scp`)
- `lsof` (for `zkill`/`zrestart`), `rsync` (for `zsync <project>` mirror mode)
- Docker + docker compose on the remote host for the deploy scripts

Debian/Ubuntu: `sudo apt install jq curl zip lsof rsync`
macOS: `brew install jq` (bash, curl, zip, ssh, lsof and rsync already ship with macOS)

## Install

```bash
git clone https://github.com/kellymichels/zscripts-token-savers.git ~/zscripts
cd ~/zscripts/bash
cp zconfig.example.json zconfig.json   # then fill in your values
chmod +x z* setup_backup_schedule
echo 'export PATH="$HOME/zscripts/bash:$PATH"' >> ~/.bashrc && source ~/.bashrc
```

## Commands

Same set as the PowerShell versions — the project key in `zconfig.json` IS the
command argument:

| Command | What it does |
|---|---|
| `zstart <p> [--detached]` | start local dev server (python/vite/nextjs) |
| `zkill <p>` | free the project's dev port |
| `zrestart <p> [--detached]` | kill + start in one command |
| `zstop <p>` | stop the project's compose stack on the server |
| `zdeploy <p> [--note "msg"]` | zip → scp → docker compose build/up → verify build version |
| `zec2 [<p>]` | TCP + HTTP + live-version reachability check |
| `zec2online [<p>]` | deep health check; auto-starts downed stacks |
| `zrepair <p>` | audit/repair container + proxy routing, smoke test |
| `zbackup [<p>] [--tag t]` | local source zip (+ pg_dump when .env has DATABASE_URL) |
| `zbackup_ec2 [<p>]` | pull db dump + data dirs down from the server |
| `zsync` | copy new backup files offsite (never overwrites) |
| `zbackup_and_sync` | both of the above; cron-friendly |
| `setup_backup_schedule --install` | daily backup cron job |
| `zsetup_mail --domain d` | provision docker-mailserver mailboxes + print DNS records |
| `zstart_docker` | bring up the local compose stack in `bash/docker/` |

Flags use GNU style (`--port 3000`, `--detached`) instead of PowerShell style
(`-Port`, `-Detached`). Detached dev servers log to `/tmp/zstart-<project>.log`.

## Usage tracking

Every run prints a footer with its own output volume:

```
--- 1,048 lines / 69,009 chars / ~19,717 tokens est. (Claude Code) ---
```

and (when `jq` is available) appends one JSON line per run to `tokens.jsonl`,
so you can see how much infrastructure output you keep out of an AI agent's
context over time. Fields: `ts, script, projects, lines, chars, est, model`
(`est` ≈ `chars / 3.5`). Nested runs (the `zkill`/`zstart` inside `zrestart`)
are counted once, not double.

Where it's written, first match wins:

1. `$ZTOKENS_DATA`
2. `ztokens.dataDir` in `zconfig.json`
3. the sibling `../ztokens/data` directory, if present
4. `~/.ztokens/data` (created on first run)

Set `ZTOKENS_MODEL` to tag records with a specific model; it defaults to
`est. chars/3.5`.

## Differences from the PowerShell versions

- `zsync <viteproject>` mirrors `dist/` with `rsync -a --delete` (robocopy /MIR equivalent).
- Scheduling uses cron (`setup_backup_schedule`) instead of Windows Task Scheduler.
- The MOTD banner picks a random `motd/*.txt` instead of tracking a shuffle rotation.
- Windows-only helpers (`.cmd` launchers) don't exist — scripts are directly executable.
