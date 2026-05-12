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

## Verification

- CompanyCodexPortfolioInfrastructureTests covers CompanyCodexProfile Codable round-trip, imagegen preference/fallback/cache behavior, required feature enablement, and the runtime tools publishHook, recordRevenue, requestApproval, and publishLesson.
- The Doctor tab includes a Codex feature matrix check built from CompanyCodexProfile.productionDefault, covering imagegen, web, vision, MCP, custom tool registration, sandbox mode, approval modes, resume, streaming, audit timeline, argument hashing, latency tracking, and cost tracking.
- Live Codex CLI smoke runs can still be performed for provider/account confidence, but the repository-level acceptance gate is covered by deterministic profile and runtime-tool tests.
