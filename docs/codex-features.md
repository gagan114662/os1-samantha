# Codex Features In Company Runtime

This document tracks which Codex CLI capabilities the company heartbeat can invoke directly.

## Current Runtime Surface

- Image generation: routed through `CompanyImageGenerator.default`; the default provider is Codex imagegen and usage is attributed to Codex.
- Web and vision: represented in `CompanyCodexProfile` for per-company capability gates and smoke-test planning.
- MCP: Composio and company tools are intended to flow through Codex MCP routing rather than parallel direct API calls.
- Sandboxes: `CompanyCodexProfile.sandboxMode` records the required runtime boundary for a company heartbeat.
- Resume: `CompanyCodexProfile.resumeEnabled` records whether long-running heartbeats can resume from checkpoint.
- Streaming: `CompanyCodexProfile.streamingEnabled` records whether a heartbeat can stream progress into the timeline.
- Approval modes: `CompanyCodexProfile.approvalMode` records the per-company approval posture.
- Feature matrix: `CompanyCodexProfile.Feature` currently enumerates 60 runtime gates, including imagegen, web, vision, MCP, custom tools, tool search, apply-patch, browser/chrome/computer use, connectors, skills, plugins, fanout, approval guardians, audit/cost/latency tracking, checkpointing, portfolio lessons, marketplace adapters, and payment webhooks.

## Company Runtime Tools

- `publishHook` promotes a hook into `CompanyHookLibrary`.
- `recordRevenue` writes a verified `CompanyLedgerEntry`.
- `requestApproval` writes an approval event.
- `publishLesson` appends to the portfolio lesson bus.

## Remaining Live Validation

- Codex imagegen smoke test must run against the real Codex CLI and produce an image artifact in a company worktree.
- Web, vision, MCP bridge, custom tool registration, sandbox enforcement, approval graduation, resume, and streaming need live heartbeat smoke tests.
- Doctor UI still needs a per-company Codex feature matrix wired to the profile data.
