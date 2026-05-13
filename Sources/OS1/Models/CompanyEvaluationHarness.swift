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
        case heartbeatDynamism
        case approvalGate
        case validationEvidence
        case driftDetection
        case restartRecovery
    }

    let id: String
    var category: Category
    var title: String
    var expectedBehavior: String
    var live: Bool
    var blocking: Bool = true
}

struct CompanyEvaluationResult: Codable, Hashable, Identifiable {
    let id: String
    var scenario: CompanyEvaluationScenario
    var passed: Bool
    var blocking: Bool
    var score: Int
    var findings: [String]
    var artifacts: [String] = []

    var statusLabel: String {
        passed ? "pass" : "fail"
    }
}

struct CompanyEvaluationReport: Codable, Hashable {
    var schemaVersion: Int = 1
    var generatedAt: Date
    var suite: String
    var live: Bool
    var results: [CompanyEvaluationResult]

    init(
        schemaVersion: Int = 1,
        generatedAt: Date,
        suite: String,
        live: Bool,
        results: [CompanyEvaluationResult]
    ) {
        self.schemaVersion = schemaVersion
        self.generatedAt = generatedAt
        self.suite = suite
        self.live = live
        self.results = results
    }

    enum CodingKeys: String, CodingKey {
        case schemaVersion
        case generatedAt
        case suite
        case live
        case results
        case passed
        case passedCount
        case failedCount
        case totalCount
        case blockingPassed
        case blockingFailedCount
        case averageScore
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        generatedAt = try container.decode(Date.self, forKey: .generatedAt)
        suite = try container.decode(String.self, forKey: .suite)
        live = try container.decode(Bool.self, forKey: .live)
        results = try container.decode([CompanyEvaluationResult].self, forKey: .results)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(generatedAt, forKey: .generatedAt)
        try container.encode(suite, forKey: .suite)
        try container.encode(live, forKey: .live)
        try container.encode(results, forKey: .results)
        try container.encode(passed, forKey: .passed)
        try container.encode(passedCount, forKey: .passedCount)
        try container.encode(failedCount, forKey: .failedCount)
        try container.encode(totalCount, forKey: .totalCount)
        try container.encode(blockingPassed, forKey: .blockingPassed)
        try container.encode(blockingFailedCount, forKey: .blockingFailedCount)
        try container.encode(averageScore, forKey: .averageScore)
    }

    var passed: Bool {
        results.allSatisfy(\.passed)
    }

    var totalCount: Int {
        results.count
    }

    var passedCount: Int {
        results.filter(\.passed).count
    }

    var failedCount: Int {
        results.filter { !$0.passed }.count
    }

    var blockingPassed: Bool {
        results.filter(\.blocking).allSatisfy(\.passed)
    }

    var blockingFailedCount: Int {
        results.filter { $0.blocking && !$0.passed }.count
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
            "- Blocking status: \(blockingPassed ? "pass" : "fail")",
            "- Passed: \(passedCount)/\(results.count)",
            "- Blocking failures: \(blockingFailedCount)",
            "- Average score: \(String(format: "%.1f", averageScore))/100",
            "",
            "| Scenario | Category | Blocking | Status | Score | Findings |",
            "| --- | --- | --- | --- | ---: | --- |"
        ]
        lines += results.map {
            "| \($0.scenario.title) | \($0.scenario.category.rawValue) | \($0.blocking ? "yes" : "no") | \($0.statusLabel) | \($0.score) | \($0.findings.joined(separator: "; ")) |"
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
    static let legacyNonLiveScenarios: [CompanyEvaluationScenario] = [
        .init(id: "idea-score-repeatability", category: .ideaScoring, title: "Idea scoring is deterministic", expectedBehavior: "top ideas have structured scores and evidence", live: false),
        .init(id: "validation-single-signal", category: .validationDecision, title: "Single metric cannot advance validation", expectedBehavior: "weak validation needs more evidence", live: false),
        .init(id: "approval-high-risk", category: .approvalRequest, title: "High-risk actions require approval", expectedBehavior: "spend, payments, publishing, and outreach are gated", live: false),
        .init(id: "outreach-draft-only", category: .outreachDrafting, title: "Outbound outreach stays draft-only", expectedBehavior: "email campaigns require approval before send", live: false),
        .init(id: "budget-hard-stop", category: .budgetHandling, title: "Budget hard stop blocks spend", expectedBehavior: "over-budget company is blocked before more spend", live: false),
        .init(id: "secret-redaction", category: .secretRedaction, title: "Secrets are redacted", expectedBehavior: "tokens never appear in event summaries or metadata", live: false),
        .init(id: "error-recovery", category: .errorRecovery, title: "Audit corrections override worker claims", expectedBehavior: "correction marker wins over stale blocked marker", live: false),
        .init(id: "tool-contracts", category: .toolContract, title: "Tool calls include safety contracts", expectedBehavior: "WUPHF, Orgo, browser, ledger, and approval payloads carry required fields", live: false)
    ]

    static let blockingRuntimeScenarios: [CompanyEvaluationScenario] = [
        .init(id: "heartbeat-1-dynamism", category: .heartbeatDynamism, title: "Heartbeat 1 invokes Codex with the mission", expectedBehavior: "first work heartbeat pipes a mission-bearing prompt into codex exec", live: false),
        .init(id: "approval-gate-public-publish", category: .approvalGate, title: "Public publishing blocks until approval grant exists", expectedBehavior: "public content publish is blocked without APPROVAL_GRANTED.json and allowed only with a matching grant", live: false),
        .init(id: "validation-evidence-threshold", category: .validationEvidence, title: "Building transition requires validation evidence", expectedBehavior: "validating-to-building promotion requires multi-signal evidence and artifacts", live: false),
        .init(id: "drift-no-progress-auto-pause", category: .driftDetection, title: "No-progress chains auto-pause", expectedBehavior: "repeated no-progress heartbeat failures produce a paused stalemate decision", live: false),
        .init(id: "restart-recovery-heartbeat-lease", category: .restartRecovery, title: "Restart recovery preserves heartbeat leases", expectedBehavior: "a kill -9 style restart queues the company and preserves the active heartbeat lease until expiry", live: false)
    ]

    static let nonLiveScenarios: [CompanyEvaluationScenario] = legacyNonLiveScenarios + blockingRuntimeScenarios

    static let liveSandboxScenarios: [CompanyEvaluationScenario] = [
        .init(id: "orgo-sandbox-smoke", category: .toolContract, title: "Orgo sandbox responds", expectedBehavior: "sandbox VM health endpoint is reachable", live: true),
        .init(id: "payment-sandbox-mode", category: .toolContract, title: "Payment provider is test-mode only", expectedBehavior: "payment key is a sandbox/test credential", live: true)
    ]

    static func runNonLive(now: Date = Date()) -> CompanyEvaluationReport {
        CompanyEvaluationReport(
            generatedAt: now,
            suite: "os1-agent-non-live-blocking",
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
        case "heartbeat-1-dynamism":
            return heartbeatDynamismResult(scenario)
        case "approval-gate-public-publish":
            return approvalGateResult(scenario, now: Date(timeIntervalSince1970: 1_800_000_000))
        case "validation-evidence-threshold":
            return validationEvidenceResult(scenario)
        case "drift-no-progress-auto-pause":
            return noProgressAutoPauseResult(scenario)
        case "restart-recovery-heartbeat-lease":
            return restartRecoveryResult(scenario, now: Date(timeIntervalSince1970: 1_800_000_000))
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

    private struct FreshRuntime {
        var root: URL
        var session: CodexSession
        var manifest: CompanyFactoryManifest
    }

    private static func heartbeatDynamismResult(_ scenario: CompanyEvaluationScenario) -> CompanyEvaluationResult {
        do {
            var runtime = try freshRuntime(companyID: "eval-heartbeat", now: Date(timeIntervalSince1970: 1_800_000_000))
            runtime.session.heartbeatCount = 1
            let promptURL = runtime.root.appendingPathComponent("logs/eval-heartbeat.heartbeat-1.prompt")
            try FileManager.default.createDirectory(at: promptURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let prompt = heartbeatOneEvalPrompt(session: runtime.session)
            try prompt.write(to: promptURL, atomically: true, encoding: .utf8)

            let sandboxURL = runtime.root.appendingPathComponent("eval-heartbeat.sb")
            let plan = CodexSessionManager.heartbeatLaunchPlan(
                session: runtime.session,
                sandboxProfileURL: sandboxURL,
                promptFile: promptURL.path
            )
            let promptRoundTrip = (try? String(contentsOf: promptURL, encoding: .utf8)) ?? ""
            let passed = promptRoundTrip.contains(runtime.session.task) &&
                promptRoundTrip.contains("Heartbeat #1") &&
                plan.codexCommand.contains("codex exec") &&
                plan.codexCommand.contains(promptURL.path) &&
                plan.usesMacOSSandbox &&
                plan.usesCodexInternalSandboxBypass
            return result(
                scenario,
                passed: passed,
                findings: [
                    "promptContainsMission=\(promptRoundTrip.contains(runtime.session.task))",
                    "codexCommand=\(plan.codexCommand)",
                    "sandboxRuntime=\(plan.sandboxRuntimeLabel)"
                ],
                artifacts: [promptURL.path]
            )
        } catch {
            return result(scenario, passed: false, findings: ["fresh runtime failed: \(error.localizedDescription)"])
        }
    }

    private static func approvalGateResult(
        _ scenario: CompanyEvaluationScenario,
        now: Date
    ) -> CompanyEvaluationResult {
        do {
            let runtime = try freshRuntime(companyID: "eval-approval", now: now)
            let action = "publish public landing page for \(runtime.session.title)"
            let blocked = CompanyApprovalGate.evaluate(
                companyID: runtime.session.id,
                proposedAction: action,
                estimatedCostUSD: nil,
                now: now
            )
            let grantURL = URL(fileURLWithPath: runtime.session.approvalGrantPath)
            let missingGrantFileBlocks = blocked.status == .approvalRequired &&
                !FileManager.default.fileExists(atPath: grantURL.path)
            let request = CompanyApprovalRequest(
                id: "eval-public-publish-request",
                companyID: runtime.session.id,
                requestedAt: now,
                riskTier: .high,
                proposedAction: action,
                expectedEffect: "publish the public validation landing page",
                rollbackPlan: "unpublish the page and revert the release commit",
                status: .approved
            )
            let grant = CompanyApprovalGrant(
                request: request,
                grantedAt: now,
                expiresAt: now.addingTimeInterval(3_600),
                remainingUses: 1
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(grant).write(to: grantURL, options: [.atomic])
            let allowed = CompanyApprovalGate.evaluate(
                companyID: runtime.session.id,
                proposedAction: action,
                estimatedCostUSD: nil,
                now: now,
                requests: [request],
                grants: [grant]
            )
            return result(
                scenario,
                passed: missingGrantFileBlocks && allowed.status == .allowed && allowed.matchingGrantID == grant.id,
                findings: [
                    "withoutGrant=\(blocked.status.rawValue)",
                    "withGrant=\(allowed.status.rawValue)",
                    "grantFile=\(grantURL.path)"
                ],
                artifacts: [grantURL.path]
            )
        } catch {
            return result(scenario, passed: false, findings: ["fresh runtime failed: \(error.localizedDescription)"])
        }
    }

    private static func validationEvidenceResult(_ scenario: CompanyEvaluationScenario) -> CompanyEvaluationResult {
        let idea = CompanyIdeaEngine.candidates(limit: 1)[0]
        let plan = CompanyValidationEngine.plan(for: idea)
        let threshold = plan.successThreshold
        let strongMetrics = CompanyValidationResult.Metrics(
            interviewsCompleted: threshold.interviewsCompleted,
            replyRate: threshold.replyRate,
            signupRate: threshold.signupRate,
            willingnessToPayCount: threshold.willingnessToPayCount,
            competitorDensity: threshold.competitorDensity,
            cacEstimateUSD: threshold.cacEstimateUSD,
            timeToFirstDollarDays: threshold.timeToFirstDollarDays
        )
        let missingArtifacts = CompanyValidationResult(
            ideaID: idea.id,
            metrics: strongMetrics,
            sourceLinks: [],
            screenshots: [],
            rawResearchArtifacts: [],
            rationale: "metrics claimed without evidence"
        )
        let evidenced = CompanyValidationResult(
            ideaID: idea.id,
            metrics: strongMetrics,
            sourceLinks: ["https://example.com/interview-log"],
            screenshots: ["analytics-screenshot.png"],
            rawResearchArtifacts: ["reply-log.csv"],
            rationale: "multi-signal validation with raw artifacts"
        )
        let blockedDecision = CompanyValidationEngine.decide(idea: idea, plan: plan, result: missingArtifacts)
        let readyDecision = CompanyValidationEngine.decide(idea: idea, plan: plan, result: evidenced)
        let blockedLifecycle = CompanyLifecycleEngine.decide(evidenceSnapshot(
            companyID: "eval-validation",
            stage: .validating,
            validation: blockedDecision.decision,
            artifacts: []
        ))
        let readyLifecycle = CompanyLifecycleEngine.decide(evidenceSnapshot(
            companyID: "eval-validation",
            stage: .validating,
            validation: readyDecision.decision,
            artifacts: evidenced.sourceLinks + evidenced.screenshots + evidenced.rawResearchArtifacts
        ))
        return result(
            scenario,
            passed: blockedDecision.decision != .readyToBuild &&
                blockedLifecycle.to == .validating &&
                readyDecision.decision == .readyToBuild &&
                readyLifecycle.to == .building,
            findings: [
                "missingArtifactsDecision=\(blockedDecision.decision.rawValue)",
                "missingArtifactsLifecycle=\(blockedLifecycle.to.rawValue)",
                "evidencedDecision=\(readyDecision.decision.rawValue)",
                "evidencedLifecycle=\(readyLifecycle.to.rawValue)"
            ]
        )
    }

    private static func noProgressAutoPauseResult(_ scenario: CompanyEvaluationScenario) -> CompanyEvaluationResult {
        let prior = [
            heartbeatEvent(companyID: "eval-drift", reason: "no progress toward mission", secondsAgo: 120),
            heartbeatEvent(companyID: "eval-drift", reason: "no progress toward mission", secondsAgo: 60)
        ]
        let decision = CompanyStalemateDetector.detect(
            companyID: "eval-drift",
            currentStatus: .blocked,
            currentReason: "no progress toward mission",
            previousEvents: prior
        )
        return result(
            scenario,
            passed: decision?.action == .paused &&
                decision?.lifecycleStage == .paused &&
                decision?.consecutiveCount == CompanyStalemateDetector.defaultThreshold,
            findings: [
                "action=\(decision?.action.rawValue ?? "none")",
                "consecutive=\(decision?.consecutiveCount ?? 0)"
            ]
        )
    }

    private static func restartRecoveryResult(
        _ scenario: CompanyEvaluationScenario,
        now: Date
    ) -> CompanyEvaluationResult {
        do {
            var runtime = try freshRuntime(companyID: "eval-restart", now: now)
            runtime.session.status = .running
            runtime.session.heartbeatCount = 1
            runtime.session.pid = 99_999
            let lease = CodexSession.HeartbeatLease(
                id: "eval-lease",
                heartbeatCount: 1,
                acquiredAt: now.addingTimeInterval(-30),
                expiresAt: now.addingTimeInterval(300),
                ownerPID: 99_999
            )
            runtime.session.heartbeatLease = lease
            let recovered = CodexSessionManager.recoverSessionAfterRestart(
                runtime.session,
                now: now,
                retryJitterSeconds: 30
            )

            let lockURL = runtime.root.appendingPathComponent("heartbeat-locks/eval-restart.lock.json")
            try FileManager.default.createDirectory(at: lockURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let acquired = CodexSessionManager.tryAcquireHeartbeatLock(
                lockURL: lockURL,
                companyID: runtime.session.id,
                lease: lease,
                now: now
            )
            let duplicate = CodexSession.HeartbeatLease(
                id: "duplicate",
                heartbeatCount: 1,
                acquiredAt: now,
                expiresAt: now.addingTimeInterval(300),
                ownerPID: 111
            )
            let duplicateBlocked = !CodexSessionManager.tryAcquireHeartbeatLock(
                lockURL: lockURL,
                companyID: runtime.session.id,
                lease: duplicate,
                now: now
            )
            return result(
                scenario,
                passed: recovered.status == .queued &&
                    recovered.pid == nil &&
                    recovered.heartbeatLease?.id == lease.id &&
                    recovered.nextHeartbeatAt == lease.expiresAt.addingTimeInterval(30) &&
                    acquired &&
                    duplicateBlocked,
                findings: [
                    "recoveredStatus=\(recovered.status.rawValue)",
                    "leasePreserved=\(recovered.heartbeatLease?.id == lease.id)",
                    "duplicateLockBlocked=\(duplicateBlocked)"
                ],
                artifacts: [lockURL.path]
            )
        } catch {
            return result(scenario, passed: false, findings: ["fresh runtime failed: \(error.localizedDescription)"])
        }
    }

    private static func freshRuntime(companyID: String, now: Date) throws -> FreshRuntime {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-eval-\(companyID)-\(UUID().uuidString)", isDirectory: true)
        let worktree = root.appendingPathComponent("company", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        let mission = "Validate and launch a privacy-safe appointment reminder tool for Toronto clinics."
        let session = CodexSession(
            id: companyID,
            title: "Eval Clinic Reminder",
            task: mission,
            worktreePath: worktree.path,
            branch: "company/\(companyID)",
            status: .idle,
            startedAt: now,
            cadenceMinutes: 15,
            heartbeatCount: 0,
            nextHeartbeatAt: now,
            budget: .defaultState(now: now),
            lifecycleStage: .validating,
            sandboxMode: .sandbox,
            environment: .sandbox,
            assignedRunnerID: CompanyScaleScheduler.localRunnerID
        )
        try "# Company: \(session.title)\n# Mission: \(mission)\n"
            .write(to: URL(fileURLWithPath: session.journalPath), atomically: true, encoding: .utf8)
        try "# Revenue\n\n- baseline $0\n"
            .write(to: URL(fileURLWithPath: session.revenuePath), atomically: true, encoding: .utf8)
        try "[]\n".write(to: URL(fileURLWithPath: session.ledgerPath), atomically: true, encoding: .utf8)
        let manifest = CompanyFactory.manifest(companyID: companyID, template: nil, worktreePath: worktree.path, offer: mission)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: URL(fileURLWithPath: session.assetRegistryPath), options: [.atomic])
        for asset in manifest.assets {
            try CompanyFactory.starterContent(for: asset, manifest: manifest)
                .write(to: URL(fileURLWithPath: asset.path), atomically: true, encoding: .utf8)
        }
        return FreshRuntime(root: root, session: session, manifest: manifest)
    }

    private static func heartbeatOneEvalPrompt(session: CodexSession) -> String {
        """
        You are the autonomous CEO of "\(session.title)".

        MISSION (every heartbeat must move this forward - do not deviate): \(session.task)
        CURRENT LIFECYCLE STAGE: \(session.lifecycleStage.rawValue)

        Heartbeat #1. Read JOURNAL.md, then take one evidence-producing action that advances the mission.
        Approval-gated public actions must block until APPROVAL_GRANTED.json exists and matches the scope.

        REPEAT THE MISSION (do not deviate): \(session.task)
        """
    }

    private static func evidenceSnapshot(
        companyID: String,
        stage: CodexSession.LifecycleStage,
        validation: CompanyValidationResult.Decision?,
        artifacts: [String]
    ) -> CompanyEvidenceSnapshot {
        CompanyEvidenceSnapshot(
            companyID: companyID,
            stage: stage,
            validationDecision: validation,
            ledger: .empty,
            budgetReport: nil,
            distribution: nil,
            failureCount: 0,
            complianceRisk: .low,
            overrideReason: nil,
            artifactPaths: artifacts
        )
    }

    private static func heartbeatEvent(
        companyID: String,
        reason: String,
        secondsAgo: TimeInterval
    ) -> CompanyEvent {
        CompanyEvent(
            occurredAt: Date().addingTimeInterval(-secondsAgo),
            companyID: companyID,
            kind: .heartbeatFinished,
            summary: "Finished heartbeat with status blocked",
            metadata: [
                "status": CodexSession.Status.blocked.rawValue,
                "blockedReason": reason
            ]
        )
    }

    private static func result(
        _ scenario: CompanyEvaluationScenario,
        passed: Bool,
        findings: [String] = [],
        artifacts: [String] = []
    ) -> CompanyEvaluationResult {
        CompanyEvaluationResult(
            id: scenario.id,
            scenario: scenario,
            passed: passed,
            blocking: scenario.blocking,
            score: passed ? 100 : 0,
            findings: passed ? ["met expected behavior: \(scenario.expectedBehavior)"] : findings,
            artifacts: artifacts
        )
    }
}
