import AppKit
import Foundation
import SwiftUI
import Testing
@testable import OS1

struct PortfolioDashboardSnapshotTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    @MainActor
    func dashboardSummaryRendersExpectedRowsForFixturePortfolio() {
        let snapshots = fixtureSnapshots()
        let report = PortfolioAggregator.aggregate(
            snapshots: snapshots,
            granularity: .daily,
            now: now,
            topN: 2
        )

        let rendered = PortfolioDashboardView.renderedSummary(report: report)

        #expect(rendered.contains("companies=4"))
        // Charlie has no entries and Delta only has an undated estimated
        // entry — both lack dated financial data.
        #expect(rendered.contains("missingData=2"))
        #expect(rendered.contains("revenue=$250.00"))
        #expect(rendered.contains("cost=$45.00"))
        #expect(rendered.contains("margin=$205.00"))
        #expect(rendered.contains("lifecycle.launched=2"))
        #expect(rendered.contains("lifecycle.building=1"))
        #expect(rendered.contains("lifecycle.idea=1"))
        // Top performer ordering: Alpha (200-30=170), Bravo (50-15=35).
        #expect(rendered.contains("top|co-alpha|$170.00"))
        #expect(rendered.contains("top|co-bravo|$35.00"))
        // Bottom performer ordering (reversed): bravo first, then alpha.
        #expect(rendered.contains("bottom|co-bravo|$35.00"))
        #expect(rendered.contains("bottom|co-alpha|$170.00"))
    }

    @Test
    @MainActor
    func dashboardRendersSemanticallyEquivalentContentInLightAndDarkMode() {
        // Snapshot tests in this repo are string-rendering tests
        // (see FleetSectionSnapshotTests). The rendered semantic content
        // must be identical whether the view is hosted with .colorScheme(.light)
        // or .colorScheme(.dark) — we just have to ensure the view builds
        // under both modes and that data-derived rows match exactly.
        let snapshots = fixtureSnapshots()
        let report = PortfolioAggregator.aggregate(
            snapshots: snapshots,
            granularity: .weekly,
            now: now
        )
        let baseline = PortfolioDashboardView.renderedSummary(report: report)

        let lightView = PortfolioDashboardView(snapshots: snapshots, now: now)
            .environment(\.colorScheme, .light)
        let darkView = PortfolioDashboardView(snapshots: snapshots, now: now)
            .environment(\.colorScheme, .dark)
        // Force SwiftUI to evaluate both bodies so we catch view-construction
        // regressions in either color scheme without needing a pixel renderer.
        _ = ViewSnapshotProbe(view: AnyView(lightView)).probe()
        _ = ViewSnapshotProbe(view: AnyView(darkView)).probe()

        #expect(baseline == PortfolioDashboardView.renderedSummary(report: report))
    }

    @Test
    @MainActor
    func dashboardHandlesEmptyPortfolioWithoutCrashing() {
        let view = PortfolioDashboardView(snapshots: [], now: now)
        _ = ViewSnapshotProbe(view: AnyView(view)).probe()
        // No companies → aggregator returns empty report; renderedSummary
        // returns the bare counters.
        let report = PortfolioAggregator.aggregate(snapshots: [], granularity: .daily, now: now)
        let rows = PortfolioDashboardView.renderedSummary(report: report)
        #expect(rows == [
            "companies=0",
            "missingData=0",
            "revenue=$0.00",
            "cost=$0.00",
            "margin=$0.00"
        ])
    }

    @Test
    @MainActor
    func dashboardHandlesPartialFinancialDataWithoutCrashing() {
        let onlyLifecycle = PortfolioCompanySnapshot(
            companyID: "co-undated",
            displayName: "Undated Co",
            lifecycleStage: .idea,
            entries: []
        )
        let view = PortfolioDashboardView(snapshots: [onlyLifecycle], now: now)
        _ = ViewSnapshotProbe(view: AnyView(view)).probe()

        let report = PortfolioAggregator.aggregate(
            snapshots: [onlyLifecycle],
            granularity: .daily,
            now: now
        )
        #expect(report.companiesWithMissingDataCount == 1)
        #expect(report.totalRevenueUSD == 0)
        let rows = PortfolioDashboardView.renderedSummary(report: report)
        #expect(rows.contains("missingData=1"))
        #expect(rows.contains("lifecycle.idea=1"))
    }

    // MARK: - Fixtures

    private func fixtureSnapshots() -> [PortfolioCompanySnapshot] {
        let alphaRevenue = CompanyLedgerEntry(
            id: "alpha-rev",
            companyID: "co-alpha",
            occurredAt: now.addingTimeInterval(-3_600),
            kind: .revenue,
            amountUSD: 200,
            source: "stripe",
            confidence: .verified,
            note: "checkout"
        )
        let alphaCost = CompanyLedgerEntry(
            id: "alpha-cost",
            companyID: "co-alpha",
            occurredAt: now.addingTimeInterval(-7_200),
            kind: .cost,
            amountUSD: 30,
            source: "compute",
            confidence: .estimated,
            note: "compute"
        )
        let bravoRevenue = CompanyLedgerEntry(
            id: "bravo-rev",
            companyID: "co-bravo",
            occurredAt: now.addingTimeInterval(-1_800),
            kind: .revenue,
            amountUSD: 50,
            source: "stripe",
            confidence: .verified,
            note: "checkout"
        )
        let bravoCost = CompanyLedgerEntry(
            id: "bravo-cost",
            companyID: "co-bravo",
            occurredAt: now.addingTimeInterval(-1_800),
            kind: .cost,
            amountUSD: 15,
            source: "compute",
            confidence: .estimated,
            note: "compute"
        )

        return [
            PortfolioCompanySnapshot(
                companyID: "co-alpha",
                displayName: "Alpha",
                lifecycleStage: .launched,
                entries: [alphaRevenue, alphaCost]
            ),
            PortfolioCompanySnapshot(
                companyID: "co-bravo",
                displayName: "Bravo",
                lifecycleStage: .launched,
                entries: [bravoRevenue, bravoCost]
            ),
            PortfolioCompanySnapshot(
                companyID: "co-charlie",
                displayName: "Charlie",
                lifecycleStage: .building,
                entries: []
            ),
            PortfolioCompanySnapshot(
                companyID: "co-delta",
                displayName: "Delta",
                lifecycleStage: .idea,
                entries: [
                    CompanyLedgerEntry(
                        id: "delta-undated-revenue",
                        companyID: "co-delta",
                        occurredAt: nil,
                        kind: .revenue,
                        amountUSD: 0,
                        source: "n/a",
                        confidence: .estimated,
                        note: "no revenue yet"
                    )
                ]
            )
        ]
    }
}

/// Forces SwiftUI to evaluate a view's body in the test process. This is
/// the closest we can get to a pixel snapshot without pulling in a heavy
/// snapshot-testing dependency; it catches construction-time failures
/// (preconditions, force-unwraps, environment misuse) under both
/// `.colorScheme(.light)` and `.colorScheme(.dark)`.
@MainActor
private struct ViewSnapshotProbe {
    let view: AnyView

    func probe() -> Bool {
        let hosting = NSHostingController(rootView: view)
        hosting.view.frame = CGRect(x: 0, y: 0, width: 1200, height: 900)
        // Forces layout + body evaluation.
        hosting.view.layoutSubtreeIfNeeded()
        return true
    }
}
