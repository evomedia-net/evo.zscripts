<!--
Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
Created by Kelly Michels · dev@evomedia.net
Licensed under the MIT License. See LICENSE.
-->

# Token Savings: Why You Should Run These Scripts Yourself

Running these scripts **manually** keeps their output out of your AI coding agent's
context window. Every line the agent doesn't have to read is a token you don't
pay for — and a token the agent can spend on the actual problem instead of on
deployment sequencing, SSH output, and Docker health checks.

This document reports two baselines side by side:

- **You run it → Claude runs the script.** What Claude ingests if it invokes the
  z-script as a single command. These figures are **measured** (see method below).
- **You run it → Claude orchestrates raw.** What Claude would ingest if the scripts
  didn't exist and it drove `scp` / `ssh` / `docker compose` step by step itself.
  These figures are **estimates** — the same command output *plus* the agent's
  reasoning and retry logic across every discrete step.

The savings from running a script yourself is the first column: if you run it,
Claude ingests **zero**. The extra value of *having* the scripts at all is the gap
between the two columns.

Dollar equivalents use a blended input/output rate: **Sonnet 5 ≈ $9/1M** | **Opus 4.8 ≈ $15/1M** | **Fable 5 ≈ $30/1M**

> **Measurement note:** "Measured" figures come from `token-count.ps1`, which runs
> each script under `Start-Transcript` and counts output characters ÷ 3.5
> chars/token. Captured in **Claude Code (Sonnet 4.6)** against the `sp` project.
> Strictly speaking that's *measured output volume with estimated tokenization*:
> ÷3.5 is a prose heuristic, and code-heavy output (paths, JSON, container IDs)
> fragments into **more** tokens per character under a real BPE tokenizer — so the
> token figures here are likely conservative. "Estimated (raw)" figures are *not*
> measured — they approximate manual orchestration and are marked *est.*
> throughout. Other models/interfaces tokenize differently.

---

## Measured per-run output (script-run baseline)

The bold figures below are real captures from `token-count.ps1 sp`; rows flagged *est.* are not:

| Script | Measured tokens/run | Notes |
|--------|--------------------:|-------|
| `zec2online` | **267** | reachability + version check |
| `zec2` | **331** | EC2 TCP/HTTP + build match |
| `zbackup_ec2` | **334** | pull server backup |
| `zrepair` | **364** | clean audit; more if it restarts containers |
| `zkill` | **377** | free the dev port |
| `zbackup` | **436** | local project snapshot |
| `zrestart` | **724** | kill + restart (detached) |
| `zstart` | **762** | start dev server (detached) |
| `zsync` | **769** | mirror backups offsite |
| `zdeploy` *(cached)* | **~810** | 53s deploy, layers cached |
| `zdeploy` *(full rebuild)* | **~34,600** *est.* | packages changed; streams full docker build |
| `zstart_docker` | *not measured* | est. ~500–1,500 |

**Cache state is what drives `zdeploy`.** A *cached* deploy is **~810 tokens**; the
large number only appears on a **full rebuild** (dependencies changed), which streams
the entire docker build. During rapid deploy → test → fix iteration almost every run
is cached, so ~810 is the realistic per-run cost — with occasional spikes when you
change packages.

---

## Local Development Control

### `zstart` — Start dev servers
**Measured: ~762 tokens/run** | est. raw orchestration: ~1,500–3,000 | typical 2–3 runs/day

Run it yourself and Claude sees none of the version-bump, MOTD, and startup output.
If Claude started the server raw, it would also wait on health checks and confirm
the port is listening — reasoning the script does deterministically.

```powershell
zstart viteapp               # start Vite dev server on its configured port
zstart pyapp -Port 3000      # override the port
zstart nextapp -Detached     # start in background, prompt returns
```

---

### `zkill` — Stop dev servers
**Measured: ~377 tokens/run** | est. raw orchestration: ~1,000–2,000 | typical 2–3 runs/day

Raw, Claude would enumerate processes, kill them, and re-check the port is free.
The script collapses that to one command.

```powershell
zkill viteapp
zkill pyapp nextapp
```

---

### `zrestart` — Restart in one command
**Measured: ~724 tokens/run** | est. raw orchestration: ~2,500–4,500 | typical 10–15 runs/day

The most-used command during rapid iteration. Raw, it's stop → wait → start with
error handling at each hop — several tool calls and their reasoning. As one script
it's a single call, and the `-Detached` switch now propagates correctly through the
kill→restart chain so the server backgrounds cleanly.

```powershell
zrestart viteapp
zrestart pyapp -Detached
```

---

## Build & Deployment

### `zdeploy` — Deploy to EC2
**Measured: ~810 tokens/run cached** *(spikes to ~34,600 on a full rebuild)* | est. raw orchestration: ~5,000–12,000 cached, ~35,000+ full rebuild | typical 10–15 runs/day

The biggest lever — and the one where cache state matters most. The script *streams*
the docker/SSH output whether Claude runs it or not, so a cached deploy really is only
~810 tokens even through Claude. The raw-orchestration cost is higher not because of
extra output but because Claude would reason between ~15 discrete steps (zip, preflight
cleanup, scp, unzip, build, up, version bump, restart, verify) and handle retries
itself. Running it yourself zeroes out all of that.

Measured cached: three runs at 808 / 858 / 808 tokens (53–54s each). The full-rebuild
figure (~34,600) is an estimate for package-change deploys — treat it as the upper
bound.

```powershell
zdeploy pyapp -Note "Fix nav alignment"
zdeploy edge                 # reload edge nginx config
zdeploy all -Note "weekly release"
```

---

### `zstart_docker` — Start local Docker stack
**Not measured** (est. ~500–1,500 tokens/run) | typical 1 run/day

One-time setup per session; doesn't need agent involvement.

---

## Backup & Sync

### `zbackup` — Backup projects locally
**Measured: ~436 tokens/run** | est. raw orchestration: ~1,200–2,500 | typical 1–2 runs/day

Raw, Claude enumerates files, decides exclusions, compresses, and stamps timestamps.
You decide when to snapshot.

```powershell
zbackup                          # everything + scripts folder
zbackup pyapp -Tag "pre-refactor"
```

---

### `zsync` — Sync backups offsite
**Measured: ~769 tokens/run** | est. raw orchestration: ~1,500–3,000 | typical 1 run/day

Raw, Claude tracks file diffs, runs robocopy, and verifies the copy. You manage
cadence independently.

```powershell
zsync
zsync viteapp                    # build + mirror dist to $env:ZSYNC_DEST
```

---

### `zbackup_ec2` — Pull backups from the server
**Measured: ~334 tokens/run** | est. raw orchestration: ~1,000–2,000 | typical 1 run/day

Separates database/app backup from code changes. Claude focuses on code; you manage
infrastructure snapshots.

```powershell
zbackup_ec2
```

---

## Diagnostics & Troubleshooting

### `zec2` — Check EC2 reachability
**Measured: ~331 tokens/run** (`zec2online`: ~267) | est. raw orchestration: ~1,000–2,000 | typical 5–8 runs/day

When a deploy fails you run this first to confirm EC2 is reachable and the right
build is live — before asking Claude to debug. Raw, that's blind network diagnostics
over SSH. Runs frequently alongside `zdeploy`.

```powershell
zec2 viteapp
zec2                             # check all projects
zec2online sp                    # lightweight HTTP-only variant
```

---

### `zrepair` — Audit & repair container routing
**Measured: ~364 tokens/run (clean audit)** | est. raw orchestration: ~2,000–4,000 | typical 1–2 runs/day

When a page 502s, this isolates routing vs. DNS vs. app logic across several
containers — rather than handing Claude an SSH session to figure out blind. The
364-token figure is a healthy run with nothing to repair; a run that actually
restarts containers emits more. Raw, Claude would SSH per container and reason
across each check.

```powershell
zrepair viteapp
```

---

## Daily Token Savings Summary

Per-run × runs/day, using midpoint run counts. The **measured** column is the real
savings from running scripts yourself; the **est. raw** column approximates what
Claude would burn orchestrating the same work with no scripts.

| Script | Measured/run | Runs/day | Measured/day | Est. raw/day |
|--------|-------------:|:--------:|-------------:|-------------:|
| `zstart` | 762 | 2–3 | ~1,900 | ~3,800–9,000 |
| `zkill` | 377 | 2–3 | ~940 | ~2,500–6,000 |
| `zrestart` | 724 | 10–15 | ~9,050 | ~31,000–68,000 |
| `zdeploy` *(cached)* | ~810 | 10–15 | ~10,100 | ~62,000–180,000 |
| `zec2` (+`online`) | ~330 | 5–8 | ~2,200 | ~6,500–16,000 |
| `zbackup` | 436 | 1–2 | ~650 | ~1,800–5,000 |
| `zsync` | 769 | 1 | ~770 | ~1,500–3,000 |
| `zbackup_ec2` | 334 | 1 | ~330 | ~1,000–2,000 |
| `zrepair` | 364 | 1–2 | ~550 | ~3,000–6,000 |
| **Total (active dev day)** | | | **~26,500** | **~115,000–295,000** *est.* |

The **~26,500 tokens/day measured** is the honest, reproducible savings from running
these yourself during an active tool-development day (mostly cached deploys). The
**~115k–295k est.** upper figure is what it would cost to have Claude drive the raw
`ssh`/`docker` sequences instead — dominated by per-step reasoning on `zdeploy` and
`zrestart`, not by output volume. Treat that column as an **upper bound, not a
prediction**: a capable agent asked to deploy might well write its own wrapper
script and ingest very little — the counterfactual depends entirely on how the
agent chooses to work. A day with several full-rebuild deploys pushes the measured
figure higher too, since each rebuild streams ~34,600 tokens.

**Daily dollar savings during active tool development:**

Script output the agent ingests is billed at **input** rates, so the measured column
uses input pricing. The est.-raw column keeps the **blended** rate, because raw
orchestration also generates agent *output* (reasoning and tool calls between steps).

| Model | Measured/day @ input rate | Est. raw/day @ blended rate |
|-------|--------------------------:|----------------------------:|
| **Sonnet 5** | ~$0.08 ($3/1M) | ~$1.04–$2.66 ($9/1M) |
| **Opus 4.8** | ~$0.13 ($5/1M) | ~$1.73–$4.43 ($15/1M) |
| **Fable 5**  | ~$0.27 ($10/1M) | ~$3.45–$8.85 ($30/1M) |

One-time ingest slightly understates the true cost: tokens that enter the context are
re-sent on every later turn of the session (at cheaper cache-read rates when prompt
caching applies), so the cumulative figure is somewhat higher than a single ingest.

Over a ~22-day working month, the measured savings run **~$2–$6/mo** (Sonnet →
Fable); the raw-orchestration estimate runs **~$23–$195/mo**. The honest dollar
figure is small — the real currency is **context**: every infrastructure token kept
out of the window is context your agent keeps for the actual problem, and that's
worth more than the dollars suggest.

---

## Claude Model Token Costs *(July 2026)*

| Model | Input | Output | Typical use |
|-------|-------|--------|-------------|
| **Haiku 4.5** | $1/1M | $5/1M | Quick edits, small changes |
| **Sonnet 5** | $3/1M | $15/1M | Daily coding, medium complexity |
| **Opus 4.8** | $5/1M | $25/1M | Complex reasoning, multi-file refactors |
| **Fable 5** | $10/1M | $50/1M | Advanced reasoning, agentic workflows |

---

## When to Run Scripts Yourself vs. Ask the Agent

**Run yourself when:**
- ✅ You know exactly what action is needed
- ✅ The script is deterministic (same input = same output)
- ✅ You want to parallelize — run `zstart` while asking Claude for code
- ✅ You're troubleshooting and need fast feedback loops

**Ask the agent when:**
- ❌ You need conditional logic ("if this test fails, try X")
- ❌ You're chaining operations that depend on each other's output
- ❌ You want the agent to interpret script output and decide next steps

**Bottom line:** These scripts are optimized for you to run directly. Use them. Save
tokens. Let Claude focus on coding.
