# Hermes Desktop - OS1 Edition

> **OS1 by Element Software** · powered by Orgo · forked from Hermes Desktop

OS1 is a Mac app for working with Samantha, a virtual employee that can
use AI tools, the internet, files, a terminal, and cloud computers.

Think of Samantha like a very smart helper inside a computer. You can
give her a goal, such as "test this business idea" or "build a tiny
website." OS1 gives her a safe place to work, shows you what she is
doing, and makes her ask before she does risky things like spend money,
publish online, message people, or use private credentials.

OS1 does not magically guarantee profit. It is built to help Samantha
try business ideas carefully: make a plan, collect proof, track costs,
track revenue, and stop when something is unsafe or not working.

The original Hermes Desktop app focused on controlling an AI agent over
SSH. OS1 adds Orgo cloud computers, a native terminal, voice mode, and
Samantha company mode for running many supervised business experiments.

## Explain It Like I Am 10

- **Samantha** is the worker.
- **OS1** is her control room.
- **A cloud computer** is the computer she works inside.
- **A company** is one small business experiment, like a YouTube helper,
  an Etsy digital product shop, a newsletter, a tiny software tool, or a
  research service.
- **A heartbeat** is Samantha checking in and doing the next bit of work.
- **An approval gate** is a locked door. Samantha must ask before she
  spends money, sends messages, publishes public content, or uses
  important secrets.
- **A ledger** is the score sheet for money in and money out.
- **Doctor checks** are safety checks that tell you whether the setup is
  ready for more serious use.

## What you get

- **Cloud computers, end to end**: paste your API key once, pick a
  workspace, pick a computer (or create one), save. The app talks
  directly to the platform's HTTP API and the per-VM websocket
  terminal — no SSH, no gateway, no helper service on the VM.
- **One-click agent install** on a fresh computer. The first time you
  open the workspace and the agent isn't there, the Overview screen
  surfaces an "Install Hermes Agent" button. ~60–90 seconds later
  Sessions, Kanban, Files, Skills, and Cron all populate.
- **Real interactive shell** over the per-VM terminal websocket.
  Bytes stream in real time; resize works; output and history reflow
  cleanly.
- **SSH connections still supported** for hosts you reach over SSH
  today. Same flow as the upstream Hermes Desktop fork OS1 was built
  on.
- **Everything else** from the foundation: native Sessions browser
  with full-text search, Kanban board, file editor with conflict
  checks, skills viewer, cron job manager, profile-aware paths,
  English / Simplified Chinese / Russian localization scaffolding.
- **Samantha company mode**: OS1 can launch supervised Codex-backed
  "companies" from the Tasks tab. Each company gets a mission, its own
  git worktree, heartbeat cadence, journal, revenue ledger, approval
  files, event timeline, and budget guard. The built-in catalog includes
  100 starter templates across content, digital products, SaaS,
  services, newsletters, marketplaces, and automation agencies.

## Samantha / Codex company mode

The Tasks tab is the operating console for Samantha's company runners.
A runner is not just a chat thread. It is a durable company record with
a scoped worktree, a heartbeat lease, a log, a journal, a ledger,
approval state, and a run timeline.

OS1 dispatches heartbeats through `CompanyFleetScheduler` with a default
per-VM cap of 5. Total concurrent companies = configured workers × cap. On
a single-Orgo-VM setup that's 5; with N Orgo workers it's 5N. Tune via
`~/.os1/portfolio/fleet.json`.

Current foundations:

- **Sandbox-first execution**: new companies default to sandbox mode.
  Codex heartbeats are wrapped by generated macOS `sandbox-exec`
  profiles so a company can mutate only its own worktree, prompt/log
  files, and approved shared lessons file. The exact runtime contract is
  documented in [Codex Heartbeat Sandbox Runtime](docs/codex-heartbeat-sandbox.md).
- **Least-privilege credentials**: companies start with no platform
  credentials. You can grant or revoke specific provider credential
  names per company. Secret reads are audited by name/count only; secret
  values are not written into prompts, event metadata, or heartbeat log
  headers.
- **Approval gates**: companies must write approval request files and
  block before spending money, publishing public content, messaging
  people, touching credentials, making regulated claims, or changing
  production infrastructure.
- **Observability**: OS1 writes append-only company events with run IDs,
  actor, tool, input hash, output summary, latency, risk tier, approval
  state, and redacted metadata. The company detail sheet shows the run
  timeline, command/log references, output tail, and metrics.
- **Reliability controls**: per-company heartbeat leases and atomic lock
  files prevent duplicate heartbeats across duplicate app/launchd starts.
  Restart recovery queues active leases instead of replaying work
  immediately, and stale locks can be recovered after crashes.
- **Provider failover matrix**: Codex/OpenAI remains the default company
  runtime, but request classes have explicit fallback posture: chat/tool
  work can route through alternate model providers, embeddings can queue
  or downshift when org headroom is low, image generation uses Codex
  imagegen first and an operator-permitted alternate only during quota or
  outage events, and voice work queues cleanly when no approved provider
  is healthy. Every provider attempt records provider, model, request
  class, and attempt number so Doctor can show green/yellow/red health by
  provider and request class.
- **Portfolio controls**: fleet pause/resume, per-company pause/resume,
  kill heartbeat, remove company, local state backups, revenue/cost
  ledger summaries, and Doctor production checks.
- **Validation before building**: ideas must show evidence such as
  customer conversations, reply rates, signup rates, willingness to pay,
  competitor research, screenshots, raw notes, and source links before
  Samantha treats them as ready to build.

The system is designed to make real-world autonomy inspectable and
revocable. It does not make business success automatic, and it should
not be allowed to perform high-risk live actions without explicit
operator approval.

## What Samantha Can Reliably Use Today

Inside OS1, Samantha can work with these reliable building blocks:

- Cloud computers through Orgo.
- A real terminal and file workspace.
- Codex-backed company heartbeats.
- Git worktrees for separate company projects.
- Journals, ledgers, event logs, and run timelines.
- Approval request files for risky actions.
- Per-company credential allowlists.
- Budget guards and lifecycle gates.
- A catalog of 100 company templates.
- Voice mode through OpenAI Realtime when an OpenAI key is configured.

Other tools, websites, and accounts can be connected, but OS1 treats
them as sensitive. Samantha should use them only with explicit operator
approval and clear limits.

## Requirements

- macOS 14 or newer (Apple Silicon or Intel — universal build)
- One of:
  - An **Orgo account** with an API key (the cloud-computer infra
    powering OS1 — get a key at
    [orgo.ai/settings/api-keys](https://www.orgo.ai/settings/api-keys)),
    OR
  - A host you already reach with `ssh` from this Mac without
    interactive prompts (same flow as upstream Hermes Desktop)

For cloud computers, the app handles VM provisioning, agent
installation, and the websocket terminal automatically. For SSH
connections, the host needs `python3` on the non-interactive SSH PATH
and Hermes already installed.

## Install

Download the latest `OS1.app.zip` from the GitHub Releases page,
unzip it, drag `OS1.app` into `/Applications`, and launch.

The build is universal (Apple Silicon + Intel) and ad-hoc signed.
On first launch macOS may say it can't verify the developer — right-click
the app, choose Open, and confirm.

## Setup

### Cloud computer (recommended)

1. Open the **Connections** tab → click **Add Host**
2. Switch the transport picker to **Orgo VM**
3. Paste your API key → click **Verify & Save**. The key persists in
   the macOS Keychain; subsequent connections reuse it.
4. Pick a workspace from the dropdown.
5. Pick a computer, or click **Create new computer…** to spin one up
   inline (defaults: Linux, 8 GB RAM, 4 CPU, 50 GB disk).
6. Save → the connection is selectable from the host list.
7. If the agent isn't installed on the VM, the **Overview** screen
   shows an install banner. One click runs the official Hermes
   Agent installer. You can use the rest of the app while it runs.

### Stripe webhooks for WUPHF

The WUPHF LaunchAgent runs WUPHF behind the OS1 localhost proxy so OS1 can
own native payment webhook routes while the WUPHF UI still listens on
`localhost:7891`. Run `make install` after cloning or pulling to render the
LaunchAgent templates for your local checkout and reload them. Save the Stripe
webhook secret in OS1 Payments or set `STRIPE_WEBHOOK_SECRET`, then forward
Stripe events to:

```sh
stripe listen --forward-to localhost:7891/webhooks/stripe
```

OS1 exposes `POST /webhooks/stripe` for signed events and
`GET /api/stripe/status` to report whether the webhook secret is configured.
Accepted Stripe events are verified with the `Stripe-Signature` header,
deduplicated, logged through `~/.os1/wuphf.log`, and appended to the company
ledger when the event metadata includes `company_id`. ElevenLabs credentials
are only required for voice conversations; Stripe webhook ingestion uses the
same local HTTP server but does not require voice configuration.

### SSH

Add a connection and switch the transport picker to **SSH**. Alias or
host, optional user/port, optional Hermes profile.

## Build from source

```sh
make install
```

`make install` builds `dist/OS1.app`, renders `launchd/*.plist.template` into
`~/Library/LaunchAgents`, and reloads changed agents. Use
`OS1_SKIP_LAUNCH_AGENTS=1 ./scripts/build-macos-app.sh` when you only want a
bundle build without installing LaunchAgents.

The bundle lands at `dist/OS1.app`.

```sh
swift test
```

At the time this README was updated, the local suite passed with 441
tests, including focused coverage for company sandbox isolation,
credential redaction, Doctor production checks, event metrics, heartbeat
locks, stale-lock recovery, restart recovery, validation policy,
factory gates, distribution policy, lifecycle gates, and ledger guards.

## Realtime voice mode

OS1 includes a minimal WebRTC voice mode using OpenAI Realtime calls
with `gpt-realtime-2`. The app starts a loopback session endpoint when
the boot animation finishes. The bottom-left **Voice** row toggles the
live voice connection on or off; there is no separate voice control
panel.

The browser surface in the app sends raw SDP to `POST /session`. The
Swift endpoint keeps `OPENAI_API_KEY` server-side, forwards the SDP to
`https://api.openai.com/v1/realtime/calls`, and uses multipart
`FormData` fields named `sdp` and `session`.

Use the **Providers** tab to save an OpenAI key in the macOS Keychain.
For local development, `OPENAI_API_KEY` is also supported as a fallback.

Run from source with an environment fallback:

```sh
OPENAI_API_KEY="sk-..." swift run OS1
```

Run the packaged app from a shell with an environment fallback:

```sh
./scripts/build-macos-app.sh
OPENAI_API_KEY="sk-..." ./dist/OS1.app/Contents/MacOS/OS1
```

The packaging script signs ad-hoc with an explicit designated
requirement for `com.elementsoftware.os1`, which gives macOS a stable
local app identity so privacy grants such as microphone access can
survive rebuilds. For a stronger certificate-backed identity, set
`OS1_CODESIGN_IDENTITY` / `HERMES_CODESIGN_IDENTITY`, or set
`OS1_AUTO_CODESIGN=1` to use the first available `Apple Development`
identity.

After the boot animation completes, the hidden WebRTC view requests
microphone access, opens the `oai-events` data channel, registers a sample
`check_calendar(date, time)` function with `session.update`, and asks
the model to greet with `hello, can you hear me?`.

The same voice session also exposes Orgo MCP tools to the model as
Realtime function tools. OS1 starts the MCP server locally, reads tools
with `tools/list`, registers them with `session.update`, and forwards
model tool calls back to `tools/call`; Orgo credentials stay in the
Swift app and are never sent to the browser or model. By default the
Realtime voice bridge exposes `core,screen,files`, disables file upload,
uses the saved Orgo API key in OS1 or `ORGO_API_KEY` if no key is saved,
and passes the active Orgo connection's computer ID as
`ORGO_DEFAULT_COMPUTER_ID`.

Voice mode runs `npx -y @orgo-ai/mcp` by default. You can override the
bridge with:

```sh
OS1_ORGO_MCP_JS_PATH="/absolute/path/to/dist/index.js"
OS1_ORGO_MCP_PACKAGE="@orgo-ai/mcp"
OS1_REALTIME_ORGO_TOOLSETS="core,screen,files"
OS1_REALTIME_ORGO_DISABLED_TOOLS="orgo_upload_file"
OS1_REALTIME_ORGO_READ_ONLY="true"
```

`shell` and `admin` are opt-in through `OS1_REALTIME_ORGO_TOOLSETS`.
Only enable them for agents and computers you are comfortable letting a
voice model operate.

Live integration tests (skipped by default) hit a real cloud computer:

```sh
ORGO_LIVE_TESTS=1 \
ORGO_API_KEY="sk_live_..." \
ORGO_DEFAULT_COMPUTER_ID="<uuid>" \
swift test --filter OrgoTransportLiveTests
```

## How it routes

For cloud connections:

1. **HTTP ops** (`/bash`, `/exec`) try the platform proxy at
   `https://www.orgo.ai/api/computers/{id}/...` first. On a 5xx
   that looks like a routing failure (ECONNREFUSED, gateway timeout,
   stale port), the transport falls back to the direct VM URL
   `https://<fly_instance_id>.orgo.dev/...` with the VNC password as
   bearer. Long-running ops (e.g. the agent installer) skip the
   proxy entirely since its 30s request timeout would always trip
   first.
2. **Terminal** opens a websocket directly to
   `wss://<fly_instance_id>.orgo.dev/terminal?token=<vncPassword>`,
   feeding bytes into SwiftTerm.

VM clock drift, missing system git, stale apt locks from earlier
attempts — all handled in the install path so you don't have to wrestle
with the VM by hand.

## Acknowledgements

OS1 builds on two layers of generous prior work:

- The original native macOS application code is forked from
  [dodo-reach/hermes-desktop](https://github.com/dodo-reach/hermes-desktop),
  the SSH-first companion for the Hermes Agent. The conventions, panels,
  discovery model, and most of the SSH-side code are that author's
  design.
- The cloud-computer transport, websocket terminal, agent auto-install,
  and connection picker were added on top to make OS1 work directly
  with Orgo VMs.

The visual design language (coral on cream, DM Sans, OS¹ wordmark) is
the **Element Software** product theme — see [`OS-1`](https://github.com/nickvasilescu/OS-1)
for the canonical palette and motion vocabulary that this app borrows.

License: [MIT](LICENSE). All upstream copyrights are preserved.

## Status

This is still an early build. The Samantha company path now has real
guardrails: sandboxed Codex heartbeats (see
[Codex Heartbeat Sandbox Runtime](docs/codex-heartbeat-sandbox.md)),
per-company credential
allowlists, approval gates, append-only event logs, run timelines,
revenue ledgers, validation gates, factory gates, distribution policy,
budget guards, heartbeat locks, restart recovery, Doctor production
checks, and local backups.
Durable session state is schema-versioned at startup, migrated from the
previous two formats with validation, and protected by pre-migration
rollback copies.

Still in progress: translation polish, GitHub Pages site,
certificate-backed signing/notarization, broader role-based permissions,
encrypted backup/restore drills, content quality review, compliance
policy, accounting export, customer support flows, payments risk controls,
and production deployment channels. Track the open GitHub issues before
relying on OS1 for unattended live revenue operations.
