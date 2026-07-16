# Z-Scripts Summary: Manual Automation to Reduce Token Usage

Running these scripts **manually** instead of asking Claude Code to orchestrate them saves significant token usage because you skip the overhead of Claude reasoning about deployment/build/testing orchestration.

---

## **Local Development Control**

### `zstart.ps1` — Start dev servers
**What:** Starts local dev servers for any project defined in `zconfig.json`
```powershell
zstart viteapp               # Start Vite dev server
zstart pyapp -Port 3000      # Start Python app on custom port
zstart nextapp -Detached     # Start in background
```
**Why run manually:** Eliminates Claude's need to track startup, wait for health checks, or validate ports. You start the server once and Claude just edits files—tokens saved on orchestration, ~150-300 tokens per use.

---

### `zkill.ps1` — Stop dev servers
**What:** Kills Node/Python/Docker processes on specified ports
```powershell
zkill viteapp                # Kill Vite dev server
zkill pyapp nextapp          # Kill multiple projects
```
**Why run manually:** You control when to stop iteration cycles. Saves Claude from having to reason about process cleanup, ~100-200 tokens.

---

### `zrestart.ps1` — Restart in one command
**What:** Calls `zkill` + `zstart` atomically; useful after major changes
```powershell
zrestart viteapp             # Kill + restart Vite app
```
**Why run manually:** Cleaner than telling Claude "stop the server and start it again"—one script handles the sequence. Saves ~200-300 tokens on orchestration logic.

---

## **Build & Deployment**

### `zdeploy.ps1` — Deploy to EC2
**What:** Zips source, SCP to EC2, runs docker compose up, verifies build version
```powershell
zdeploy pyapp -Note "Fix nav alignment"
zdeploy edge                 # Just reload edge nginx config
zdeploy nextapp              # Deploy Next.js app + db
zdeploy all                  # Deploy all projects (edge first)
```
**Why run manually:** Deployment is deterministic once code is ready. You test locally, then run the deploy script—Claude never needs to understand EC2 SSH, zip compression, docker compose, or deployment verification. Saves ~800-1200 tokens that would otherwise go to deployment orchestration.

---

### `zstart_docker.ps1` — Ensure Docker daemon is running
**What:** Starts Docker Desktop if not running (Windows convenience)
**Why run manually:** One-time setup; doesn't need Claude involvement.

---

## **Backup & Sync**

### `zbackup.ps1` — Backup projects locally
**What:** Zips any project defined in `zconfig.json` to the local backups folder with a timestamp
```powershell
zbackup                      # Backup everything + this scripts folder
zbackup viteapp nextapp      # Backup just those two projects
zbackup pyapp -Tag "pre-refactor"
```
**Why run manually:** You decide when to snapshot. Running this yourself before risky changes means Claude never needs to reason about backup strategy or file compression. Saves ~300-500 tokens per session.

---

### `zsync.ps1` — Sync backups to OneDrive
**What:** Robocopy new files from the local backups folder to OneDrive (incremental)
```powershell
zsync                        # Sync all new backup files
zsync viteapp                # Build + mirror vite dist to $env:ZSYNC_DEST
```
**Why run manually:** You manage backup cadence independently. Claude doesn't need to reason about incremental sync logic or file enumeration. Saves ~250-400 tokens.

---

### `zbackup_ec2.ps1` — Remote backups on EC2
**What:** SSH to EC2, tar application and database data, pull to local backups folder
**Why run manually:** Separates database/app backup concerns from code changes. Claude focuses on code; you manage infrastructure snapshots.

---

## **Diagnostics & Troubleshooting**

### `zec2.ps1` — Check EC2 reachability
**What:** TCP + HTTP connectivity tests + live build version for all projects with a `domain`
```powershell
zec2 viteapp                 # Check if Vite app is up on EC2
zec2                         # Test all projects
```
**Why run manually:** When a deploy fails, you run this to verify EC2 is reachable before asking Claude to debug. Eliminates Claude doing network diagnostics blind. Saves ~400-600 tokens of troubleshooting overhead.

---

### `zec2online.ps1` — Deep EC2 health check
**What:** Full health check; auto-starts downed stacks, streams diagnostics
**Why run manually:** Quick check before starting work; Claude doesn't need to validate infrastructure state.

---

### `zrepair.ps1` — Audit & repair container routing
**What:** SSH to EC2, verify nginx proxy routes, check docker compose health, run smoke tests
```powershell
zrepair viteapp              # Audit proxy path + smoke test
zrepair all                  # Audit all projects
```
**Why run manually:** When pages 502, you run this first to isolate whether it's routing, DNS, or app logic. Saves ~1000-1500 tokens of "try this, check logs, try that" debugging.

---

### `zsetup_mail.ps1` — Email account provisioning
**What:** Automates creation of email accounts on EC2; displays Route 53 DNS requirements
**Why run manually:** One-time setup task; doesn't benefit from Claude guidance.

---

## **Token Usage Impact by Script**

| Script | Manual Run Saves | Without Script (Claude orchestrates) |
|--------|-----------------|--------------------------------------|
| **zstart** | ~150-300 tokens | Claude tracks startup, validates ports, polls health |
| **zkill** | ~100-200 tokens | Claude enumerates processes, checks exit codes |
| **zrestart** | ~200-300 tokens | Claude chains stop→wait→start with error handling |
| **zdeploy** | **~800-1200 tokens** | Claude manages zip, SSH, SCP, compose, verification |
| **zbackup** | ~300-500 tokens | Claude enumerates, compresses, manages timestamps |
| **zsync** | ~250-400 tokens | Claude tracks file diffs, runs robocopy, verifies copy |
| **zec2** | ~400-600 tokens | Claude does TCP/HTTP tests, parses output |
| **zrepair** | **~1000-1500 tokens** | Claude SSH, grep logs, run smoke tests, interpret failures |

**Total potential savings per day of active development: 3,000–7,000 tokens** if you run these manually vs. asking Claude to orchestrate.

---

## **Claude Model Token Costs** *(Approximate, May 2026)*

| Model | Input Cost | Output Cost | Use Case |
|-------|-----------|-----------|----------|
| **Haiku 4.5** | ~$0.80/1M | ~$4/1M | Quick code edits, small changes |
| **Sonnet 4.6** | ~$3/1M | ~$15/1M | Daily coding, medium complexity |
| **Opus 4.8** | ~$15/1M | ~$60/1M | Complex reasoning, multi-file refactors |

**Token savings example:**
- Running `zdeploy` manually: ~1000 tokens saved × $15/1M (Sonnet input) = ~$0.015 saved
- Running `zrepair` manually: ~1500 tokens saved × $15/1M = ~$0.0225 saved
- Running all scripts daily: ~5000 tokens × $0.015 = ~$0.075 saved per day, ~$22.50/month

**More importantly:** Manual scripts let Claude focus on *code logic* instead of *infrastructure orchestration*—where Claude adds real value.

---

## **TL;DR**

Run these scripts manually when:
- ✅ You know the exact deployment/test/backup action needed
- ✅ The script is deterministic (same input = same result)
- ✅ You want to parallelize (run zstart while asking Claude for code)
- ✅ You're troubleshooting and need fast feedback loops

Ask Claude to *invoke* them only when:
- ❌ You need complex conditional logic (e.g., "if this test fails, try X")
- ❌ You're chaining many operations that depend on each other's output
- ❌ You want Claude to interpret script output and decide next steps

**Bottom line:** Your z-scripts are optimized for **you** to run directly. Use them. Save tokens. Let Claude focus on coding.
