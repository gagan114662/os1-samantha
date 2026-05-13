#!/usr/bin/env python3
"""
Headless tax-export CLI for OS1 (issue #191).

Reads a portfolio ledger dump + entity registry, produces filing-ready exports
per (entity x jurisdiction) pair. Mirrors the deterministic guarantees of the
Swift `TaxExportPipeline`: identical inputs (including --exported-at) produce
byte-identical bytes, suitable for `diff -r` across reruns.

Schema reference: docs/tax-export.md
"""

from __future__ import annotations

import argparse
import csv
import hashlib
import io
import json
import os
import sys
from collections.abc import Iterable
from datetime import UTC, datetime
from decimal import ROUND_HALF_UP, Decimal
from typing import Any

_CENT = Decimal("0.01")

USD = "USD"

# IRS Schedule C / 1120 line-item map (mirrors IRSLineItem in Swift).
LINE_ITEMS = [
    ("grossReceipts", "Gross receipts or sales"),
    ("returnsAndAllowances", "Returns and allowances"),
    ("advertising", "Advertising"),
    ("commissionsAndFees", "Commissions and fees"),
    ("contractLabor", "Contract labor"),
    ("officeExpense", "Office expense"),
    ("supplies", "Supplies"),
    ("utilities", "Utilities (hosting/compute)"),
    ("otherExpenses", "Other expenses"),
    ("taxesAndLicenses", "Taxes and licenses"),
    ("unclassified", "Unclassified"),
]

CATEGORY_TO_LINE = {
    "ads": "advertising",
    "paymentFees": "commissionsAndFees",
    "manualLabor": "contractLabor",
    "tools": "officeExpense",
    "purchases": "supplies",
    "cloudCompute": "utilities",
    "tokenUsage": "otherExpenses",
    "subscription": "otherExpenses",
}

ENTITY_TYPE_TO_FORM = {
    "sole-proprietor": "Schedule C",
    "llc-single-member": "Schedule C",
    "c-corp": "Form 1120",
    "s-corp": "Form 1120-S",
    "llc-multi-member": "Form 1065",
    "foreign-entity": "Form 1120-F",
}


def money(value: float) -> str:
    return f"{round2(value):.2f}"


def round2(value: float) -> float:
    """Half-away-from-zero rounding to match Swift `(x * 100).rounded() / 100`.

    Python's builtin `round()` is banker's (half-to-even), which would diverge
    from Swift's default `.toNearestOrAwayFromZero` for values like 0.005.
    Using `Decimal.quantize(ROUND_HALF_UP)` matches Swift bit-for-bit on the
    positive values produced by the tax export pipeline.
    """
    return float(Decimal(repr(value)).quantize(_CENT, rounding=ROUND_HALF_UP))


def fx_to_usd(amount: float, currency: str, fx_rates: dict[str, float]) -> float:
    rate = fx_rates.get(currency)
    if rate is None:
        if currency == USD:
            return amount
        raise SystemExit(f"missing FX rate for currency {currency}")
    return amount * rate


def iso(dt: datetime) -> str:
    return dt.astimezone(UTC).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(value: str) -> datetime:
    if value.endswith("Z"):
        value = value[:-1] + "+00:00"
    return datetime.fromisoformat(value).astimezone(UTC)


def fiscal_year_bounds(year: int, start_month: int) -> tuple[datetime, datetime]:
    start = datetime(year, start_month, 1, tzinfo=UTC)
    end = datetime(year + 1, start_month, 1, tzinfo=UTC)
    return start, end


def active_day_fraction(entity: dict[str, Any], year: int) -> float:
    start, end = fiscal_year_bounds(year, entity.get("fiscalYearStartMonth", 1))
    total = (end - start).days or 365
    incorporated = entity.get("incorporatedAt")
    dissolved = entity.get("dissolvedAt")
    active_start = max(parse_iso(incorporated), start) if incorporated else start
    active_end = min(parse_iso(dissolved), end) if dissolved else end
    if active_end <= active_start:
        return 0.0
    return min(1.0, max(0.0, (active_end - active_start).days / total))


def normalize(lines: list[dict[str, Any]], fx_rates: dict[str, float]) -> list[dict[str, Any]]:
    normalized = []
    for line in lines:
        amount = fx_to_usd(line["amount"], line.get("currency", USD), fx_rates)
        normalized.append(
            {
                **line,
                "amount": round2(amount),
                "currency": USD,
            }
        )
    return normalized


def filter_to_entity_and_year(
    lines: list[dict[str, Any]],
    entity: dict[str, Any],
    year: int,
) -> list[dict[str, Any]]:
    start, end = fiscal_year_bounds(year, entity.get("fiscalYearStartMonth", 1))
    incorporated = parse_iso(entity["incorporatedAt"]) if entity.get("incorporatedAt") else None
    dissolved = parse_iso(entity["dissolvedAt"]) if entity.get("dissolvedAt") else None
    result = []
    for line in lines:
        if line["entityID"] != entity["id"]:
            continue
        occurred = parse_iso(line["occurredAt"])
        if not (start <= occurred < end):
            continue
        if incorporated and occurred < incorporated:
            continue
        if dissolved and occurred > dissolved:
            continue
        result.append(line)
    result.sort(key=lambda r: (r["occurredAt"], r["id"]))
    return result


def jurisdictions_for(entity: dict[str, Any], override: list[str] | None) -> list[str]:
    if override:
        return sorted(set(override))
    seen: list[str] = []
    for j in [entity["primaryJurisdiction"], *entity.get("additionalJurisdictions", [])]:
        if j not in seen:
            seen.append(j)
    return sorted(seen)


def allocate(
    lines: list[dict[str, Any]],
    entity: dict[str, Any],
    jurisdictions: list[str],
) -> dict[str, list[dict[str, Any]]]:
    buckets: dict[str, list[dict[str, Any]]] = {j: [] for j in jurisdictions}
    allocation = entity.get("allocation", {"kind": "primaryOnly"})
    kind = allocation.get("kind", "primaryOnly")
    weights = allocation.get("weights", {}) if kind == "revenueProportional" else {}

    for line in lines:
        pinned = line.get("jurisdiction")
        if pinned and pinned in buckets:
            buckets[pinned].append(line)
            continue

        if kind == "primaryOnly":
            buckets[entity["primaryJurisdiction"]].append(line)
        elif kind == "equalSplit":
            share = 1.0 / len(jurisdictions)
            for j in jurisdictions:
                buckets[j].append(_fragment(line, share, j))
        elif kind == "revenueProportional":
            total = sum(max(0.0, weights.get(j, 0)) for j in jurisdictions) or 0.0
            if total <= 0:
                buckets[entity["primaryJurisdiction"]].append(line)
                continue
            for j in jurisdictions:
                share = max(0.0, weights.get(j, 0)) / total
                buckets[j].append(_fragment(line, share, j))

    for j in buckets:
        buckets[j].sort(key=lambda r: (r["occurredAt"], r["id"]))
    return buckets


def _fragment(line: dict[str, Any], share: float, jurisdiction: str) -> dict[str, Any]:
    return {
        **line,
        "id": f"{line['id']}#{jurisdiction}",
        "amount": round2(line["amount"] * share),
        "jurisdiction": jurisdiction,
    }


def classify(category: str | None, kind: str) -> str:
    if kind == "revenue":
        return "grossReceipts"
    if kind == "refund":
        return "returnsAndAllowances"
    return CATEGORY_TO_LINE.get(category or "", "unclassified")


def csv_bytes(header: list[str], rows: Iterable[list[str]]) -> bytes:
    buf = io.StringIO()
    writer = csv.writer(buf, lineterminator="\n", quoting=csv.QUOTE_MINIMAL)
    writer.writerow(header)
    for row in rows:
        writer.writerow(row)
    return buf.getvalue().rstrip("\n").encode("utf-8")


def make_pl(lines: list[dict[str, Any]]) -> bytes:
    revenue = sum(row["amount"] for row in lines if row["kind"] == "revenue")
    refunds = sum(row["amount"] for row in lines if row["kind"] == "refund")
    costs = sum(row["amount"] for row in lines if row["kind"] == "cost")
    net = revenue - refunds - costs
    return csv_bytes(
        ["line_item", "amount_usd"],
        [
            ["Gross revenue", money(revenue)],
            ["Refunds and allowances", money(refunds)],
            ["Total costs", money(costs)],
            ["Net income", money(net)],
        ],
    )


def make_register(lines: list[dict[str, Any]], kind: str, path: str) -> tuple[str, bytes]:
    rows = []
    for row in lines:
        if row["kind"] != kind:
            continue
        rows.append(
            [
                row["id"],
                row["occurredAt"],
                row.get("category") or "",
                money(row["amount"]),
                row.get("jurisdiction") or "",
                row.get("counterparty") or "",
                row.get("memo") or "",
            ]
        )
    header = ["id", "occurred_at", "category", "amount_usd", "jurisdiction", "counterparty", "memo"]
    return path, csv_bytes(header, rows)


def make_irs_line_items(lines: list[dict[str, Any]], entity: dict[str, Any]) -> bytes:
    totals = dict.fromkeys((key for key, _ in LINE_ITEMS), 0.0)
    for row in lines:
        totals[classify(row.get("category"), row["kind"])] += row["amount"]
    form = ENTITY_TYPE_TO_FORM.get(entity["entityType"], "Schedule C")
    rows = [[form, label, money(totals[key])] for key, label in LINE_ITEMS]
    return csv_bytes(["form", "line_item", "amount_usd"], rows)


def make_1099(
    payments: list[dict[str, Any]],
    entity: dict[str, Any],
    tax_year: int,
) -> bytes:
    eligible = [
        p for p in payments if p["payerEntityID"] == entity["id"] and p["amountUSD"] >= 600.0
    ]
    eligible.sort(key=lambda p: p["recipientName"])
    rows = []
    for p in eligible:
        form = "1099-NEC" if p["isUSResident"] else "1042-S"
        withhold = "no" if p["isUSResident"] else "yes"
        rows.append(
            [
                p["recipientName"],
                p.get("recipientTaxID") or "",
                p["recipientCountry"],
                money(p["amountUSD"]),
                "yes" if p["isUSResident"] else "no",
                form,
                withhold,
            ]
        )
    body = csv_bytes(
        [
            "recipient_name",
            "recipient_tax_id",
            "recipient_country",
            "amount_usd",
            "us_resident",
            "form_type",
            "withholding_required",
        ],
        rows,
    )
    return body + f"\n# tax_year={tax_year} threshold_usd=600.00".encode()


def quarterly_deadlines(tax_year: int, fiscal_year_start_month: int) -> list[str]:
    """15th of the 4th/6th/9th/13th month of the entity's fiscal year."""
    offsets = [3, 5, 8, 12]
    deadlines: list[str] = []
    for offset in offsets:
        absolute = fiscal_year_start_month + offset
        year = tax_year + (absolute - 1) // 12
        month = ((absolute - 1) % 12) + 1
        deadlines.append(f"{year:04d}-{month:02d}-15")
    return deadlines


def make_quarterly_estimates(
    lines: list[dict[str, Any]],
    tax_year: int,
    jurisdiction: str,
    active_fraction: float,
    fiscal_year_start_month: int,
) -> bytes:
    revenue = sum(row["amount"] for row in lines if row["kind"] == "revenue")
    refunds = sum(row["amount"] for row in lines if row["kind"] == "refund")
    costs = sum(row["amount"] for row in lines if row["kind"] == "cost")
    net = max(0.0, revenue - refunds - costs)
    rate = 0.22 if jurisdiction == "US-FED" else 0.093
    estimated = round2(net * rate * active_fraction)
    per_q = round2(estimated / 4.0)
    deadlines = quarterly_deadlines(tax_year, fiscal_year_start_month)
    basis = f"net={money(net)} rate={rate:.4f} active={active_fraction:.4f}"
    rows = [
        [q, d, money(per_q), basis]
        for q, d in zip(["Q1", "Q2", "Q3", "Q4"], deadlines, strict=True)
    ]
    return csv_bytes(["quarter", "deadline", "amount_usd", "basis"], rows)


def make_ca_sales_tax(lines: list[dict[str, Any]]) -> bytes:
    ca_rev = [
        row
        for row in lines
        if row["kind"] == "revenue" and (row.get("jurisdiction") or "US-CA") == "US-CA"
    ]
    total = sum(row["amount"] for row in ca_rev)
    tax = round2(total * 0.0725)
    return csv_bytes(
        ["jurisdiction", "taxable_revenue_usd", "rate", "tax_owed_usd", "filing_form"],
        [["US-CA", money(total), "0.0725", money(tax), "CDTFA-401"]],
    )


def sha256_hex(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def totals_checksum(lines: list[dict[str, Any]], totals: dict[str, Any]) -> str:
    canonical = ""
    for row in lines:
        canonical += (
            f"{row['id']}|{row['kind']}|{row.get('category') or '-'}|{money(row['amount'])}\n"
        )
    canonical += (
        f"TOTAL|revenue={money(totals['revenueUSD'])}|refunds={money(totals['refundsUSD'])}|"
        f"cost={money(totals['costUSD'])}|net={money(totals['netUSD'])}|count={totals['lineCount']}"
    )
    return sha256_hex(canonical.encode("utf-8"))


def build_bundle(
    entity: dict[str, Any],
    jurisdiction: str,
    lines: list[dict[str, Any]],
    contractors: list[dict[str, Any]],
    tax_year: int,
    source_commit: str,
    exported_at: datetime,
    active_fraction: float,
) -> tuple[dict[str, Any], dict[str, bytes]]:
    files: dict[str, bytes] = {}
    notes: list[str] = []
    if active_fraction < 1.0:
        notes.append(
            f"Active-day fraction: {active_fraction:.4f} "
            f"(prorated for mid-year incorporation/dissolution)."
        )
    if not lines:
        notes.append(
            "Zero ledger activity for this jurisdiction; export contains empty registers and zero totals."
        )

    files["pl.csv"] = make_pl(lines)
    files["revenue_register.csv"] = make_register(lines, "revenue", "revenue_register.csv")[1]
    files["expense_register.csv"] = make_register(lines, "cost", "expense_register.csv")[1]

    if jurisdiction == "US-FED":
        files["irs_line_items.csv"] = make_irs_line_items(lines, entity)
        files["1099_register.csv"] = make_1099(contractors, entity, tax_year)
        files["quarterly_estimates.csv"] = make_quarterly_estimates(
            lines, tax_year, jurisdiction, active_fraction, entity.get("fiscalYearStartMonth", 1)
        )
        unclassified = sum(
            1
            for row in lines
            if row["kind"] == "cost"
            and classify(row.get("category"), row["kind"]) == "unclassified"
        )
        if unclassified:
            notes.append(
                f"{unclassified} cost line(s) classified as 'unclassified' - operator triage required."
            )
    elif jurisdiction == "US-CA":
        files["sales_tax_summary.csv"] = make_ca_sales_tax(lines)
        files["quarterly_estimates.csv"] = make_quarterly_estimates(
            lines, tax_year, jurisdiction, active_fraction, entity.get("fiscalYearStartMonth", 1)
        )

    revenue = sum(row["amount"] for row in lines if row["kind"] == "revenue")
    refunds = sum(row["amount"] for row in lines if row["kind"] == "refund")
    costs = sum(row["amount"] for row in lines if row["kind"] == "cost")
    totals_canonical = {
        "revenueUSD": money(revenue),
        "refundsUSD": money(refunds),
        "costUSD": money(costs),
        "netUSD": money(revenue - refunds - costs),
        "lineCount": len(lines),
    }
    totals = {
        "revenueUSD": round2(revenue),
        "refundsUSD": round2(refunds),
        "costUSD": round2(costs),
        "netUSD": round2(revenue - refunds - costs),
        "lineCount": len(lines),
    }
    file_entries = [
        {"path": path, "sha256": sha256_hex(data), "byteCount": len(data)}
        for path, data in sorted(files.items())
    ]
    manifest = {
        "entityID": entity["id"],
        "entityLegalName": entity["legalName"],
        "taxYear": tax_year,
        "jurisdiction": jurisdiction,
        "sourceLedgerCommitHash": source_commit,
        "exportedAt": iso(exported_at),
        "totalsChecksum": totals_checksum(lines, totals),
        "files": file_entries,
        "totals": totals_canonical,
        "notes": notes,
    }
    manifest_bytes = json.dumps(manifest, sort_keys=True, indent=2).encode("utf-8")
    files["manifest.json"] = manifest_bytes
    return manifest, files


def run(args: argparse.Namespace) -> int:
    with open(args.entities) as f:
        registry = json.load(f)
    with open(args.ledger) as f:
        ledger = json.load(f)

    contractors = []
    if args.contractors:
        with open(args.contractors) as f:
            contractors = json.load(f)

    fx_rates = {USD: 1.0}
    if args.fx_rates:
        with open(args.fx_rates) as f:
            fx_rates.update(json.load(f).get("rates", {}))

    exported_at = parse_iso(args.exported_at) if args.exported_at else datetime.now(UTC)
    target_entity = next((e for e in registry["entities"] if e["id"] == args.entity_id), None)
    if target_entity is None:
        print(f"ERROR: entity {args.entity_id} not found", file=sys.stderr)
        return 2

    normalized = normalize(ledger, fx_rates)
    filtered = filter_to_entity_and_year(normalized, target_entity, args.tax_year)
    jurisdictions = jurisdictions_for(target_entity, args.jurisdiction)
    allocations = allocate(filtered, target_entity, jurisdictions)
    fraction = active_day_fraction(target_entity, args.tax_year)

    os.makedirs(args.out, exist_ok=True)
    for jurisdiction in jurisdictions:
        manifest, files = build_bundle(
            entity=target_entity,
            jurisdiction=jurisdiction,
            lines=allocations[jurisdiction],
            contractors=contractors,
            tax_year=args.tax_year,
            source_commit=args.source_commit,
            exported_at=exported_at,
            active_fraction=fraction,
        )
        bundle_dir = os.path.join(
            args.out, f"{target_entity['id']}__{jurisdiction}__{args.tax_year}"
        )
        os.makedirs(bundle_dir, exist_ok=True)
        for path, data in sorted(files.items()):
            with open(os.path.join(bundle_dir, path), "wb") as f:
                f.write(data)
        print(
            f"wrote {bundle_dir} ({len(files)} files, totals_checksum={manifest['totalsChecksum'][:12]})"
        )
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="OS1 tax-export pipeline (issue #191).")
    parser.add_argument(
        "--entities", required=True, help="Path to entities.json (TaxEntityRegistry)."
    )
    parser.add_argument(
        "--ledger", required=True, help="Path to ledger.json (array of TaxLedgerLine)."
    )
    parser.add_argument("--contractors", help="Path to contractors.json (TaxContractorPayment[]).")
    parser.add_argument("--fx-rates", help="Path to fx-rates.json ({asOf, rates}).")
    parser.add_argument("--entity-id", required=True)
    parser.add_argument("--tax-year", type=int, required=True)
    parser.add_argument(
        "--jurisdiction",
        action="append",
        default=[],
        help="Override entity-default jurisdictions (repeatable).",
    )
    parser.add_argument(
        "--source-commit", required=True, help="Git commit hash of the source ledger."
    )
    parser.add_argument("--exported-at", help="Freeze export timestamp (ISO8601) for determinism.")
    parser.add_argument("--out", required=True, help="Output directory.")
    args = parser.parse_args()
    return run(args)


if __name__ == "__main__":
    sys.exit(main())
