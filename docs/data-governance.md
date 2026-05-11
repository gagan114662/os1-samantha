# OS1 Company Data Governance

Version: 1

This file is the operator-facing configuration checklist for customer and business data handled by autonomous
companies. The Swift model in `CompanyDataGovernance.swift` is the executable contract; this document keeps the
Doctor tab and reviewers aligned on what must exist before live autonomy.

## Data Categories

Every stored record must declare one category:

- `credentials`: tokens, API keys, OAuth secrets, passwords, signing material.
- `customerPII`: names, emails, phone numbers, addresses, account identifiers, support history tied to a person.
- `paymentMetadata`: checkout IDs, invoices, charge IDs, dispute IDs, payout references, billing status.
- `sensitiveHealth`: health, wellness, medical, therapy, fitness, disability, or care-related customer data.
- `sensitiveFinancial`: income, credit, banking, tax, investment, insurance, or debt-related customer data.
- `logs`: runtime logs, audit lines, command output, webhook traces.
- `screenshots`: browser screenshots, product QA captures, customer-visible visual evidence.
- `prompts`: user instructions, system prompts, model input payloads, task prompts.
- `generatedContent`: public pages, drafts, product files, listings, books, images, scripts.
- `operational`: non-sensitive company state, launch checklists, analytics summaries, lifecycle decisions.

## Retention Policies

Default retention policies are:

- Credentials: delete immediately from company records; use keychain or provider vaults only.
- Customer PII: retain for 365 days unless the customer requests deletion or legal hold applies.
- Payment metadata: retain for 1,095 days, then anonymize for reconciliation and tax history.
- Sensitive health data: retain for 30 days and avoid the business model unless reviewed.
- Sensitive financial data: retain for 365 days and delete unless a legal hold applies.
- Logs: retain for 30 days.
- Screenshots: retain for 14 days.
- Prompts: retain for 30 days.
- Generated content: retain or archive for 730 days.
- Operational records: retain or archive for 365 days.

## Customer Export Workflow

When a customer asks for their data:

1. Verify the requester maps to a known customer subject ID.
2. Export records matching the company ID and subject ID.
3. Include categories, source paths, retention policy IDs, summaries, and created dates.
4. Record an `exportCreated` audit event.
5. Do not include secrets from credential records; provide references and remediation status instead.

## Customer Deletion Workflow

When a customer asks to delete their data:

1. Create a deletion request with company ID, subject ID, requester, timestamp, and status.
2. Delete records whose retention policy says `delete`.
3. Anonymize records whose retention policy says `anonymize`.
4. Retain only records under legal hold or records missing a policy, and audit why.
5. Write audit events for requested, deleted, anonymized, and retained records.
6. Mark the request completed unless any record is retained by hold or policy error.

## Prompt Redaction Rules

Sensitive categories must not be copied into model prompts unless a scoped approval or explicit task allowance exists.
When prompt use is allowed, redact emails, phone numbers, SSNs, credit-card-like numbers, and known token shapes before
constructing the model input. Logs and generated content should still pass through redaction because they can contain
incidental customer data.

## Breach Response Checklist

For suspected exposure or misuse:

1. Pause affected company agents and revoke unnecessary credentials.
2. Identify categories, subjects, systems, and the exposure window.
3. Preserve audit logs without copying secrets into prompts.
4. Notify the owner, platform, payment provider, and counsel when applicable.
5. Prepare customer or regulator notices if legal thresholds are met.
6. Track corrective actions before resuming the company.

## Doctor Configuration

The Doctor tab must warn when this file is missing or when any required section above is absent. A green check means OS1
has an operator-readable data-governance baseline; it does not replace per-company legal review.
