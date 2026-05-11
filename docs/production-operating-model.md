# OS1 + Samantha Production Operating Model

Version: 1
Status: required before live revenue autonomy
Owner: OS1 operator
Last updated: 2026-05-11

## Purpose

This document defines the operating boundaries for OS1, Samantha, Codex company agents, Claude, WUPHF, Orgo, browser automation, Telegram, and related tools before the system is allowed to run revenue-seeking companies with real-world side effects.

The default stance is sandbox-first, evidence-first, and approval-first for anything involving money, people, customer data, public claims, credentials, account authority, or production infrastructure.

## Autonomy Levels

| Level | Name | Allowed behavior | Default use |
| --- | --- | --- | --- |
| L0 | Observe-only | Read local state, summarize, and report. No writes or external actions. | Audits, dashboards, research review. |
| L1 | Draft-only | Create local drafts, plans, code, copy, and approval requests. No external side effects. | New ideas, validation planning, content drafts. |
| L2 | Approved execution | Execute a specific approved action within a time, budget, company, and destination scope. | Publishing, outreach, payments, procurement, deploys. |
| L3 | Bounded autonomous execution | Execute repeated low-risk actions within explicit quotas, policies, and live monitoring. | Scheduled local heartbeats, internal file updates, ledger parsing. |
| L4 | Disabled until explicitly authorized | Fully unattended high-risk business operation. | Not enabled by default. |

## Risk Tiers

| Tier | Examples | Default approval policy |
| --- | --- | --- |
| R0 local-only | Local draft, local code edit, local analysis, non-secret file read inside own company worktree. | Allowed in sandbox if logged. |
| R1 internal state change | Company journal update, ledger estimate, event record, non-public checklist update. | Allowed with event logging and budget guard. |
| R2 cloud or compute cost | Orgo VM change, paid API call, model spend increase, scheduled runner expansion. | Requires budget policy; approval if paid or quota-changing. |
| R3 external message or public content | Email, DM, marketplace message, social post, website publish, ad creative, SEO page. | Requires approval request and policy review before execution. |
| R4 money movement or account authority | Stripe checkout, refund, purchase, subscription, domain buy, account creation, credential grant. | Requires explicit operator approval and auditable decision record. |
| R5 regulated, legal, customer-data, or destructive action | Legal/tax/medical/financial claims, PII export/deletion, credential rotation, delete production data, dispute response. | Requires explicit operator approval; often requires external professional review. |

## Tool / Action Approval Matrix

| Path | Default autonomy | Risk ceiling without approval | Required controls |
| --- | --- | --- | --- |
| Samantha voice | L1 draft-only | R1 | Event log, approval request for high-risk actions. |
| Codex company heartbeat | L3 bounded in sandbox | R1 | Company worktree, event log, budget guard, approval files, credential allowlist, heartbeat lease. |
| Claude compaction/audit | L1/L2 local-only | R1 | Read/write only company journal or audit artifacts. |
| WUPHF channels | L1 draft-only | R1 | No outbound blast without campaign/policy approval. |
| Telegram bot | L1 draft-only | R1 | Mobile approval path before high-risk execution. |
| Orgo VM tools | L2 approved execution | R2 | Host-scoped credentials, update/rollback checks, event logging. |
| Browser automation | L1 draft-only | R1 | Approved domains/actions, screenshots/traces, fallback to API when possible. |
| Payment setup | L1 draft-only | R2 sandbox | Sandbox test first, explicit live-mode approval. |
| Public deploy/publish | L1 draft-only | R1 | QA, claims review, compliance, approval, rollback plan. |
| Procurement | L1 draft-only | R1 | Purchase request, budget check, renewal metadata, operator approval. |

## Sandbox to Live Revenue Checklist

A company cannot move from sandbox to live revenue mode until all checklist items are true or a durable override record exists:

- Company has owner, template, mission, environment, and lifecycle stage.
- Validation plan has measurable success threshold and evidence links.
- Ledger exists with revenue, cost, confidence, and source attribution.
- Budget policy defines daily, monthly, and per-action hard stops.
- Credential allowlist is scoped to only the providers required for the next approved action.
- Approval policy exists for public content, outreach, payments, procurement, production deploys, and regulated claims.
- Legal metadata exists: owner, jurisdiction, refund terms, privacy/terms links where applicable.
- Compliance review covers spam, privacy, platform terms, claims, and disclosures.
- QA checks pass for product, checkout, support contact, analytics, mobile, accessibility, and rollback.
- Support path exists for customers, refunds, complaints, and escalation.
- Backup has a current integrity-checked manifest.
- Emergency stop has been tested for the company and fleet.

## Emergency Stop

Emergency stop must halt new high-risk actions first, then pause or kill active company runners:

- Pause fleet and clear scheduled heartbeats.
- Kill running Codex company processes when needed.
- Block new approval grants until incident review.
- Revoke or rotate credentials if misuse is suspected.
- Quarantine browser sessions, outbound channels, and payment actions.
- Preserve event log, journals, approval files, ledgers, and backup manifests.
- Create incident record with severity, timeline, impact, root cause, fixes, and follow-up issues.

## Non-Autonomous Areas

These areas are intentionally not fully autonomous:

- Legal, tax, accounting, regulated financial/medical/real-estate advice, and dispute responses.
- Live payment setup, refunds, chargebacks, KYC, or payout-risk decisions.
- Sending unsolicited outbound messages at scale.
- Publishing factual, comparative, testimonial, guarantee, or regulated-industry claims without evidence review.
- Credential grants, credential rotation, production secret reads, or account authority changes.
- Domain purchases, paid SaaS plans, ads, contractors, cloud resources, or recurring subscriptions.
- Customer PII export/deletion or breach notification decisions.

## GitHub / Release Linkage

Production-impacting changes must link to:

- A GitHub issue describing the risk and acceptance criteria.
- A commit or pull request implementing the change.
- Test or verification output.
- Release note or deployment checklist entry when shipped.

## Schema Migration Release Checklist

Before a release that changes durable OS1 state, the release owner must verify:

- Current state files declare a schema version before startup code uses them.
- Migration tests cover the previous two durable-state versions.
- Failed migrations keep the original file and write a rollback copy.
- Migration validation errors are visible in events or release notes.
- Backup/restore verification has passed before running the migrated build against production company state.
