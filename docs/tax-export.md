# Tax export pipeline

Filing-ready accounting exports for every legal entity OS1 operates. One bundle
is produced per **(entity × jurisdiction × tax year)** triple. Implementation
lives in `Sources/OS1/Models/CompanyTaxExport.swift` (Swift, in-app) and
`scripts/export-tax.py` (Python, headless CI). Both implementations write the
same on-disk schema and are deterministic.

> Tracking issue: [#191](https://github.com/gagan114662/os1-samantha/issues/191).
> Filing remains operator-only; this pipeline never auto-submits.

## Architecture

```
~/.os1/entities.json           ledger.json (per-company)         contractors.json
        │                              │                                 │
        ▼                              ▼                                 ▼
                       ┌────────────────────────────────────┐
                       │       TaxExportPipeline             │
                       │  • normalize currencies (FX table) │
                       │  • filter by fiscal year + active  │
                       │  • allocate across jurisdictions   │
                       │  • emit deterministic files        │
                       └────────────────────────────────────┘
                                       │
                ┌──────────────────────┼──────────────────────┐
                ▼                      ▼                      ▼
        US-FED bundle           US-CA bundle           Non-US bundle (DE, GB, …)
        Schedule C / 1120       sales-tax + 540-ES     generic CSV (locale headers)
        + 1099-NEC register     + quarterly estimates
        + quarterly estimates
```

## Entity registry — `~/.os1/entities.json`

`TaxEntityRegistry`:

```json
{
  "entities": [
    {
      "id": "operator-personal",
      "legalName": "Jane Operator",
      "entityType": "sole-proprietor",
      "primaryJurisdiction": "US-FED",
      "additionalJurisdictions": ["US-CA"],
      "itin": "xxx-xx-1234",
      "fiscalYearStartMonth": 1,
      "incorporatedAt": null,
      "dissolvedAt": null,
      "baseCurrency": "USD",
      "allocation": {"kind": "revenueProportional", "weights": {"US-FED": 1.0, "US-CA": 0.4}}
    },
    {
      "id": "llc-acme",
      "legalName": "Acme Holdings LLC",
      "entityType": "llc-single-member",
      "primaryJurisdiction": "US-FED",
      "additionalJurisdictions": [],
      "ein": "12-3456789",
      "fiscalYearStartMonth": 1,
      "incorporatedAt": "2025-07-01T00:00:00Z",
      "dissolvedAt": null,
      "baseCurrency": "USD",
      "allocation": {"kind": "primaryOnly"}
    }
  ],
  "companyToEntity": {
    "co-blog-llc": "llc-acme",
    "co-courses-llc": "operator-personal"
  }
}
```

### `entityType` values

| Value                 | US filing form                          |
|-----------------------|------------------------------------------|
| `sole-proprietor`     | Schedule C (attached to Form 1040)       |
| `llc-single-member`   | Schedule C (disregarded entity)          |
| `llc-multi-member`    | Form 1065 (partnership)                  |
| `c-corp`              | Form 1120                                |
| `s-corp`              | Form 1120-S                              |
| `foreign-entity`      | Form 1120-F                              |

### `allocation`

Allocation rule for entries that don't pin themselves to a single jurisdiction:

- `{"kind": "primaryOnly"}` — everything lands in `primaryJurisdiction`.
- `{"kind": "equalSplit"}` — every active jurisdiction gets `1/N` of the amount.
- `{"kind": "revenueProportional", "weights": {"US-FED": 0.6, "US-CA": 0.4}}` — weights
  are normalized to sum to 1.0 across the active jurisdictions. Missing jurisdictions are zero.

A ledger line may set its own `jurisdiction` field (e.g. for a sale physically
shipped to California); that pin overrides the allocation rule.

## Ledger line schema — `ledger.json`

Array of `TaxLedgerLine`:

```json
[
  {
    "id": "stripe-cs_abc123",
    "entityID": "llc-acme",
    "occurredAt": "2025-08-15T14:22:00Z",
    "kind": "revenue",                              // revenue | cost | refund
    "category": "sales",                            // CompanyLedgerEntry.Category
    "amount": 1499.00,
    "currency": "USD",
    "jurisdiction": "US-CA",                        // optional pin
    "counterparty": "customer@example.com",
    "memo": "Pro plan annual"
  }
]
```

Currencies are normalized to USD using the FX table (`--fx-rates`); USD passes
through unchanged. Unknown currencies cause the pipeline to abort.

## Contractor payments — `contractors.json`

Drives 1099-NEC / 1042-S register generation:

```json
[
  {
    "id": "pay-1",
    "payerEntityID": "llc-acme",
    "recipientName": "Alpha Contractor",
    "recipientTaxID": "xxx-xx-1234",
    "recipientCountry": "US",
    "amountUSD": 1200.00,
    "isUSResident": true
  }
]
```

Threshold: payments `>= $600` to a US-resident contractor are emitted as
`1099-NEC`; non-US-resident recipients emit `1042-S` with `withholding_required=yes`.

## FX rate fixture — `fx-rates.json`

```json
{
  "asOf": "2025-12-31T23:59:59Z",
  "rates": {"EUR": 1.10, "GBP": 1.27, "CAD": 0.74, "JPY": 0.0066}
}
```

The pipeline always treats `USD` as `1.0` regardless of the table. Same fixture
+ same ledger → identical USD amounts on every run.

## Output layout

```
out/
└── llc-acme__US-FED__2025/
    ├── pl.csv                       P&L summary (gross, refunds, costs, net)
    ├── revenue_register.csv         Per-line revenue detail
    ├── expense_register.csv         Per-line expense detail
    ├── irs_line_items.csv           Schedule C / 1120 line-item rollup (US-FED only)
    ├── 1099_register.csv            Contractor / withholding (US-FED only)
    ├── quarterly_estimates.csv      Q1–Q4 1040-ES amounts + deadlines (US-FED / US-CA)
    └── manifest.json                Source-of-truth manifest (see below)
└── llc-acme__US-CA__2025/
    ├── pl.csv
    ├── revenue_register.csv
    ├── expense_register.csv
    ├── sales_tax_summary.csv        CA sales-tax accrual (statewide 7.25% minimum)
    ├── quarterly_estimates.csv      CA FTB 540-ES schedule
    └── manifest.json
└── llc-acme__DE__2025/              Non-US generic CSV
    ├── pl.csv
    ├── revenue_register.csv
    ├── expense_register.csv
    └── manifest.json
```

## Manifest schema — `manifest.json`

Keys are emitted in sorted (alphabetical) order with 2-space indentation —
matching `json.dumps(obj, sort_keys=True, indent=2)`. Monetary totals are
serialized as **2-decimal strings**, not JSON numbers, so Swift and Python
produce byte-identical output (`Double` / `float` shortest-roundtrip
representations diverge across runtimes; fixed strings do not).

```json
{
  "entityID": "llc-acme",
  "entityLegalName": "Acme Holdings LLC",
  "exportedAt": "2025-12-31T23:59:59Z",
  "files": [
    {
      "byteCount": 156,
      "path": "pl.csv",
      "sha256": "…"
    },
    {
      "byteCount": 412,
      "path": "irs_line_items.csv",
      "sha256": "…"
    }
  ],
  "jurisdiction": "US-FED",
  "notes": [
    "Active-day fraction: 0.5041 (prorated for mid-year incorporation/dissolution).",
    "3 cost line(s) classified as 'unclassified' — operator triage required."
  ],
  "sourceLedgerCommitHash": "deadbeef…",
  "taxYear": 2025,
  "totals": {
    "costUSD": "4800.00",
    "lineCount": 87,
    "netUSD": "7450.00",
    "refundsUSD": "250.00",
    "revenueUSD": "12500.00"
  },
  "totalsChecksum": "<sha256-hex>"
}
```

`lineCount` stays a JSON integer (it's a count, not money). The in-memory
`TaxExportManifest.Totals` Swift struct still holds `Double` fields for
ergonomic in-app access — only the on-disk JSON uses string-formatted money.

`totalsChecksum` is SHA256 over a canonical concatenation of `id|kind|category|amount`
for every line plus the totals tuple. Two runs with the same inputs always
produce the same checksum.

## Edge cases

### Zero revenue

The export still produces all expected files; totals are zero. `notes` includes
`"Zero ledger activity for this jurisdiction; export contains empty registers and zero totals."`

### Mid-year incorporation / dissolution

If `incorporatedAt` or `dissolvedAt` falls inside the tax year:

1. Ledger lines outside the active window are dropped.
2. Quarterly estimated-tax amounts are scaled by `active_days / total_days`
   (see `Active-day fraction` note in the manifest).
3. P&L totals reflect actual activity only.

### Multi-jurisdiction entities

The `allocation` rule splits each unpinned line proportionally. A line with an
explicit `jurisdiction` is pinned to that jurisdiction only.

### Mixed currencies

All amounts are multiplied by `fx_rates[currency]` before any aggregation,
rounded to 2 decimal places using banker-free half-away-from-zero rounding
(`(amount * 100).rounded() / 100` in Swift; `round(amount * 100) / 100` in
Python). Both implementations produce identical USD totals from the same fixture.

## CLI usage

```bash
python3 scripts/export-tax.py \
    --entities ~/.os1/entities.json \
    --ledger out/portfolio-ledger.json \
    --contractors out/contractors.json \
    --fx-rates fixtures/fx-2025.json \
    --entity-id llc-acme \
    --tax-year 2025 \
    --source-commit "$(git -C $LEDGER_REPO rev-parse HEAD)" \
    --exported-at "2025-12-31T23:59:59Z" \
    --out exports/2025/
```

Pass `--jurisdiction US-FED --jurisdiction US-CA` to override the entity-default
set. Omit `--exported-at` to use the current UTC time; pass a fixed value to
get byte-identical output across reruns.

## Doctor row

`TaxPipelineDoctorRow` surfaces in the Doctor tab with:

| Field                              | Source                                                            |
|------------------------------------|-------------------------------------------------------------------|
| `unclassifiedCostCount`            | cost entries whose category maps to `unclassified`                |
| `missingEntityMappingCount`        | ledger entries whose `companyID` is absent from the registry      |
| `salesTaxAccruedSinceLastFilingUSD`| running accrual from CA sales-tax summary                         |
| `nextQuarterlyEstimateDeadline`    | next Apr 15 / Jun 15 / Sep 15 / Jan 15 ≥ now                      |
| `daysUntilNextDeadline`            | calendar days from `now` to next deadline                         |

## Non-US jurisdictions

For any jurisdiction code outside `{US-FED, US-CA}` the pipeline emits:

- `pl.csv` — same columns, locale-neutral line-item names
- `revenue_register.csv`, `expense_register.csv` — same schema
- `manifest.json`

The operator hands the bundle to a local accountant; OS1 does not attempt
country-specific filings. Add new first-class jurisdictions by extending
`buildBundle` in Swift and the parallel `build_bundle` in Python.
