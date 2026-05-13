import SwiftUI

/// Single-pane-of-glass dashboard summarizing revenue, cost, and margin
/// across every live Samantha company. Renders aggregates produced by
/// `PortfolioAggregator` and supports daily/weekly/monthly time-series.
struct PortfolioDashboardView: View {
    @Environment(\.os1Theme) private var theme

    let snapshots: [PortfolioCompanySnapshot]
    let now: Date

    @State private var granularity: PortfolioGranularity = .daily

    init(snapshots: [PortfolioCompanySnapshot], now: Date = Date()) {
        self.snapshots = snapshots
        self.now = now
    }

    var body: some View {
        HermesPageContainer(width: .dashboard) {
            VStack(alignment: .leading, spacing: 24) {
                header

                if snapshots.isEmpty {
                    emptyState
                } else {
                    let report = PortfolioAggregator.aggregate(
                        snapshots: snapshots,
                        granularity: granularity,
                        now: now
                    )
                    granularityToggle
                    summarySection(report: report)
                    if report.companiesWithMissingDataCount > 0 {
                        partialDataBanner(report: report)
                    }
                    lifecycleSection(report: report)
                    timeSeriesSection(report: report)
                    topBottomSection(report: report)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string("Portfolio"))
                .font(.os1TitleSection)
                .fontWeight(.semibold)
            Text(L10n.string("Aggregate revenue, cost, and margin across every live company."))
                .font(.os1Body)
                .foregroundStyle(.os1OnCoralSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var granularityToggle: some View {
        Picker("Granularity", selection: $granularity) {
            ForEach(PortfolioGranularity.allCases, id: \.self) { value in
                Text(value.title).tag(value)
            }
        }
        .pickerStyle(.segmented)
        .frame(maxWidth: 360)
    }

    private var emptyState: some View {
        HermesSurfacePanel {
            ContentUnavailableView(
                L10n.string("No companies yet"),
                systemImage: "tray",
                description: Text(L10n.string("Once Samantha launches its first company, its revenue, cost, and margin will roll up here."))
            )
            .frame(maxWidth: .infinity, minHeight: 240)
        }
    }

    private func partialDataBanner(report: PortfolioAggregateReport) -> some View {
        HermesSurfacePanel {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle")
                    .foregroundStyle(theme.palette.warning)
                VStack(alignment: .leading, spacing: 4) {
                    Text(L10n.string("Some companies are missing financial data"))
                        .font(.os1Body.bold())
                    Text(String(
                        format: L10n.string("%d of %d companies have no dated ledger entries; their totals are excluded from the time-series chart."),
                        report.companiesWithMissingDataCount,
                        report.companyCount
                    ))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func summarySection(report: PortfolioAggregateReport) -> some View {
        HermesSurfacePanel(title: "Current period") {
            HStack(alignment: .top, spacing: 24) {
                summaryStat(label: "Revenue", value: report.totalRevenueUSD)
                summaryStat(label: "Cost", value: report.totalCostUSD)
                summaryStat(
                    label: "Margin",
                    value: report.totalMarginUSD,
                    tint: report.totalMarginUSD >= 0 ? theme.palette.success : theme.palette.danger
                )
                summaryStat(label: "Companies", count: report.companyCount)
            }
        }
    }

    private func summaryStat(label: String, value: Double, tint: Color = .os1OnCoralPrimary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(label))
                .font(.os1SmallCaps)
                .foregroundStyle(.os1OnCoralMuted)
            Text(PortfolioDashboardView.formatCurrency(value))
                .font(.os1TitleSection)
                .foregroundStyle(tint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func summaryStat(label: String, count: Int) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(label))
                .font(.os1SmallCaps)
                .foregroundStyle(.os1OnCoralMuted)
            Text("\(count)")
                .font(.os1TitleSection)
                .foregroundStyle(.os1OnCoralPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func lifecycleSection(report: PortfolioAggregateReport) -> some View {
        HermesSurfacePanel(title: "Lifecycle distribution") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(PortfolioDashboardView.lifecycleOrder, id: \.self) { stage in
                    let count = report.lifecycleDistribution[stage] ?? 0
                    HStack {
                        Text(stage).font(.os1Body)
                        Spacer()
                        Text("\(count)").font(.os1Body.monospaced())
                    }
                    .foregroundStyle(.os1OnCoralPrimary)
                }
            }
        }
    }

    private func timeSeriesSection(report: PortfolioAggregateReport) -> some View {
        HermesSurfacePanel(title: "Time series") {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(L10n.string("Bucket")).font(.os1SmallCaps)
                    Spacer()
                    Text(L10n.string("Revenue")).font(.os1SmallCaps)
                    Text(L10n.string("Cost")).font(.os1SmallCaps).frame(width: 90, alignment: .trailing)
                    Text(L10n.string("Margin")).font(.os1SmallCaps).frame(width: 90, alignment: .trailing)
                }
                .foregroundStyle(.os1OnCoralMuted)
                ForEach(report.buckets.suffix(12)) { bucket in
                    HStack {
                        Text(PortfolioDashboardView.formatBucketLabel(bucket.start, granularity: report.granularity))
                            .font(.os1Body.monospaced())
                        Spacer()
                        Text(PortfolioDashboardView.formatCurrency(bucket.revenueUSD))
                            .font(.os1Body.monospaced())
                            .frame(width: 90, alignment: .trailing)
                        Text(PortfolioDashboardView.formatCurrency(bucket.costUSD))
                            .font(.os1Body.monospaced())
                            .frame(width: 90, alignment: .trailing)
                        Text(PortfolioDashboardView.formatCurrency(bucket.marginUSD))
                            .font(.os1Body.monospaced())
                            .foregroundStyle(bucket.marginUSD >= 0 ? theme.palette.success : theme.palette.danger)
                            .frame(width: 90, alignment: .trailing)
                    }
                }
            }
        }
    }

    private func topBottomSection(report: PortfolioAggregateReport) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HermesSurfacePanel(title: "Top performers") {
                performerList(report.topPerformers, emptyLabel: "No ranked companies yet.")
            }
            HermesSurfacePanel(title: "Bottom performers") {
                performerList(report.bottomPerformers, emptyLabel: "No ranked companies yet.")
            }
        }
    }

    private func performerList(_ rows: [PortfolioCompanyReport], emptyLabel: String) -> some View {
        Group {
            if rows.isEmpty {
                Text(L10n.string(emptyLabel))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(rows) { row in
                        HStack {
                            Text(row.displayName).font(.os1Body)
                            Spacer()
                            Text(PortfolioDashboardView.formatCurrency(row.marginUSD))
                                .font(.os1Body.monospaced())
                                .foregroundStyle(row.marginUSD >= 0 ? theme.palette.success : theme.palette.danger)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Formatting helpers (also exposed for tests)

    static let lifecycleOrder: [String] = [
        "idea", "validating", "building", "launched",
        "revenuePositive", "scaling", "paused", "killed", "pivoting", "unknown"
    ]

    static func formatCurrency(_ amount: Double) -> String {
        // Locale-independent rendering so tests and JSON exports stay
        // deterministic across operator machines and CI runners.
        let sign = amount < 0 ? "-" : ""
        let magnitude = abs(amount)
        let whole = Int(magnitude)
        let cents = Int(((magnitude - Double(whole)) * 100).rounded())
        let grouped = formatWithThousands(whole)
        return "\(sign)$\(grouped).\(String(format: "%02d", cents))"
    }

    private static func formatWithThousands(_ value: Int) -> String {
        let digits = String(value)
        guard digits.count > 3 else { return digits }
        var result: [Character] = []
        for (offset, char) in digits.reversed().enumerated() {
            if offset > 0 && offset % 3 == 0 {
                result.append(",")
            }
            result.append(char)
        }
        return String(result.reversed())
    }

    static func formatBucketLabel(_ date: Date, granularity: PortfolioGranularity) -> String {
        let formatter = DateFormatter()
        formatter.timeZone = TimeZone(identifier: "UTC")
        switch granularity {
        case .daily: formatter.dateFormat = "yyyy-MM-dd"
        case .weekly: formatter.dateFormat = "yyyy-'W'ww"
        case .monthly: formatter.dateFormat = "yyyy-MM"
        }
        return formatter.string(from: date)
    }

    /// Deterministic rendered summary used by snapshot tests. Same content
    /// for light + dark mode (semantic content is theme-independent).
    @MainActor
    static func renderedSummary(report: PortfolioAggregateReport) -> [String] {
        var lines: [String] = []
        lines.append("companies=\(report.companyCount)")
        lines.append("missingData=\(report.companiesWithMissingDataCount)")
        lines.append("revenue=\(formatCurrency(report.totalRevenueUSD))")
        lines.append("cost=\(formatCurrency(report.totalCostUSD))")
        lines.append("margin=\(formatCurrency(report.totalMarginUSD))")
        for stage in lifecycleOrder {
            if let count = report.lifecycleDistribution[stage], count > 0 {
                lines.append("lifecycle.\(stage)=\(count)")
            }
        }
        for row in report.topPerformers {
            lines.append("top|\(row.companyID)|\(formatCurrency(row.marginUSD))")
        }
        for row in report.bottomPerformers {
            lines.append("bottom|\(row.companyID)|\(formatCurrency(row.marginUSD))")
        }
        return lines
    }
}
