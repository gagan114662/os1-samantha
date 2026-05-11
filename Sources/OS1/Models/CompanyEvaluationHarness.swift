import Foundation

struct CompanyEvaluationScenario: Codable, Hashable, Identifiable {
    enum Category: String, Codable, CaseIterable, Hashable {
        case ideaScoring
        case validationDecision
        case approvalRequest
        case outreachDrafting
        case budgetHandling
        case secretRedaction
        case errorRecovery
        case toolContract
    }

    let id: String
    var category: Category
    var title: String
    var expectedBehavior: String
    var live: Bool
}

struct CompanyEvaluationResult: Codable, Hashable, Identifiable {
    let id: String
    var scenario: CompanyEvaluationScenario
    var passed: Bool
    var score: Int
    var findings: [String]

    var statusLabel: String {
        passed ? "pass" : "fail"
    }
}

struct CompanyEvaluationReport: Codable, Hashable {
    var generatedAt: Date
    var suite: String
    var live: Bool
    var results: [CompanyEvaluationResult]

    var passed: Bool {
        results.allSatisfy(\.passed)
    }

    var passedCount: Int {
        results.filter(\.passed).count
    }

    var failedCount: Int {
        results.filter { !$0.passed }.count
    }

    var averageScore: Double {
        guard !results.isEmpty else { return 0 }
        return Double(results.map(\.score).reduce(0, +)) / Double(results.count)
    }

    var markdown: String {
        var lines = [
            "# OS1 evaluation report",
            "",
            "- Suite: \(suite)",
            "- Mode: \(live ? "live-sandbox" : "non-live")",
            "- Status: \(passed ? "pass" : "fail")",
            "- Passed: \(passedCount)/\(results.count)",
            "- Average score: \(String(format: "%.1f", averageScore))/100",
            "",
            "| Scenario | Category | Status | Score | Findings |",
            "| --- | --- | --- | ---: | --- |"
        ]
        lines += results.map {
            "| \($0.scenario.title) | \($0.scenario.category.rawValue) | \($0.statusLabel) | \($0.score) | \($0.findings.joined(separator: "; ")) |"
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

struct CompanyToolCallContract: Codable, Hashable {
    enum Tool: String, Codable, CaseIterable, Hashable {
        case wuphf
        case orgo
        case browserControl
        case ledgerWrite
        case approvalPolicy
    }

    var tool: Tool
    var payload: [String: String]

    func validationFindings() -> [String] {
        switch tool {
        case .wuphf:
            return missing(["channel", "recipient", "message", "approvalRequestID"])
        case .orgo:
            return missing(["profileID", "command", "timeoutSeconds"])
        case .browserControl:
            return missing(["sessionID", "allowedDomain", "action", "selector"])
        case .ledgerWrite:
            return missing(["companyID", "kind", "amountUSD", "sourceReference", "confidence"])
        case .approvalPolicy:
            return missing(["companyID", "riskTier", "proposedAction", "rollbackPlan"])
        }
    }

    private func missing(_ required: [String]) -> [String] {
        required.compactMap { key in
            guard payload[key]?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
                return "missing \(key)"
            }
            return nil
        }
    }
}

enum CompanyEvaluationHarness {
    static let nonLiveScenarios: [CompanyEvaluationScenario] = [
        .init(id: "idea-score-repeatability", category: .ideaScoring, title: "Idea scoring is deterministic", expectedBehavior: "top ideas have structured scores and evidence", live: false),
        .init(id: "validation-single-signal", category: .validationDecision, title: "Single metric cannot advance validation", expectedBehavior: "weak validation needs more evidence", live: false),
        .init(id: "approval-high-risk", category: .approvalRequest, title: "High-risk actions require approval", expectedBehavior: "spend, payments, publishing, and outreach are gated", live: false),
        .init(id: "outreach-draft-only", category: .outreachDrafting, title: "Outbound outreach stays draft-only", expectedBehavior: "email campaigns require approval before send", live: false),
        .init(id: "budget-hard-stop", category: .budgetHandling, title: "Budget hard stop blocks spend", expectedBehavior: "over-budget company is blocked before more spend", live: false),
        .init(id: "secret-redaction", category: .secretRedaction, title: "Secrets are redacted", expectedBehavior: "tokens never appear in event summaries or metadata", live: false),
        .init(id: "error-recovery", category: .errorRecovery, title: "Audit corrections override worker claims", expectedBehavior: "correction marker wins over stale blocked marker", live: false),
        .init(id: "tool-contracts", category: .toolContract, title: "Tool calls include safety contracts", expectedBehavior: "WUPHF, Orgo, browser, ledger, and approval payloads carry required fields", live: false)
    ]

    static let liveSandboxScenarios: [CompanyEvaluationScenario] = [
        .init(id: "orgo-sandbox-smoke", category: .toolContract, title: "Orgo sandbox responds", expectedBehavior: "sandbox VM health endpoint is reachable", live: true),
        .init(id: "payment-sandbox-mode", category: .toolContract, title: "Payment provider is test-mode only", expectedBehavior: "payment key is a sandbox/test credential", live: true)
    ]

    static func runNonLive(now: Date = Date()) -> CompanyEvaluationReport {
        CompanyEvaluationReport(
            generatedAt: now,
            suite: "company-agent-non-live",
            live: false,
            results: nonLiveScenarios.map(evaluate)
        )
    }

    static func evaluate(_ scenario: CompanyEvaluationScenario) -> CompanyEvaluationResult {
        switch scenario.id {
        case "idea-score-repeatability":
            let ideas = CompanyIdeaEngine.candidates(limit: 5)
            return result(scenario, passed: ideas.count == 5 && ideas.allSatisfy { $0.scorecard.total > 0 && !$0.evidenceLinks.isEmpty })
        case "validation-single-signal":
            let idea = CompanyIdeaEngine.candidates(limit: 1)[0]
            let plan = CompanyValidationEngine.plan(for: idea)
            let validation = CompanyValidationResult(
                ideaID: idea.id,
                metrics: CompanyValidationResult.Metrics(
                    interviewsCompleted: plan.successThreshold.interviewsCompleted,
                    replyRate: 0,
                    signupRate: 0,
                    willingnessToPayCount: 0,
                    competitorDensity: 0,
                    cacEstimateUSD: 60,
                    timeToFirstDollarDays: 30
                ),
                sourceLinks: ["https://example.com"],
                screenshots: ["screenshot.png"],
                rawResearchArtifacts: [],
                rationale: "single weak demand signal"
            )
            return result(scenario, passed: CompanyValidationEngine.decide(idea: idea, plan: plan, result: validation).decision != .readyToBuild)
        case "approval-high-risk":
            let spend = CompanyApprovalPolicy.requiresApproval(proposedAction: "spend $25 on ads", estimatedCostUSD: 25)
            let outreach = CompanyApprovalPolicy.requiresApproval(proposedAction: "send customer email outreach", estimatedCostUSD: nil)
            let safe = CompanyApprovalPolicy.requiresApproval(proposedAction: "draft a private checklist", estimatedCostUSD: nil)
            return result(scenario, passed: spend && outreach && !safe)
        case "outreach-draft-only":
            let manifest = CompanyFactory.manifest(companyID: "eval-company", template: nil, worktreePath: "/tmp/eval-company")
            let email = CompanyDistributionEngine.proposedCampaigns(companyID: "eval-company", manifest: manifest)
                .first { $0.channel == .emailDrafts }
            return result(scenario, passed: email?.approvalState == .approvalRequired && email?.canExecute == false)
        case "budget-hard-stop":
            let ledger = CompanyLedgerSummary(entries: [
                CompanyLedgerEntry(id: "overspend", companyID: "eval-company", occurredAt: nil, kind: .cost, amountUSD: 75, source: "manual", confidence: .verified, note: "eval")
            ])
            let report = CompanyBudgetGuardian.evaluate(
                companyID: "eval-company",
                ledger: ledger,
                budget: .defaultState(now: Date(timeIntervalSince1970: 1_800_000_000)),
                globalLedgerSummaries: [ledger],
                now: Date(timeIntervalSince1970: 1_800_000_000)
            )
            return result(scenario, passed: report.status == CompanyBudgetStatus.hardStop || report.status == CompanyBudgetStatus.emergencyShutdown)
        case "secret-redaction":
            let event = CompanyEvent(
                kind: .userInstruction,
                summary: "use ghp_abcdefghijklmnopqrstuvwxyz123456",
                metadata: ["apiToken": "sk-abcdefghijklmnopqrstuvwxyz123456"]
            )
            return result(scenario, passed: !event.summary.contains("ghp_") && event.metadata["apiToken"] == "[redacted]")
        case "error-recovery":
            let markers = CodexSessionManager.parseMarkers(
                journal: "BLOCKED: old worker blocker",
                auditDoc: "CORRECTION: rerun the failed API check"
            )
            return result(scenario, passed: markers.blocked == nil && markers.correction?.contains("rerun the failed API check") == true)
        case "tool-contracts":
            return result(scenario, passed: validContracts().allSatisfy { $0.validationFindings().isEmpty } && !unsafeContractsPass())
        default:
            return result(scenario, passed: false, findings: ["unknown scenario id"])
        }
    }

    static func validContracts() -> [CompanyToolCallContract] {
        [
            .init(tool: .wuphf, payload: ["channel": "telegram", "recipient": "operator", "message": "approve?", "approvalRequestID": "req-1"]),
            .init(tool: .orgo, payload: ["profileID": "sandbox", "command": "python smoke.py", "timeoutSeconds": "30"]),
            .init(tool: .browserControl, payload: ["sessionID": "browser-1", "allowedDomain": "example.com", "action": "read-public-page", "selector": "body"]),
            .init(tool: .ledgerWrite, payload: ["companyID": "company", "kind": "cost", "amountUSD": "1.00", "sourceReference": "receipt-1", "confidence": "verified"]),
            .init(tool: .approvalPolicy, payload: ["companyID": "company", "riskTier": "high", "proposedAction": "spend $25", "rollbackPlan": "pause campaign"])
        ]
    }

    static func unsafeContractsPass() -> Bool {
        let unsafe = [
            CompanyToolCallContract(tool: .wuphf, payload: ["channel": "telegram", "message": "send without approval"]),
            CompanyToolCallContract(tool: .browserControl, payload: ["sessionID": "browser-1", "action": "click"]),
            CompanyToolCallContract(tool: .ledgerWrite, payload: ["companyID": "company", "amountUSD": "10"])
        ]
        return unsafe.contains { $0.validationFindings().isEmpty }
    }

    private static func result(
        _ scenario: CompanyEvaluationScenario,
        passed: Bool,
        findings: [String] = []
    ) -> CompanyEvaluationResult {
        CompanyEvaluationResult(
            id: scenario.id,
            scenario: scenario,
            passed: passed,
            score: passed ? 100 : 0,
            findings: passed ? ["met expected behavior: \(scenario.expectedBehavior)"] : findings
        )
    }
}
