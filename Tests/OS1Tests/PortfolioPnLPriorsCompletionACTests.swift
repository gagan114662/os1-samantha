import Foundation
import Testing
@testable import OS1

/// Acceptance-criteria tests for the #145 follow-up. PR #148 landed the
/// prior/posterior surface in `CompanyFleetRiskControls.swift`; this PR
/// closes the three remaining audit-flagged gaps:
///
/// - AC1 — Allocation recommender (`PortfolioAllocationRecommender`)
/// - AC2 — Calibration tracker (`PortfolioCalibrationTracker`)
/// - AC3 — Confidence intervals on every digest projection
///   (`PortfolioDigestRenderer` + `PortfolioDashboardView.renderedSummary`
///   banded overload)
struct PortfolioPnLPriorsCompletionACTests {

    // MARK: AC1 — Allocation recommender

    @Test
    func ac1_recommenderRanksByEVTimesTractabilityAndRespectsCapacity() {
        let posteriors = [
            makePosterior(id: "high-ev", ev: 1_500, low: 900, high: 2_100, tract: 0.7, prob: 0.55),
            makePosterior(id: "mid-ev", ev: 800, low: 500, high: 1_100, tract: 0.6, prob: 0.40),
            makePosterior(id: "low-ev", ev: 200, low: 100, high: 300, tract: 0.5, prob: 0.20),
            makePosterior(id: "tied", ev: 1_500, low: 900, high: 2_100, tract: 0.7, prob: 0.55)
        ]
        let recs = PortfolioAllocationRecommender.rank(
            posteriors: posteriors,
            capacity: .init(attentionSlots: 3, riskAppetite: .balanced),
            topN: 7
        )
        #expect(recs.count == 3) // capped by capacity, not topN
        #expect(recs.map(\.companyID) == ["high-ev", "tied", "mid-ev"])
        // ties broken by companyID alphabetical
        #expect(recs[0].rank == 1 && recs[1].rank == 2 && recs[2].rank == 3)
    }

    @Test
    func ac1_aggressiveAppetitePromotesWideCredibleBands() {
        let stable = makePosterior(id: "stable", ev: 1_000, low: 900, high: 1_100, tract: 0.7, prob: 0.6)
        let volatile = makePosterior(id: "volatile", ev: 1_000, low: 200, high: 1_800, tract: 0.7, prob: 0.6)
        let balanced = PortfolioAllocationRecommender.rank(
            posteriors: [stable, volatile],
            capacity: .init(attentionSlots: 2, riskAppetite: .balanced)
        )
        let aggressive = PortfolioAllocationRecommender.rank(
            posteriors: [stable, volatile],
            capacity: .init(attentionSlots: 2, riskAppetite: .aggressive)
        )
        let defensive = PortfolioAllocationRecommender.rank(
            posteriors: [stable, volatile],
            capacity: .init(attentionSlots: 2, riskAppetite: .defensive)
        )
        // Balanced ignores spread → companies score equally so alphabetical wins.
        #expect(balanced.first?.companyID == "stable")
        // Aggressive prefers wider spread.
        #expect(aggressive.first?.companyID == "volatile")
        // Defensive prefers narrow spread.
        #expect(defensive.first?.companyID == "stable")
    }

    @Test
    func ac1_zeroCapacityReturnsEmpty() {
        let posteriors = [makePosterior(id: "any", ev: 500, low: 400, high: 600, tract: 0.5, prob: 0.5)]
        let recs = PortfolioAllocationRecommender.rank(
            posteriors: posteriors,
            capacity: .init(attentionSlots: 0, riskAppetite: .balanced)
        )
        #expect(recs.isEmpty)
    }

    @Test
    func ac1_engineBridgeProducesIdenticalOutputFromNightlySnapshot() {
        let posteriors = [
            makePosterior(id: "a", ev: 800, low: 600, high: 1_000, tract: 0.6, prob: 0.4),
            makePosterior(id: "b", ev: 1_500, low: 900, high: 2_100, tract: 0.7, prob: 0.6)
        ]
        let snap = CompanyProfitNightlySnapshot(generatedAt: Date(), posteriors: posteriors)
        let direct = PortfolioAllocationRecommender.rank(posteriors: posteriors)
        let viaEngine = CompanyProfitPriorEngine.allocationRecommendations(snapshot: snap)
        #expect(direct == viaEngine)
    }

    @Test
    func ac1_recommendationReasoningCarriesScoreAndBand() {
        let p = makePosterior(id: "co", ev: 1_000, low: 700, high: 1_400, tract: 0.6, prob: 0.5)
        let rec = PortfolioAllocationRecommender.rank(posteriors: [p]).first!
        let reasoning = rec.reasoning.joined(separator: "|")
        #expect(reasoning.contains("score"))
        #expect(reasoning.contains("credible $700–$1400"))
        #expect(reasoning.contains("P(MRR≥target)"))
    }

    // MARK: AC2 — Calibration tracker

    @Test
    func ac2_calibrationSnapshotRoundTripsThroughDiskStore() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = PortfolioCalibrationTracker(directory: dir)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = PortfolioCalibrationTracker.Snapshot(
            takenAt: now,
            posteriors: [makePosterior(id: "a", ev: 1_000, low: 700, high: 1_300, tract: 0.6, prob: 0.5)]
        )
        try tracker.recordSnapshot(snapshot)
        let loaded = try tracker.loadSnapshots()
        #expect(loaded.count == 1)
        #expect(loaded.first?.posteriors.first?.companyID == "a")
    }

    @Test
    func ac2_evaluationReportsCalibrationErrorAndBandCoverageAcrossAQuarter() throws {
        // Fabricate one quarter of synthetic posteriors: 4 companies with mixed
        // EV and band widths. Realized revenue puts 2 inside the band, 2 outside.
        let snapshotAt = Date(timeIntervalSince1970: 1_800_000_000)
        let evaluationAt = snapshotAt.addingTimeInterval(Double(90 * 86_400))
        let posteriors = [
            makePosterior(id: "a", ev: 1_000, low: 800, high: 1_200, tract: 0.6, prob: 0.5),
            makePosterior(id: "b", ev: 500, low: 400, high: 600, tract: 0.5, prob: 0.4),
            makePosterior(id: "c", ev: 2_000, low: 1_500, high: 2_500, tract: 0.7, prob: 0.6),
            makePosterior(id: "d", ev: 300, low: 250, high: 350, tract: 0.4, prob: 0.3)
        ]
        let snapshot = PortfolioCalibrationTracker.Snapshot(takenAt: snapshotAt, posteriors: posteriors)
        let actuals: [String: Double] = [
            "a": 1_100, // inside band
            "b": 800,   // outside band — high
            "c": 1_800, // inside band
            "d": 100    // outside band — low
        ]
        let report = PortfolioCalibrationTracker.evaluate(
            snapshot: snapshot,
            actualRevenueUSD: actuals,
            evaluatedAt: evaluationAt
        )
        #expect(report.rows.count == 4)
        #expect(report.bandCoverage == 0.5) // 2 of 4 inside
        // mean relative error ≈ ((100/1100)+(300/800)+(200/1800)+(200/100))/4
        #expect(report.calibrationError > 0)
        #expect(report.snapshotTakenAt == snapshotAt)
        #expect(report.evaluatedAt == evaluationAt)
        #expect(report.horizonDays == 90)
        #expect(report.rows.map(\.companyID) == ["a", "b", "c", "d"]) // sorted alphabetical
    }

    @Test
    func ac2_snapshotDueReturnsMatureSnapshotOnly() throws {
        let dir = makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = PortfolioCalibrationTracker(directory: dir)
        let day0 = Date(timeIntervalSince1970: 1_700_000_000)
        let day30 = day0.addingTimeInterval(30 * 86_400)
        try tracker.recordSnapshot(.init(takenAt: day0, posteriors: []))
        try tracker.recordSnapshot(.init(takenAt: day30, posteriors: []))

        let early = try tracker.snapshotDue(at: day0.addingTimeInterval(45 * 86_400), horizonDays: 90)
        #expect(early == nil) // 45d after day0 hasn't reached the 90d horizon

        let mature = try tracker.snapshotDue(at: day0.addingTimeInterval(100 * 86_400), horizonDays: 90)
        #expect(mature?.takenAt == day0) // only day0 has matured

        let allMature = try tracker.snapshotDue(at: day0.addingTimeInterval(130 * 86_400), horizonDays: 90)
        #expect(allMature?.takenAt == day30) // latest mature snapshot wins
    }

    @Test
    func ac2_persistencePathIsSeparateFromPortfolioSnapshotsDirectory() {
        let tracker = PortfolioCalibrationTracker.defaultStore()
        #expect(tracker.directory.lastPathComponent == "portfolio-calibration")
        // Sanity: distinct from PR #208's snapshot path.
        #expect(tracker.directory.lastPathComponent != PortfolioSnapshotStore.directoryName)
    }

    // MARK: AC3 — Confidence intervals in the digest

    @Test
    func ac3_digestRendererEmitsBandSuffixOnEveryProjectionRow() {
        let report = makeReport(revenue: 8_200, cost: 4_000)
        let posteriors = [
            makePosterior(id: "co-acme", ev: 1_200, low: 900, high: 1_500, tract: 0.7, prob: 0.62),
            makePosterior(id: "co-beta", ev: 600, low: 400, high: 800, tract: 0.5, prob: 0.35)
        ]
        let recommendations = PortfolioAllocationRecommender.rank(
            posteriors: posteriors,
            capacity: .init(attentionSlots: 2, riskAppetite: .balanced)
        )
        let lines = PortfolioDigestRenderer.render(
            report: report,
            posteriors: posteriors,
            recommendations: recommendations
        )
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("revenue=$8,200.00"))
        #expect(joined.contains("band $1,300.00-$2,300.00")) // 900+400 .. 1500+800 (single $-sign from format())
        #expect(joined.contains("margin="))
        // Every allocation row carries a band suffix.
        let allocationRows = lines.filter { $0.hasPrefix("allocation|") }
        #expect(allocationRows.count == 2)
        #expect(allocationRows.allSatisfy { $0.contains("band=$") }) // format() already prefixes $
        #expect(allocationRows.allSatisfy { $0.contains("P(MRR>=target)=") })
    }

    @Test
    func ac3_pointEstimateOnlyDigestExplicitlyMarksBandsAsUnknown() {
        let report = makeReport(revenue: 100, cost: 50)
        let lines = PortfolioDigestRenderer.render(report: report)
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("revenue=$100.00 (band=unknown)"))
        #expect(joined.contains("margin=$50.00 (band=unknown)"))
    }

    @MainActor
    @Test
    func ac3_dashboardBandedRenderedSummaryIncludesBandSuffix() {
        let report = makeReport(revenue: 1_000, cost: 200)
        let posteriors = [makePosterior(id: "co-1", ev: 800, low: 600, high: 1_000, tract: 0.6, prob: 0.5)]
        let lines = PortfolioDashboardView.renderedSummary(
            report: report,
            posteriors: posteriors,
            recommendations: PortfolioAllocationRecommender.rank(posteriors: posteriors)
        )
        let joined = lines.joined(separator: "\n")
        #expect(joined.contains("band"))
        #expect(joined.contains("allocation|#1|co-1"))
    }

    @Test
    func ac3_digestFromExistingDigestRanksCarriesBandPerEntry() {
        let report = makeReport(revenue: 2_000, cost: 500)
        let ranks = [
            CompanyProfitDigestRank(
                rank: 1,
                companyID: "co-acme",
                score: 800,
                expectedValueUSD: 1_200,
                credibleIntervalUSD: 900...1_500,
                reasoning: ["test"]
            )
        ]
        let lines = PortfolioDigestRenderer.render(report: report, digest: ranks)
        let row = lines.first { $0.hasPrefix("digest|") }
        #expect(row != nil)
        #expect(row?.contains("band=$900.00-$1,500.00") == true)
    }

    // MARK: - Helpers

    private func makePosterior(
        id: String,
        ev: Double,
        low: Double,
        high: Double,
        tract: Double,
        prob: Double
    ) -> CompanyProfitPosterior {
        CompanyProfitPosterior(
            companyID: id,
            templateID: "tmpl",
            generatedAt: Date(timeIntervalSince1970: 1_800_000_000),
            companyAgeDays: 60,
            expectedValueUSD: ev,
            lowerCredibleUSD: low,
            upperCredibleUSD: high,
            tractability: tract,
            probabilityMRRExceedsTarget: prob,
            metricEstimates: [],
            reasoning: []
        )
    }

    private func makeReport(revenue: Double, cost: Double) -> PortfolioAggregateReport {
        PortfolioAggregateReport(
            generatedAt: Date(),
            granularity: .daily,
            windowStart: Date(),
            windowEnd: Date(),
            totalRevenueUSD: revenue,
            totalCostUSD: cost,
            buckets: [],
            companyReports: [
                PortfolioCompanyReport(
                    companyID: "co-acme",
                    displayName: "Acme",
                    lifecycleStage: .launched,
                    templateID: "tmpl",
                    revenueUSD: revenue,
                    costUSD: cost,
                    hasFinancialData: true
                )
            ],
            lifecycleDistribution: ["launched": 1],
            topPerformers: [PortfolioCompanyReport(
                companyID: "co-acme",
                displayName: "Acme",
                lifecycleStage: .launched,
                templateID: "tmpl",
                revenueUSD: revenue,
                costUSD: cost,
                hasFinancialData: true
            )],
            bottomPerformers: [],
            companyCount: 1,
            companiesWithMissingDataCount: 0,
            nativeCurrencies: ["USD"],
            recomputeTrigger: .heartbeat
        )
    }

    private func makeTempDir() -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("calibration-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}
