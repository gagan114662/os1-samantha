#!/usr/bin/env python3
"""Run OS1 company-agent evals and write CI/Doctor-readable reports."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import urllib.parse
import urllib.request
from datetime import UTC, datetime
from pathlib import Path

NON_LIVE_SCENARIOS = [
    ("idea-score-repeatability", "ideaScoring", "Idea scoring is deterministic"),
    ("validation-single-signal", "validationDecision", "Single metric cannot advance validation"),
    ("approval-high-risk", "approvalRequest", "High-risk actions require approval"),
    ("outreach-draft-only", "outreachDrafting", "Outbound outreach stays draft-only"),
    ("budget-hard-stop", "budgetHandling", "Budget hard stop blocks spend"),
    ("secret-redaction", "secretRedaction", "Secrets are redacted"),
    ("error-recovery", "errorRecovery", "Audit corrections override worker claims"),
    ("tool-contracts", "toolContract", "Tool calls include safety contracts"),
]


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--live", action="store_true", help="Run live sandbox checks instead of non-live evals."
    )
    parser.add_argument("--json-report", default="artifacts/evals/non-live-report.json")
    parser.add_argument("--markdown-report", default="artifacts/evals/non-live-report.md")
    parser.add_argument("--swift-test", default="swift")
    return parser.parse_args()


def run_non_live(swift: str) -> tuple[bool, list[dict[str, object]], str]:
    proc = subprocess.run(
        [swift, "test", "--filter", "CompanyEvaluationHarnessTests"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    passed = proc.returncode == 0
    results = [
        {
            "id": scenario_id,
            "category": category,
            "title": title,
            "status": "pass" if passed else "fail",
            "score": 100 if passed else 0,
            "findings": ["Swift eval scenario passed"]
            if passed
            else ["Swift eval test target failed"],
        }
        for scenario_id, category, title in NON_LIVE_SCENARIOS
    ]
    return passed, results, proc.stdout


def run_live_sandbox() -> tuple[bool, list[dict[str, object]], str]:
    orgo_url = os.environ.get("ORGO_SANDBOX_URL", "").rstrip("/")
    stripe_key = os.environ.get("STRIPE_SECRET_KEY", "")
    output: list[str] = []
    results: list[dict[str, object]] = []

    orgo_passed = False
    if orgo_url:
        parsed = urllib.parse.urlparse(orgo_url)
        if parsed.scheme not in {"http", "https"}:
            output.append("ORGO_SANDBOX_URL must use http or https")
        else:
            try:
                with urllib.request.urlopen(f"{orgo_url}/health", timeout=10) as response:  # noqa: S310
                    orgo_passed = 200 <= response.status < 300
                    output.append(f"orgo health status={response.status}")
            except Exception as exc:
                output.append(f"orgo health failed: {exc}")
    else:
        output.append("ORGO_SANDBOX_URL is required for --live")

    payment_passed = stripe_key.startswith("sk_test_")
    if not payment_passed:
        output.append("STRIPE_SECRET_KEY must be a Stripe test-mode key starting with sk_test_")

    results.append(live_result("orgo-sandbox-smoke", "Orgo sandbox responds", orgo_passed))
    results.append(
        live_result("payment-sandbox-mode", "Payment provider is test-mode only", payment_passed)
    )
    return all(result["status"] == "pass" for result in results), results, "\n".join(output)


def live_result(scenario_id: str, title: str, passed: bool) -> dict[str, object]:
    return {
        "id": scenario_id,
        "category": "toolContract",
        "title": title,
        "status": "pass" if passed else "fail",
        "score": 100 if passed else 0,
        "findings": ["sandbox check passed"] if passed else ["sandbox prerequisite failed"],
    }


def write_reports(json_path: Path, markdown_path: Path, report: dict[str, object]) -> None:
    json_path.parent.mkdir(parents=True, exist_ok=True)
    markdown_path.parent.mkdir(parents=True, exist_ok=True)
    json_path.write_text(json.dumps(report, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    markdown_path.write_text(markdown(report), encoding="utf-8")


def markdown(report: dict[str, object]) -> str:
    lines = [
        "# OS1 evaluation report",
        "",
        f"- Suite: {report['suite']}",
        f"- Mode: {'live-sandbox' if report['live'] else 'non-live'}",
        f"- Status: {'pass' if report['passed'] else 'fail'}",
        f"- Passed: {report['passedCount']}/{report['totalCount']}",
        f"- Average score: {report['averageScore']:.1f}/100",
        "",
        "| Scenario | Category | Status | Score | Findings |",
        "| --- | --- | --- | ---: | --- |",
    ]
    for result in report["results"]:
        findings = "; ".join(result["findings"])
        lines.append(
            f"| {result['title']} | {result['category']} | {result['status']} | {result['score']} | {findings} |"
        )
    lines.append("")
    return "\n".join(lines)


def main() -> int:
    args = parse_args()
    if args.live:
        passed, results, output = run_live_sandbox()
        suite = "company-agent-live-sandbox"
    else:
        passed, results, output = run_non_live(args.swift_test)
        suite = "company-agent-non-live"

    average = sum(int(result["score"]) for result in results) / max(1, len(results))
    report = {
        "generatedAt": datetime.now(UTC).isoformat(),
        "suite": suite,
        "live": args.live,
        "passed": passed,
        "passedCount": sum(1 for result in results if result["status"] == "pass"),
        "totalCount": len(results),
        "averageScore": average,
        "results": results,
        "outputTail": output[-4000:],
    }
    write_reports(Path(args.json_report), Path(args.markdown_report), report)
    print(markdown(report))
    if output:
        print("## Raw output tail")
        print(output[-4000:])
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
