<!--
Evomedia.net Token Savers — https://github.com/kellymichels/zscripts-token-savers
Created by Kelly Michels · dev@evomedia.net
Licensed under the MIT License. See LICENSE.
-->

# Elevator Pitch

## The one-liner

**AI coding agents waste thousands of tokens a day on infrastructure orchestration. Token Savers gives you one-word commands to run those parts yourself — so your agent spends tokens on code, not on SSH.**

## The 30-second version

Every time you ask an AI coding agent to deploy your app, it burns 15,000–35,000 tokens reading Docker build output, SSH logs, and health-check responses — before writing a single line of code. Do that 10–15 times a day on a rapid dev cycle and you've spent $1.41–$16 just on infrastructure chatter (Sonnet 5 to Fable 5), plus context window space that should go to your actual problem.

Token Savers collapses the infrastructure side into short, one-word commands you run yourself: `zdeploy myapp`, `zrepair myapp`, `zstart myapp`. Describe each project once in `zconfig.json` — where it lives, what kind it is, where it deploys — and every command just knows. You run the deploy; your agent edits the code. You run the health check; your agent reads the result and fixes whatever's wrong.

**Estimated savings: 157,000–540,000 tokens per active development day.** See [TOKEN_SAVINGS.md](TOKEN_SAVINGS.md) for the per-script breakdown and measurement methodology.

## Why it's different

- **Built around the AI-agent workflow.** The commands are short on purpose — fewer keystrokes for you, fewer tokens when an agent invokes them. But the real saving is the operations you *don't* hand to the agent at all.
- **The project name IS the command.** `zstart blog`, `zdeploy api`, `zbackup store` — no flags to memorize, no switches to wire up.
- **One config file, zero secrets in git.** Server IP, SSH key, paths, and project definitions live in one gitignored JSON. Clone it anywhere, drop in your config, go.
- **It verifies the deploy actually landed.** Not "did the server return 200" (a stale cache does that too) — it checks that the *build number* went live, so you know the code you just shipped is the code that's running.

## Who it's for

Solo developers and small teams running several containerized web apps (Python, Vite, Next.js, plus edge proxies and stock Docker images) on a single VPS or EC2 box, from a Windows dev machine, over SSH — and using AI coding agents to write the code.

## The tagline

*Fewer keystrokes. Fewer tokens. One config to rule your fleet.*
