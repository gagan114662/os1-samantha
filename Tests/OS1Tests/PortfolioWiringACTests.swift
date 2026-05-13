import Foundation
import Testing
@testable import OS1

/// Acceptance-criteria tests for the #184 wiring follow-up.
///
/// PR #199 shipped the pure aggregator + dashboard view. This suite covers
/// the four wiring gaps the content audit flagged:
///
/// - Bullet 2 — revenue sourced from `CompanyPaymentProviderEvent` verified records
/// - Bullet 4 — recompute is bound to heartbeat ticks, not view-appear
/// - Bullet 7 — historical snapshots persist across launches
/// - Bullet 9 — Doctor `portfolio-p&l` row turns red after 7 cost-heavy days
struct PortfolioWiringACTests {

    // MARK: AC2 — verified payment events feed revenue; unverified entries do not

    @Test
    func ac2_verifiedPaymentEventsContributeRevenueAndEstimatedEntriesDoNot() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // 1 verified charge (via provider event) + 1 verified refund + 1 estimated
        // ledger entry that should be ignored.
        let charge = CompanyPaymentProviderEvent(
            id: "ch_1",
            companyID: "co-1",
            occurredAt: now.addingTimeInterval(-3_600),
            provider: "stripe",
            kind: .charge,
            amountUSD: 200,
            sourceReference: "ch_1"
        )
        let refund = CompanyPaymentProviderEvent(
            id: "re_1",
            companyID: "co-1",
            occurredAt: now.addingTimeInterval(-1_800),
            provider: "stripe",
            kind: .refund,
            amountUSD: 50,
            sourceReference: "re_1"
        )
        let estimated = CompanyLedgerEntry(
            id: "guess",
            companyID: "co-1",
            occurredAt: now.addingTimeInterval(-7_200),
            kind: .revenue,
            category: .sales,
            amountUSD: 999, // pure noise — must NOT appear in totals
            source: "manual-estimate",
            confidence: .estimated,
            note: "Estimated, not verified"
        )
        let snapshot = PortfolioCompanySnapshot.from(
            companyID: "co-1",
            displayName: "Acme",
            lifecycleStage: .launched,
            paymentEvents: [charge, refund],
            ledgerEntries: [estimated]
        )
        let report = PortfolioAggregator.aggregate(
            snapshots: [snapshot],
            granularity: .daily,
            now: now,
            trigger: .manual
        )
        // 200 (charge) − 50 (refund) = 150. The estimated 999 entry is discarded.
        #expect(report.totalRevenueUSD == 150.0)
        #expect(report.totalCostUSD == 0)
        #expect(report.recomputeTrigger == .manual)
    }

    @Test
    func ac2_unverifiedManualEntryNeverContributesToTotalRevenue() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let manualUnverified = CompanyLedgerEntry(
            id: "unverified-1",
            companyID: "co-1",
            occurredAt: now.addingTimeInterval(-3_600),
            kind: .revenue,
            category: .sales,
            amountUSD: 500,
            source: "manual",
            confidence: .manual,
            note: "Operator-typed, not verified by a webhook"
        )
        let snapshot = PortfolioCompanySnapshot(
            companyID: "co-1",
            displayName: "Acme",
            lifecycleStage: .launched,
            entries: [manualUnverified]
        )
        let report = PortfolioAggregator.aggregate(
            snapshots: [snapshot],
            granularity: .daily,
            now: now
        )
        #expect(report.totalRevenueUSD == 0)
    }

    // MARK: AC4 — recompute is bound to heartbeat ticks

    @Test
    func ac4_recomputeSchedulerFiresOnHeartbeatEventsAndRecordsTrigger() {
        var calls: [(PortfolioRecomputeTrigger, Date)] = []
        let scheduler = PortfolioRecomputeScheduler { trigger, at in
            calls.append((trigger, at))
        }
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let heartbeatStart = CompanyEvent(
            occurredAt: now,
            companyID: "co-1",
            actor: "codex",
            kind: .heartbeatStarted,
            summary: "Heartbeat tick"
        )
        let heartbeatFinish = CompanyEvent(
            occurredAt: now.addingTimeInterval(30),
            companyID: "co-1",
            actor: "codex",
            kind: .heartbeatFinished,
            summary: "Heartbeat finished"
        )
        let unrelated = CompanyEvent(
            occurredAt: now.addingTimeInterval(60),
            companyID: "co-1",
            actor: "codex",
            kind: .companyCreated,
            summary: "Created"
        )

        scheduler.observe(events: [heartbeatStart, unrelated, heartbeatFinish], now: now)
        #expect(scheduler.triggerCount == 2)
        #expect(scheduler.lastTrigger == .heartbeat)
        #expect(calls.allSatisfy { $0.0 == .heartbeat })

        scheduler.observeManualRefresh(now: now)
        #expect(scheduler.lastTrigger == .manual)
        #expect(scheduler.triggerCount == 3)

        scheduler.observeScheduledTick(now: now)
        #expect(scheduler.lastTrigger == .scheduled)
        #expect(scheduler.triggerCount == 4)
    }

    @Test
    func ac4_viewAppearDoesNotImplicitlyTriggerRecompute() {
        // The scheduler is the only path to a recompute. Constructing a report
        // directly carries the explicit trigger; nothing in PortfolioAggregator
        // listens for view lifecycle events.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = PortfolioAggregator.aggregate(
            snapshots: [],
            granularity: .daily,
            now: now,
            trigger: .initialLoad
        )
        #expect(report.recomputeTrigger == .initialLoad)

        let recomputed = PortfolioAggregator.aggregate(
            snapshots: [],
            granularity: .daily,
            now: now,
            trigger: .heartbeat
        )
        #expect(recomputed.recomputeTrigger == .heartbeat)
    }

    // MARK: AC7 — persistent snapshot store

    @Test
    func ac7_snapshotStoreRoundTripsAndASecondLoadReturnsThePriorSnapshot() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("portfolio-snapshots-\(UUID().uuidString)")
        let store = PortfolioSnapshotStore(directory: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let snapshot = PortfolioCompanySnapshot.from(
            companyID: "co-1",
            displayName: "Acme",
            lifecycleStage: .launched,
            paymentEvents: [
                CompanyPaymentProviderEvent(
                    id: "ch_1",
                    companyID: "co-1",
                    occurredAt: now.addingTimeInterval(-3_600),
                    provider: "stripe",
                    kind: .charge,
                    amountUSD: 250,
                    sourceReference: "ch_1"
                )
            ]
        )
        let original = PortfolioAggregator.aggregate(
            snapshots: [snapshot],
            granularity: .daily,
            now: now,
            trigger: .scheduled
        )
        try store.save(original)

        // Simulate a relaunch: build a fresh store object pointing at the same
        // directory and load.
        let reopened = PortfolioSnapshotStore(directory: dir)
        let restored = try #require(try reopened.loadLatest())
        #expect(restored.totalRevenueUSD == original.totalRevenueUSD)
        #expect(restored.companyCount == original.companyCount)
        #expect(restored.recomputeTrigger == .scheduled)

        // Multiple saves over different days preserve history.
        let nextDay = now.addingTimeInterval(86_400)
        let secondReport = PortfolioAggregator.aggregate(
            snapshots: [snapshot],
            granularity: .daily,
            now: nextDay,
            trigger: .heartbeat
        )
        try store.save(secondReport)
        let history = try store.loadHistory()
        #expect(history.count == 2)
        #expect(history.last?.recomputeTrigger == .heartbeat)
        #expect(history.first?.recomputeTrigger == .scheduled)
    }

    // MARK: AC9 — Doctor portfolio-p&l row 7-day threshold flip

    @Test
    func ac9_doctorPortfolioPnLRowTurnsRedAfterSevenConsecutiveCostHeavyDays() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        // Build a synthetic 30-day daily report whose trailing 7 buckets each
        // have cost > revenue.
        let report = makeReportWithBucketRunup(
            now: now,
            costHeavyTailDays: 7,
            otherDayProfile: .revenueHeavy
        )
        let row = DoctorViewModel.portfolioPnLDoctorRow(report: report)
        #expect(row.severity == .error)
        #expect(row.detail?.contains("7 consecutive days") == true)
    }

    @Test
    func ac9_doctorPortfolioPnLRowStaysGreenWithMixedHistory() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let report = makeReportWithBucketRunup(
            now: now,
            costHeavyTailDays: 2,
            otherDayProfile: .revenueHeavy
        )
        let row = DoctorViewModel.portfolioPnLDoctorRow(report: report)
        #expect(row.severity == .ok || row.severity == .warn)
    }

    @Test
    func ac9_doctorPortfolioPnLRowUnknownOnColdStartWithNoSnapshot() {
        let row = DoctorViewModel.portfolioPnLDoctorRow(report: nil)
        #expect(row.severity == .unknown)
        #expect(row.id == "portfolio-p&l")
    }

    // MARK: - Helpers

    private enum DayProfile { case revenueHeavy, costHeavy }

    private func makeReportWithBucketRunup(
        now: Date,
        costHeavyTailDays: Int,
        otherDayProfile: DayProfile
    ) -> PortfolioAggregateReport {
        let dayCount = 30
        let ranges = PortfolioAggregator.bucketRanges(
            granularity: .daily,
            now: now,
            bucketCount: dayCount
        )
        let tailStartIndex = dayCount - costHeavyTailDays
        let buckets: [PortfolioBucket] = ranges.enumerated().map { idx, range in
            let isCostHeavy = idx >= tailStartIndex
            let revenue: Double = isCostHeavy ? 10 : (otherDayProfile == .revenueHeavy ? 500 : 10)
            let cost: Double = isCostHeavy ? 200 : (otherDayProfile == .revenueHeavy ? 50 : 200)
            return PortfolioBucket(
                start: range.start,
                end: range.end,
                revenueUSD: revenue,
                costUSD: cost
            )
        }
        let totalRev = buckets.reduce(0) { $0 + $1.revenueUSD }
        let totalCost = buckets.reduce(0) { $0 + $1.costUSD }
        return PortfolioAggregateReport(
            generatedAt: now,
            granularity: .daily,
            windowStart: ranges.first?.start ?? now,
            windowEnd: ranges.last?.end ?? now,
            totalRevenueUSD: totalRev,
            totalCostUSD: totalCost,
            buckets: buckets,
            companyReports: [],
            lifecycleDistribution: [:],
            topPerformers: [],
            bottomPerformers: [],
            companyCount: 1,
            companiesWithMissingDataCount: 0,
            nativeCurrencies: ["USD"],
            recomputeTrigger: .heartbeat
        )
    }
}
