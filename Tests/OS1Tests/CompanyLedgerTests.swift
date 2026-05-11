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
}
