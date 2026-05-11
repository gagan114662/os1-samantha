import Foundation
import Testing
@testable import OS1

struct CompanyLedgerTests {
    @Test
    func markdownSummarySeparatesRevenueCostAndConfidence() {
        let markdown = """
        - 2026-05-11 Stripe checkout paid: $29.00 id=cs_123
        - 2026-05-11 cloud cost: $4.50 receipt=orgo
        - estimated revenue projection: $500
        - manual sale recorded by founder: $10
        - no revenue API connected yet
        """

        let summary = CompanyLedgerParser.summarize(revenueMarkdown: markdown)

        #expect(summary.revenueUSD == 539.0)
        #expect(summary.costUSD == 4.5)
        #expect(summary.netUSD == 534.5)
        #expect(summary.verifiedRevenueUSD == 29.0)
        #expect(summary.hasVerifiedRevenue)
    }

    @Test
    func ledgerJSONEntriesAreIncludedInSummary() throws {
        let entries = [
            CompanyLedgerEntry(
                id: "stripe-1",
                companyID: "abc",
                occurredAt: nil,
                kind: .revenue,
                amountUSD: 99,
                source: "stripe",
                confidence: .verified,
                note: "checkout id=cs_1"
            ),
            CompanyLedgerEntry(
                id: "token-1",
                companyID: "abc",
                occurredAt: nil,
                kind: .cost,
                amountUSD: 12.25,
                source: "codex",
                confidence: .estimated,
                note: "token estimate"
            )
        ]
        let data = try JSONEncoder().encode(entries)
        let summary = CompanyLedgerParser.summarize(
            revenueMarkdown: "",
            ledgerJSON: String(data: data, encoding: .utf8) ?? ""
        )

        #expect(summary.revenueUSD == 99)
        #expect(summary.costUSD == 12.25)
        #expect(summary.netUSD == 86.75)
        #expect(summary.hasVerifiedRevenue)
    }

    @Test
    func profitAndLossComputesRefundsMarginROIAndTraceability() throws {
        let day0 = Date(timeIntervalSince1970: 1_800_000_000)
        let day2 = day0.addingTimeInterval(172_800)
        let sourceEventID = UUID()
        let entries = [
            CompanyLedgerEntry(
                id: "stripe-1",
                companyID: "abc",
                occurredAt: day2,
                kind: .revenue,
                category: .sales,
                amountUSD: 120,
                source: "stripe",
                sourceEventID: sourceEventID,
                sourceReference: "checkout=cs_1",
                confidence: .verified,
                note: "checkout=cs_1"
            ),
            CompanyLedgerEntry(
                id: "refund-1",
                companyID: "abc",
                occurredAt: day2,
                kind: .refund,
                category: .refund,
                amountUSD: 20,
                source: "stripe",
                sourceReference: "refund=re_1",
                confidence: .verified,
                note: "refund re_1"
            ),
            CompanyLedgerEntry(
                id: "cloud-1",
                companyID: "abc",
                occurredAt: day0,
                kind: .cost,
                category: .cloudCompute,
                amountUSD: 25,
                source: "orgo",
                sourceReference: "receipt=orgo_1",
                confidence: .verified,
                note: "receipt=orgo_1"
            )
        ]

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(entries)
        let summary = CompanyLedgerParser.summarize(
            revenueMarkdown: "",
            ledgerJSON: String(data: data, encoding: .utf8) ?? ""
        )

        #expect(summary.revenueUSD == 120)
        #expect(summary.refundUSD == 20)
        #expect(summary.netRevenueUSD == 100)
        #expect(summary.netUSD == 75)
        #expect(summary.contributionMargin == 0.75)
        #expect(summary.roi == 3)
        #expect(summary.paybackPeriodDays == 2)
        #expect(summary.tracedEntryCount == 3)
        #expect(summary.canMarkProfitable)
    }

    @Test
    func profitabilityGuardRejectsUnverifiedProfitAndPausesLosses() {
        let estimatedProfit = CompanyLedgerSummary(entries: [
            CompanyLedgerEntry(
                id: "estimate",
                companyID: "abc",
                occurredAt: nil,
                kind: .revenue,
                amountUSD: 500,
                source: "manual",
                confidence: .estimated,
                note: "forecast"
            )
        ])
        let loss = CompanyLedgerSummary(entries: [
            CompanyLedgerEntry(
                id: "ads",
                companyID: "abc",
                occurredAt: nil,
                kind: .cost,
                category: .ads,
                amountUSD: 75,
                source: "manual",
                confidence: .manual,
                note: "ad spend"
            )
        ])
        let override = CompanyLedgerSummary(entries: [
            CompanyLedgerEntry(
                id: "override",
                companyID: "abc",
                occurredAt: nil,
                kind: .revenue,
                amountUSD: 100,
                source: "manual",
                confidence: .manualOverride,
                note: "founder manual override after bank reconciliation"
            )
        ])

        #expect(!estimatedProfit.canMarkProfitable)
        #expect(CompanyProfitabilityGuard.evaluate(summary: estimatedProfit).reasons.contains("unverifiedProfit"))
        #expect(CompanyProfitabilityGuard.evaluate(summary: loss).shouldPause)
        #expect(override.canMarkProfitable)
    }
}
