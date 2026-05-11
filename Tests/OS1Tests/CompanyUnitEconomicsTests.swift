import Foundation
import Testing
@testable import OS1

struct CompanyUnitEconomicsTests {
    @Test
    func revenueLedgerFeedsUnitEconomicsCalculations() {
        let report = CompanyUnitEconomicsEngine.evaluate(
            companyID: "company",
            ledger: healthyLedger(),
            cohorts: [cohort(channel: "seo", customers: 10, churned: 1, spend: 100, ltv: 600)]
        )

        #expect(report.verifiedRevenueUSD == 600)
        #expect(report.refundRate == 0.05)
        #expect(report.paymentFeesUSD == 20)
        #expect(report.computeCostUSD == 30)
        #expect(report.cacUSD == 10)
        #expect(report.ltvUSD == 60)
        #expect(report.channelReports["seo"]?.cacUSD == 10)
    }

    @Test
    func verifiedMetricsAreDistinguishedFromEstimates() {
        let verified = CompanyUnitEconomicsEngine.evaluate(
            companyID: "verified",
            ledger: healthyLedger(),
            cohorts: [cohort(channel: "seo", customers: 10, churned: 1, spend: 100, ltv: 600)]
        )
        let estimated = CompanyUnitEconomicsEngine.evaluate(
            companyID: "estimated",
            ledger: CompanyLedgerSummary(entries: [
                entry(id: "forecast", kind: .revenue, amount: 200, confidence: .estimated)
            ]),
            cohorts: []
        )

        #expect(verified.confidence == .verified)
        #expect(estimated.confidence == .immature)
        #expect(estimated.reasons.contains("metricsNotVerified"))
    }

    @Test
    func cannotAutoScaleUntilUnitEconomicsMeetThresholds() {
        let ledger = healthyLedger(netRevenue: 600, cost: 100)
        let weakEconomics = CompanyUnitEconomicsEngine.evaluate(
            companyID: "company",
            ledger: ledger,
            cohorts: [cohort(channel: "ads", customers: 10, churned: 5, spend: 1_000, ltv: 100)]
        )
        let decision = CompanyLifecycleEngine.decide(snapshot(ledger: ledger, unitEconomics: weakEconomics))

        #expect(!weakEconomics.canScale)
        #expect(decision.action == .pause)
        #expect(decision.rationale.contains("unit economics"))
    }

    @Test
    func scaleAllowedWhenUnitEconomicsMeetThresholds() {
        let ledger = healthyLedger(netRevenue: 600, cost: 100)
        let report = CompanyUnitEconomicsEngine.evaluate(
            companyID: "company",
            ledger: ledger,
            cohorts: [cohort(channel: "seo", customers: 10, churned: 1, spend: 50, ltv: 800)]
        )
        let decision = CompanyLifecycleEngine.decide(snapshot(ledger: ledger, unitEconomics: report))

        #expect(report.canScale)
        #expect(decision.action == .scale)
    }

    @Test
    func poorUnitEconomicsTriggerLifecycleReview() {
        let report = CompanyUnitEconomicsEngine.evaluate(
            companyID: "company",
            ledger: healthyLedger(netRevenue: 100, cost: 95),
            cohorts: [cohort(channel: "ads", customers: 5, churned: 2, spend: 500, ltv: 80)]
        )

        #expect(report.shouldReview)
        #expect(report.reasons.contains("contributionMarginBelowThreshold"))
        #expect(report.reasons.contains("churnRateAboveThreshold"))
    }

    private func snapshot(
        ledger: CompanyLedgerSummary,
        unitEconomics: CompanyUnitEconomicsReport
    ) -> CompanyEvidenceSnapshot {
        CompanyEvidenceSnapshot(
            companyID: "company",
            stage: .revenuePositive,
            validationDecision: nil,
            ledger: ledger,
            budgetReport: nil,
            distribution: nil,
            unitEconomics: unitEconomics,
            failureCount: 0,
            complianceRisk: .low,
            overrideReason: nil,
            artifactPaths: []
        )
    }

    private func healthyLedger(
        netRevenue: Double = 600,
        cost: Double = 50
    ) -> CompanyLedgerSummary {
        CompanyLedgerSummary(entries: [
            entry(id: "revenue", kind: .revenue, amount: netRevenue, confidence: .verified),
            entry(id: "refund", kind: .refund, amount: netRevenue * 0.05, confidence: .verified),
            entry(id: "fees", kind: .cost, category: .paymentFees, amount: 20, confidence: .verified),
            entry(id: "compute", kind: .cost, category: .cloudCompute, amount: 30, confidence: .verified),
            entry(id: "other", kind: .cost, category: .other, amount: max(0, cost - 50), confidence: .verified)
        ])
    }

    private func entry(
        id: String,
        kind: CompanyLedgerEntry.Kind,
        category: CompanyLedgerEntry.Category? = nil,
        amount: Double,
        confidence: CompanyLedgerEntry.Confidence
    ) -> CompanyLedgerEntry {
        CompanyLedgerEntry(
            id: id,
            companyID: "company",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            kind: kind,
            category: category,
            amountUSD: amount,
            source: "test",
            confidence: confidence,
            note: "id=\(id)"
        )
    }

    private func cohort(
        channel: String,
        customers: Int,
        churned: Int,
        spend: Double,
        ltv: Double
    ) -> CompanyUnitEconomicsCohort {
        CompanyUnitEconomicsCohort(
            id: channel,
            channel: channel,
            customersAcquired: customers,
            customersChurned: churned,
            acquisitionSpendUSD: spend,
            observedLTVUSD: ltv
        )
    }
}
