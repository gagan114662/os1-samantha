# OS1 + Samantha

A fork of [`nickvasilescu/hermes-desktop-os1`](https://github.com/nickvasilescu/hermes-desktop-os1) extended into a single-interface assistant stack: **Samantha** (voice, ElevenLabs) and a **Telegram bot** (text, Claude Code subscription) talk to you; everything else is staff.

> Inspired by *Her* (2013). Built over a weekend of iteration. Not a production system.

---

## Architecture at a glance

```
                          ┌──────────────────────────────┐
                          │           YOU                │
                          └─────────┬────────────────────┘
                                    │  (voice or Telegram)
                                    ▼
                          ┌──────────────────────────────┐
                          │          SAMANTHA            │
                          │  ElevenLabs Convai (voice)   │
                          │  + Claude Code CLI (text)    │
                          │  12 tools wired in           │
                          └─────────┬────────────────────┘
              ┌─────────────────────┼─────────────────────┐
              ▼                     ▼                     ▼
      ┌───────────────┐    ┌────────────────┐    ┌────────────────┐
      │  WUPHF        │    │  Orgo cloud VM │    │  Codex Tasks   │
      │  (AI office)  │    │  (Linux box)   │    │  (companies)   │
      │  CEO / Eng /  │    │  Claude+Codex  │    │  Heartbeat     │
      │  GTM agents   │    │  installed     │    │  loop, audits  │
      └───────────────┘    └────────────────┘    └────────────────┘
              ▲                     ▲                     ▲
              │                     │                     │
     localhost:7891         orgo.ai REST API      ChatGPT subscription
     (npx wuphf)            screenshot stream     (codex CLI on Mac)
```

### Three pillars

1. **Voice agent (Samantha)** — ElevenLabs Conversational AI, system-prompted to be a warm CEO-style chief of staff. Has 12 tools across three categories:
   - **WUPHF**: `wuphf_post`, `wuphf_read`, `wuphf_list_members`, `wuphf_wiki_search` (delegate to AI employees)
   - **Orgo VM**: `orgo_screenshot`, `orgo_bash`, `orgo_click`, `orgo_type`, `orgo_key`, `orgo_list_workspaces`, `orgo_list_computers`, `orgo_create_computer`
2. **Telegram bot** — Mac-local Python daemon that uses your Claude Code subscription (no API key) to act as Samantha when you're on mobile. Uses the same WUPHF bridge.
3. **Codex Tasks** — autonomous "companies" running on heartbeats: each is a `codex exec` invocation in its own git worktree. Every 3rd heartbeat is an adversarial auditor that re-runs commands and forces hallucination corrections.

---

## Repo layout

```
Sources/OS1/                            Swift app (SwiftUI macOS, Package.swift)
  App/                                  AppState, command surface
  Models/                               AppSection, ConnectionProfile, ...
  Services/
    Codex/CodexSessionManager.swift     Companies — heartbeat loop, audits, compaction
    Realtime/                           Voice server (split across 6 files)
    Orgo/                               VM transport + catalog
    Storage/KeychainSecret.swift        Generic Keychain reader
  Views/
    Desktop/                            Screenshot stream + click forwarding
    CodexTasks/                         Companies UI (Tasks tab)
    Doctor/                             Health-check tab with 7 local-stack checks
    ...
Tests/OS1Tests/
  CodexSessionManagerTests.swift        11 focused tests — marker parsing, Codable
  LocalizationCoverageTests.swift       en/ru/zh-Hans key parity
daemons/
  samantha-bot/bot.py                   Telegram bot daemon, uses Claude Code subscription
  coo/daemon.py                         "COO" daemon that polls Codex companies + escalates via Telegram
launchd/                                LaunchAgent plists for all four processes
  com.os1.app.plist
  com.os1.wuphf.plist
  com.os1.samantha-bot.plist
  com.os1.coo.plist
vm-launchers/                           .desktop files for the Orgo VM's Linux desktop
scripts/
  build-macos-app.sh                    Universal binary + ad-hoc sign
  notarize.sh                           Developer-ID + Apple notary submit + staple
```

---

## What goes in your Keychain (not in this repo)

Every credential is read from macOS Keychain. None of these values are stored in source files or plist env vars.

| Service identifier               | What it is                                |
|----------------------------------|-------------------------------------------|
| `ai.orgo.mac.api-key`            | Orgo platform API key                     |
| `io.elevenlabs.api-key`          | ElevenLabs (voice)                        |
| `io.elevenlabs.agent-id`         | Samantha's Convai agent ID                |
| `dev.composio.connect.api-key`   | Composio (Gmail/Reddit/etc OAuth tokens)  |
| `Claude Code-credentials`        | Claude Code subscription (auto-managed)   |
| `org.telegram.bot-token`         | Telegram bot token                        |
| `os1.creds.<platform>` × 14      | Platform passwords for browser automation |

Run the Doctor tab to see what's missing.

---

## What's *not* committed

- `~/.os1/credentials.env` — local-only env file for misc API keys
- `~/.os1/codex-tasks/` — company worktrees, journals, audits, revenue trackers
- `~/.os1/voice-port` — ephemeral port discovery file for the voice server
- `~/.os1/coo/state.json`, `~/.os1/samantha-bot/bot.pid` — runtime state

---

## Setup (broad strokes)

1. `npm install -g wuphf` and run `wuphf --no-open --no-nex --pack starter` once to seed the office.
2. Install Claude Code CLI + Codex CLI (Mac and/or VM).
3. Put your keys in Keychain (use the `Providers` and `Connectors` tabs in OS1).
4. `swift build` + `./scripts/build-macos-app.sh` to produce `dist/OS1.app`.
5. `launchctl load -w ~/Library/LaunchAgents/com.os1.*.plist` to bring all four services up.
6. Talk to Samantha. Or text `@your-bot` on Telegram.

For production distribution, also run `./scripts/notarize.sh` after setting `OS1_CODESIGN_IDENTITY`.

---

## Honest project status

Pre-1.0. Built end-to-end in a long iterative session; many architectural decisions are deliberate trade-offs rather than discoveries. Current operating posture:

- Company heartbeats are scheduled through a fleet pool with a configurable per-VM concurrency cap. A single Orgo VM defaults to 5 concurrent companies; additional Orgo workers scale capacity linearly within the configured cap.
- Voice is gated by ElevenLabs quota — runs out fast in heavy testing
- The heartbeat auditor catches immediate hallucination, and the longitudinal drift evaluator emits drift reports when behavior diverges from mission, baseline, or revenue trajectory.
- Browser automation has consumer-platform domain policy, stealth-profile requirements, user-agent rotation, cookie-jar partitioning, and captcha hand-off. Consumer platforms remain high risk and should still run with explicit operator approval.
- Click forwarding has ~500ms-2.5s latency because frames come from screenshot polling, not VNC
- No multi-user, no auth between you and the voice/bot stack
- Codex Tasks sandbox mode is wrapped by macOS `sandbox-exec`; the nested Codex command still uses
  `--dangerously-bypass-approvals-and-sandbox` so heartbeats can run unattended. See
  [Codex Heartbeat Sandbox Runtime](docs/codex-heartbeat-sandbox.md).

## License

MIT, inherited from upstream `nickvasilescu/hermes-desktop-os1`. Additions in this fork are also MIT.
