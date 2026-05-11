import Foundation
import Testing
@testable import OS1

struct CompanyLifecycleEngineTests {
    @Test
    func validationCannotPromoteWithoutSatisfiedGateOrOverride() {
        let evidence = snapshot(stage: .validating, validation: .needsMoreEvidence)
        let decision = CompanyLifecycleEngine.decide(evidence)

        #expect(decision.action == .hold)
        #expect(decision.to == .validating)
        #expect(decision.requiresOverride)
    }

    @Test
    func readyValidationPromotesToBuilding() {
        let evidence = snapshot(stage: .validating, validation: .readyToBuild)
        let decision = CompanyLifecycleEngine.decide(evidence)

        #expect(decision.action == .promote)
        #expect(decision.to == .building)
    }

    @Test
    func riskBudgetAndFailureBreachesPauseOrKillAutomatically() {
        let critical = CompanyLifecycleEngine.decide(snapshot(stage: .building, risk: .critical))
        let failures = CompanyLifecycleEngine.decide(snapshot(stage: .launched, failures: 5))
        let loss = CompanyLifecycleEngine.decide(snapshot(stage: .launched, ledger: CompanyLedgerSummary(entries: [
            CompanyLedgerEntry(id: "loss", companyID: "c", occurredAt: nil, kind: .cost, amountUSD: 100, source: "manual", confidence: .manual, note: "loss")
        ])))
        let hardBudget = CompanyLifecycleEngine.decide(snapshot(stage: .launched, budgetStatus: .hardStop))
        let emergencyBudget = CompanyLifecycleEngine.decide(snapshot(stage: .launched, budgetStatus: .emergencyShutdown))

        #expect(critical.action == .kill)
        #expect(failures.action == .pause)
        #expect(loss.action == .pause)
        #expect(hardBudget.action == .pause)
        #expect(emergencyBudget.action == .kill)
    }

    @Test
    func killedCompaniesKeepArtifactPathsInEvidenceSnapshot() {
        let evidence = snapshot(stage: .validating, validation: .rejected, artifacts: ["JOURNAL.md", "REVENUE.md", "COMPANY_ASSETS.json"])
        let decision = CompanyLifecycleEngine.decide(evidence)

        #expect(decision.action == .kill)
        #expect(decision.evidence.artifactPaths.contains("JOURNAL.md"))
        #expect(decision.evidence.artifactPaths.contains("COMPANY_ASSETS.json"))
    }

    @Test
    func paidLaunchRequiresLegalReadinessGate() {
        let blocked = CompanyLifecycleEngine.decide(snapshot(
            stage: .building,
            distribution: activeDistribution(),
            legal: CompanyLegalReadiness(
                companyID: "company",
                blockers: ["Privacy policy link is required."],
                policyLinks: [:],
                reviewedAt: nil,
                approvalRequestID: nil
            )
        ))
        let approved = CompanyLifecycleEngine.decide(snapshot(
            stage: .building,
            distribution: activeDistribution(),
            legal: CompanyLegalReadiness(
                companyID: "company",
                blockers: [],
                policyLinks: [:],
                reviewedAt: Date(timeIntervalSince1970: 1_800_000_000),
                approvalRequestID: "approval-legal"
            )
        ))

        #expect(blocked.action == .hold)
        #expect(blocked.rationale.contains("Legal launch gate blocked paid launch"))
        #expect(approved.action == .promote)
        #expect(approved.to == .launched)
    }

    @Test
    func portfolioRanksByEvidenceRevenueProfitAndRisk() {
        let winner = snapshot(stage: .launched, ledger: CompanyLedgerSummary(entries: [
            CompanyLedgerEntry(id: "rev", companyID: "winner", occurredAt: nil, kind: .revenue, amountUSD: 200, source: "stripe", confidence: .verified, note: "id=cs_1"),
            CompanyLedgerEntry(id: "cost", companyID: "winner", occurredAt: nil, kind: .cost, amountUSD: 20, source: "ads", confidence: .verified, note: "receipt=ad_1")
        ]), artifacts: ["winner"])
        let loser = snapshot(companyID: "loser", stage: .validating, validation: .needsMoreEvidence, risk: .high, artifacts: ["loser"])

        let ranks = CompanyLifecycleEngine.rankPortfolio([loser, winner])

        #expect(ranks.first?.companyID == "company")
        #expect(ranks.first?.profitUSD == 180)
    }

    private func snapshot(
        companyID: String = "company",
        stage: CodexSession.LifecycleStage,
        validation: CompanyValidationResult.Decision? = nil,
        ledger: CompanyLedgerSummary = .empty,
        budgetStatus: CompanyBudgetStatus? = nil,
        distribution: CompanyDistributionSummary? = nil,
        legal: CompanyLegalReadiness? = nil,
        failures: Int = 0,
        risk: CompanyIdea.RiskTier = .low,
        artifacts: [String] = []
    ) -> CompanyEvidenceSnapshot {
        CompanyEvidenceSnapshot(
            companyID: companyID,
            stage: stage,
            validationDecision: validation,
            ledger: ledger,
            budgetReport: budgetStatus.map {
                CompanyBudgetReport(
                    companyID: companyID,
                    status: $0,
                    companyEstimatedSpendUSD: 0,
                    companyActualSpendUSD: 0,
                    companyHardLimitUSD: 50,
                    companyEmergencyLimitUSD: 100,
                    globalSpendUSD: 0,
                    globalHardLimitUSD: 500,
                    globalEmergencyLimitUSD: 750,
                    channelUsage: [],
                    reasons: [$0.rawValue]
                )
            },
            distribution: distribution,
            legalReadiness: legal,
            failureCount: failures,
            complianceRisk: risk,
            overrideReason: nil,
            artifactPaths: artifacts
        )
    }

    private func activeDistribution() -> CompanyDistributionSummary {
        CompanyDistributionSummary(
            active: [
                CompanyGrowthCampaign(
                    id: "campaign-1",
                    companyID: "company",
                    channel: .seoPages,
                    audience: "buyers",
                    creative: "publish paid landing page",
                    spendLimitUSD: 0,
                    approvalState: .approved,
                    complianceChecks: ["claims review"],
                    complianceDecision: .approved,
                    rateLimitPerDay: 5,
                    suppressionList: [],
                    nextAction: "launch"
                )
            ],
            blocked: [],
            nextRecommendedAction: "launch",
            revenueLedgerEntries: []
        )
    }
}
