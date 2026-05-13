import Foundation
import Testing
@testable import OS1

struct PortfolioAggregatorTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func emptyPortfolioProducesZeroAggregates() {
        let report = PortfolioAggregator.aggregate(
            snapshots: [],
            granularity: .daily,
            now: now
        )

        #expect(report.isEmpty)
        #expect(report.companyCount == 0)
        #expect(report.totalRevenueUSD == 0)
        #expect(report.totalCostUSD == 0)
        #expect(report.totalMarginUSD == 0)
        #expect(report.lifecycleDistribution.isEmpty)
        #expect(report.topPerformers.isEmpty)
        #expect(report.bottomPerformers.isEmpty)
        #expect(report.companiesWithMissingDataCount == 0)
        #expect(report.buckets.count == PortfolioGranularity.daily.defaultBucketCount)
        #expect(report.buckets.allSatisfy { $0.revenueUSD == 0 && $0.costUSD == 0 })
    }

    @Test
    func oneCompanyAggregatesVerifiedRevenueAndCost() {
        let revenueEntry = CompanyLedgerEntry(
            id: "rev-1",
            companyID: "co-1",
            occurredAt: now.addingTimeInterval(-3_600),
            kind: .revenue,
            amountUSD: 120,
            source: "stripe",
            confidence: .verified,
            note: "checkout id=cs_1"
        )
        let costEntry = CompanyLedgerEntry(
            id: "cost-1",
            companyID: "co-1",
            occurredAt: now.addingTimeInterval(-7_200),
            kind: .cost,
            amountUSD: 30,
            source: "codex",
            confidence: .estimated,
            note: "compute"
        )
        let estimatedRevenueEntry = CompanyLedgerEntry(
            id: "rev-2",
            companyID: "co-1",
            occurredAt: now.addingTimeInterval(-3_600),
            kind: .revenue,
            amountUSD: 999,
            source: "forecast",
            confidence: .estimated,
            note: "projection — must NOT count"
        )

        let snapshot = PortfolioCompanySnapshot(
            companyID: "co-1",
            displayName: "Solo Co",
            lifecycleStage: .launched,
            templateID: "tpl-newsletter",
            entries: [revenueEntry, costEntry, estimatedRevenueEntry],
            lastUpdatedAt: now
        )

        let report = PortfolioAggregator.aggregate(
            snapshots: [snapshot],
            granularity: .daily,
            now: now
        )

        #expect(report.companyCount == 1)
        #expect(report.totalRevenueUSD == 120)
        #expect(report.totalCostUSD == 30)
        #expect(report.totalMarginUSD == 90)
        #expect(report.lifecycleDistribution["launched"] == 1)
        #expect(report.topPerformers.count == 1)
        #expect(report.topPerformers.first?.companyID == "co-1")
        #expect(report.companiesWithMissingDataCount == 0)
    }

    @Test
    func mixedCurrenciesRecordedButNotConverted() {
        // Caller is responsible for converting to USD before constructing
        // the snapshot. Aggregator records native currencies for provenance
        // and trusts the USD totals.
        let usdEntry = CompanyLedgerEntry(
            id: "rev-usd",
            companyID: "co-usd",
            occurredAt: now.addingTimeInterval(-3_600),
            kind: .revenue,
            amountUSD: 100,
            source: "stripe",
            confidence: .verified,
            note: "usd checkout"
        )
        let eurAsUSDEntry = CompanyLedgerEntry(
            id: "rev-eur",
            companyID: "co-eur",
            occurredAt: now.addingTimeInterval(-3_600),
            kind: .revenue,
            amountUSD: 55,
            source: "stripe-eu",
            confidence: .verified,
            note: "EUR 50 normalized to USD 55"
        )
        let jpyAsUSDEntry = CompanyLedgerEntry(
            id: "rev-jpy",
            companyID: "co-jpy",
            occurredAt: now.addingTimeInterval(-3_600),
            kind: .revenue,
            amountUSD: 7.50,
            source: "stripe-jp",
            confidence: .verified,
            note: "JPY 1100 normalized to USD 7.50"
        )

        let snapshots = [
            PortfolioCompanySnapshot(
                companyID: "co-usd",
                displayName: "USA",
                lifecycleStage: .launched,
                nativeCurrency: "USD",
                entries: [usdEntry]
            ),
            PortfolioCompanySnapshot(
                companyID: "co-eur",
                displayName: "Europe",
                lifecycleStage: .launched,
                nativeCurrency: "EUR",
                entries: [eurAsUSDEntry]
            ),
            PortfolioCompanySnapshot(
                companyID: "co-jpy",
                displayName: "Japan",
                lifecycleStage: .building,
                nativeCurrency: "JPY",
                entries: [jpyAsUSDEntry]
            )
        ]

        let report = PortfolioAggregator.aggregate(
            snapshots: snapshots,
            granularity: .weekly,
            now: now
        )

        #expect(report.nativeCurrencies == ["EUR", "JPY", "USD"])
        #expect(report.totalRevenueUSD == 162.50)
        #expect(report.totalCostUSD == 0)
        #expect(report.totalMarginUSD == 162.50)
        #expect(report.companyCount == 3)
    }

    @Test
    func companyMissingFinancialDataIsCountedButDoesNotCrash() {
        let healthy = PortfolioCompanySnapshot(
            companyID: "co-ok",
            displayName: "Healthy Co",
            lifecycleStage: .launched,
            entries: [
                CompanyLedgerEntry(
                    id: "rev",
                    companyID: "co-ok",
                    occurredAt: now.addingTimeInterval(-1_800),
                    kind: .revenue,
                    amountUSD: 50,
                    source: "stripe",
                    confidence: .verified,
                    note: "ok"
                )
            ]
        )
        let missingDates = PortfolioCompanySnapshot(
            companyID: "co-missing",
            displayName: "Missing Co",
            lifecycleStage: .idea,
            entries: [
                CompanyLedgerEntry(
                    id: "rev-undated",
                    companyID: "co-missing",
                    occurredAt: nil,
                    kind: .revenue,
                    amountUSD: 25,
                    source: "manual",
                    confidence: .manualOverride,
                    note: "undated founder override"
                )
            ]
        )
        let empty = PortfolioCompanySnapshot(
            companyID: "co-empty",
            displayName: "Empty Co",
            lifecycleStage: nil,
            entries: []
        )

        let report = PortfolioAggregator.aggregate(
            snapshots: [healthy, missingDates, empty],
            granularity: .daily,
            now: now
        )

        #expect(report.companyCount == 3)
        #expect(report.companiesWithMissingDataCount == 2)
        // Undated revenue still counts toward total revenue but not buckets.
        #expect(report.totalRevenueUSD == 75)
        let bucketRevenue = report.buckets.reduce(0) { $0 + $1.revenueUSD }
        #expect(bucketRevenue == 50)
        // Lifecycle for the nil-stage company is recorded under "unknown".
        #expect(report.lifecycleDistribution["unknown"] == 1)
        #expect(report.lifecycleDistribution["idea"] == 1)
        #expect(report.lifecycleDistribution["launched"] == 1)
        // Only companies with financial data are rankable.
        #expect(report.topPerformers.contains { $0.companyID == "co-ok" })
        #expect(!report.topPerformers.contains { $0.companyID == "co-empty" })
    }

    @Test
    func twentyCompanySyntheticPortfolioMatchesTolerance() {
        // AC: synthetic portfolio of 20 companies with mixed lifecycle +
        // ledger data renders the expected aggregates within a documented
        // tolerance.
        let stages: [CodexSession.LifecycleStage] = [
            .idea, .validating, .building, .launched, .revenuePositive,
            .scaling, .paused, .killed, .pivoting, .launched
        ]

        let snapshots = (0..<20).map { index -> PortfolioCompanySnapshot in
            let stage = stages[index % stages.count]
            let dayOffset = -Double((index % 7) + 1) * 86_400
            let revenue: Double = stage == .killed || stage == .idea ? 0 : Double((index + 1) * 10)
            let cost: Double = Double((index % 5) + 1) * 4

            var entries: [CompanyLedgerEntry] = [
                CompanyLedgerEntry(
                    id: "cost-\(index)",
                    companyID: "co-\(index)",
                    occurredAt: now.addingTimeInterval(dayOffset),
                    kind: .cost,
                    amountUSD: cost,
                    source: "compute",
                    confidence: .estimated,
                    note: "synthetic compute"
                )
            ]
            if revenue > 0 {
                entries.append(
                    CompanyLedgerEntry(
                        id: "rev-\(index)",
                        companyID: "co-\(index)",
                        occurredAt: now.addingTimeInterval(dayOffset + 60),
                        kind: .revenue,
                        amountUSD: revenue,
                        source: "stripe",
                        confidence: .verified,
                        note: "synthetic revenue"
                    )
                )
            }

            return PortfolioCompanySnapshot(
                companyID: "co-\(index)",
                displayName: "Co \(index)",
                lifecycleStage: stage,
                templateID: "tpl-\(index % 3)",
                entries: entries
            )
        }

        let report = PortfolioAggregator.aggregate(
            snapshots: snapshots,
            granularity: .daily,
            now: now,
            topN: 3
        )

        let expectedRevenue = snapshots.reduce(0.0) { acc, snap in
            acc + snap.entries
                .filter { $0.kind == .revenue && $0.confidence == .verified }
                .reduce(0) { $0 + $1.amountUSD }
        }
        let expectedCost = snapshots.reduce(0.0) { acc, snap in
            acc + snap.entries.filter { $0.kind == .cost }.reduce(0) { $0 + $1.amountUSD }
        }

        let tolerance = 0.01
        #expect(abs(report.totalRevenueUSD - expectedRevenue) <= tolerance)
        #expect(abs(report.totalCostUSD - expectedCost) <= tolerance)
        #expect(report.companyCount == 20)
        #expect(report.topPerformers.count == 3)
        #expect(report.bottomPerformers.count == 3)
        #expect(report.lifecycleDistribution.values.reduce(0, +) == 20)
    }

    @Test
    func reportRoundtripsThroughJSONExport() throws {
        let snapshot = PortfolioCompanySnapshot(
            companyID: "co-export",
            displayName: "Export Co",
            lifecycleStage: .launched,
            entries: [
                CompanyLedgerEntry(
                    id: "rev",
                    companyID: "co-export",
                    occurredAt: now.addingTimeInterval(-1_800),
                    kind: .revenue,
                    amountUSD: 250,
                    source: "stripe",
                    confidence: .verified,
                    note: "ok"
                )
            ]
        )
        let report = PortfolioAggregator.aggregate(
            snapshots: [snapshot],
            granularity: .monthly,
            now: now
        )
        let json = try report.jsonExport()
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(PortfolioAggregateReport.self, from: json)
        #expect(decoded.totalRevenueUSD == report.totalRevenueUSD)
        #expect(decoded.companyCount == report.companyCount)
    }
}
