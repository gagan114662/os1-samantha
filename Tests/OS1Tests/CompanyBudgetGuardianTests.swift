import Foundation
import Testing
@testable import OS1

struct CompanyBudgetGuardianTests {
    @Test
    func spendTrackingSeparatesEstimatedActualChannelAndGlobalUsage() {
        let company = CompanyLedgerSummary(entries: [
            cost("codex-tokens", category: .tokenUsage, amount: 11, confidence: .estimated, source: "codex"),
            cost("orgo-vm", category: .cloudCompute, amount: 19, confidence: .verified, source: "orgo"),
            cost("etsy-api", category: .tools, amount: 7, confidence: .manual, source: "api")
        ])
        let other = CompanyLedgerSummary(entries: [
            cost("ads", category: .ads, amount: 13, confidence: .verified, source: "meta")
        ])

        let report = CompanyBudgetGuardian.evaluate(
            companyID: "company",
            ledger: company,
            budget: .defaultState(now: Date(timeIntervalSince1970: 1_800_000_000)),
            globalLedgerSummaries: [company, other]
        )

        #expect(report.companyEstimatedSpendUSD == 11)
        #expect(report.companyActualSpendUSD == 26)
        #expect(report.companySpendUSD == 37)
        #expect(report.globalSpendUSD == 50)
        #expect(report.status == .warning)
        #expect(report.reasons.contains("companyWarningLimit"))
        #expect(report.channelUsage.first(where: { $0.category == .tokenUsage })?.estimatedUSD == 11)
        #expect(report.channelUsage.first(where: { $0.category == .cloudCompute })?.actualUSD == 19)
    }

    @Test
    func hardStopRequiresExplicitBudgetApprovalBeforeMoreSpend() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = CompanyLedgerSummary(entries: [
            cost("ads", category: .ads, amount: 55, confidence: .verified, source: "meta")
        ])
        var budget = CodexSession.BudgetState.defaultState(now: now)

        let blocked = CompanyBudgetGuardian.evaluate(
            companyID: "company",
            ledger: ledger,
            budget: budget,
            globalLedgerSummaries: [ledger],
            now: now
        )

        #expect(blocked.status == .hardStop)
        #expect(blocked.shouldBlockHeartbeat)
        #expect(blocked.reasons.contains("companyHardLimit"))

        let request = CompanyApprovalRequest(
            id: "approval-1",
            companyID: "company",
            riskTier: .high,
            proposedAction: "Increase ads budget for capped paid campaign",
            expectedEffect: "Run one demand test",
            estimatedCostUSD: 40,
            rollbackPlan: "Stop campaign",
            status: .approved,
            decisionNote: "founder approved capped ad test",
            decidedAt: now,
            expiresAt: now.addingTimeInterval(3_600)
        )
        let approval = try #require(CompanyBudgetGuardian.approval(from: request, approvedAt: now, expiresAt: request.expiresAt))
        budget.approvals.append(approval)

        let approved = CompanyBudgetGuardian.evaluate(
            companyID: "company",
            ledger: ledger,
            budget: budget,
            globalLedgerSummaries: [ledger],
            now: now
        )

        #expect(approved.status == .warning)
        #expect(!approved.shouldBlockHeartbeat)
        #expect(approved.companyHardLimitUSD == 90)
        #expect(approved.channelUsage.first(where: { $0.category == .ads })?.hardLimitUSD == 65)
    }

    @Test
    func emergencyThresholdCannotBeBypassedByBudgetIncrease() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = CompanyLedgerSummary(entries: [
            cost("domain-purchase", category: .purchases, amount: 125, confidence: .verified, source: "namecheap")
        ])
        var budget = CodexSession.BudgetState.defaultState(now: now)
        budget.approvals.append(
            CompanyBudgetApproval(
                id: "approval-1",
                approvedAt: now,
                expiresAt: nil,
                reason: "large experiment",
                companyIncreaseUSD: 500,
                globalIncreaseUSD: 500,
                channelIncreasesUSD: [.purchases: 500]
            )
        )

        let report = CompanyBudgetGuardian.evaluate(
            companyID: "company",
            ledger: ledger,
            budget: budget,
            globalLedgerSummaries: [ledger],
            now: now
        )

        #expect(report.status == .emergencyShutdown)
        #expect(report.shouldBlockHeartbeat)
        #expect(report.reasons.contains("companyEmergencyShutdown"))
    }

    private func cost(
        _ id: String,
        category: CompanyLedgerEntry.Category,
        amount: Double,
        confidence: CompanyLedgerEntry.Confidence,
        source: String
    ) -> CompanyLedgerEntry {
        CompanyLedgerEntry(
            id: id,
            companyID: "company",
            occurredAt: nil,
            kind: .cost,
            category: category,
            amountUSD: amount,
            source: source,
            confidence: confidence,
            note: id
        )
    }
}
