<!--
Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
Created by Kelly Michels · dev@evomedia.net
Licensed under the MIT License. See LICENSE.
-->

# Elevator Pitch

## The one-liner

**AI coding agents waste thousands of tokens a day on infrastructure orchestration. Token Savers gives you one-word commands to run those parts yourself — so your agent spends tokens on code, not on SSH.**

## The 30-second version

Every time your AI coding agent runs your infrastructure for you — a deploy, a restart, a health check — the full output lands in its context window: Docker layers, SSH banners, health-check chatter. We measured it: an active dev day pushes **~26,500 tokens of pure script output** through the agent, and a single full Docker rebuild adds ~35,000 more. The dollars are small; the context is not — every line of infrastructure noise crowds out the code your agent is supposed to be reasoning about.

Token Savers collapses the infrastructure side into short, one-word commands you run yourself: `zdeploy myapp`, `zrepair myapp`, `zstart myapp`. Describe each project once in `zconfig.json` — where it lives, what kind it is, where it deploys — and every command just knows. You run the deploy; your agent edits the code. You run the health check; your agent reads the result and fixes whatever's wrong.

**Measured: ~26,500 tokens of script output per active development day** — kept out of your agent's context entirely when you run the commands yourself. See [TOKEN_SAVINGS.md](TOKEN_SAVINGS.md) for the per-script measurements and method.

## Why it's different

- **Built around the AI-agent workflow.** The commands are short on purpose — fewer keystrokes for you, fewer tokens when an agent invokes them. But the real saving is the operations you *don't* hand to the agent at all.
- **The project name IS the command.** `zstart blog`, `zdeploy api`, `zbackup store` — no flags to memorize, no switches to wire up.
- **One config file, zero secrets in git.** Server IP, SSH key, paths, and project definitions live in one gitignored JSON. Clone it anywhere, drop in your config, go.
- **It verifies the deploy actually landed.** Not "did the server return 200" (a stale cache does that too) — it checks that the *build number* went live, so you know the code you just shipped is the code that's running.

## Who it's for

Solo developers and small teams running several containerized web apps (Python, Vite, Next.js, plus edge proxies and stock Docker images) on a single VPS or EC2 box, from a Windows dev machine, over SSH — and using AI coding agents to write the code.

## The tagline

*Fewer keystrokes. Fewer tokens. One config to rule your fleet.*
