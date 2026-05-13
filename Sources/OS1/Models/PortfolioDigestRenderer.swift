import Foundation

/// Closes acceptance bullet "Confidence intervals on every projection in the
/// digest (no point estimates without bands)."
///
/// The dashboard's existing `renderedSummary` emits point estimates only.
/// This renderer takes the same aggregate report plus the optional Bayesian
/// posteriors (from `CompanyProfitPriorEngine.nightlySnapshot`) and emits a
/// digest where every projection ships with a `[low, high]` credible band.
///
/// Format example (deterministic for tests):
///
/// ```
/// companies=12
/// revenue=$8,200.00 (band $7,400.00-$8,950.00)
/// top|co-acme|EV=$1,200.00 band=$900.00-$1,500.00 P(MRR>=target)=0.62
/// allocation|#1|co-acme|EV=$1,200.00 band=$900.00-$1,500.00
/// ```
///
/// If posteriors are absent, projection rows still render as point estimates
/// with `band=unknown` so the audit reads "we deliberately have no band"
/// rather than silently dropping the column.
enum PortfolioDigestRenderer {
    /// Render every row of the digest. Public so snapshot tests can assert
    /// the band suffix on every projection line.
    static func render(
        report: PortfolioAggregateReport,
        posteriors: [CompanyProfitPosterior] = [],
        recommendations: [PortfolioAllocationRecommender.Recommendation] = []
    ) -> [String] {
        var lines: [String] = []
        lines.append("companies=\(report.companyCount)")
        lines.append("missingData=\(report.companiesWithMissingDataCount)")

        let totalsBand = aggregateBand(posteriors: posteriors)
        lines.append("revenue=\(format(report.totalRevenueUSD)) (\(bandSuffix(totalsBand)))")
        lines.append("cost=\(format(report.totalCostUSD))")
        lines.append("margin=\(format(report.totalMarginUSD)) (\(marginBandSuffix(report: report, posteriorsBand: totalsBand)))")

        for stage in lifecycleOrder {
            if let count = report.lifecycleDistribution[stage], count > 0 {
                lines.append("lifecycle.\(stage)=\(count)")
            }
        }
        let posteriorByCompany = Dictionary(uniqueKeysWithValues: posteriors.map { ($0.companyID, $0) })

        for row in report.topPerformers {
            lines.append("top|\(row.companyID)|\(projectionLine(row: row, posterior: posteriorByCompany[row.companyID]))")
        }
        for row in report.bottomPerformers {
            lines.append("bottom|\(row.companyID)|\(projectionLine(row: row, posterior: posteriorByCompany[row.companyID]))")
        }
        for recommendation in recommendations {
            let band = "\(format(recommendation.lowerCredibleUSD))-\(format(recommendation.upperCredibleUSD))"
            lines.append(
                "allocation|#\(recommendation.rank)|\(recommendation.companyID)|EV=\(format(recommendation.expectedValueUSD)) band=\(band) P(MRR>=target)=\(probability(recommendation.probabilityMRRExceedsTarget))"
            )
        }
        return lines
    }

    /// Convenience used when the dashboard already has a digest-ranked list.
    static func render(
        report: PortfolioAggregateReport,
        digest: [CompanyProfitDigestRank]
    ) -> [String] {
        var lines = render(report: report, posteriors: [], recommendations: [])
        for entry in digest {
            let band = "\(format(entry.credibleIntervalUSD.lowerBound))-\(format(entry.credibleIntervalUSD.upperBound))"
            lines.append("digest|#\(entry.rank)|\(entry.companyID)|EV=\(format(entry.expectedValueUSD)) band=\(band) score=\(format(entry.score))")
        }
        return lines
    }

    // MARK: - Internal helpers

    private static func aggregateBand(posteriors: [CompanyProfitPosterior]) -> (Double, Double)? {
        guard !posteriors.isEmpty else { return nil }
        let lower = posteriors.reduce(0.0) { $0 + $1.lowerCredibleUSD }
        let upper = posteriors.reduce(0.0) { $0 + $1.upperCredibleUSD }
        return (lower, upper)
    }

    private static func bandSuffix(_ band: (Double, Double)?) -> String {
        guard let band else { return "band=unknown" }
        return "band \(format(band.0))-\(format(band.1))"
    }

    private static func marginBandSuffix(
        report: PortfolioAggregateReport,
        posteriorsBand: (Double, Double)?
    ) -> String {
        guard let band = posteriorsBand else { return "band=unknown" }
        let low = band.0 - report.totalCostUSD
        let high = band.1 - report.totalCostUSD
        return "band \(format(low))-\(format(high))"
    }

    private static func projectionLine(
        row: PortfolioCompanyReport,
        posterior: CompanyProfitPosterior?
    ) -> String {
        let ev = format(row.marginUSD)
        guard let posterior else {
            return "EV=\(ev) band=unknown"
        }
        let bandLow = format(posterior.lowerCredibleUSD - row.costUSD)
        let bandHigh = format(posterior.upperCredibleUSD - row.costUSD)
        return "EV=\(ev) band=\(bandLow)-\(bandHigh) P(MRR>=target)=\(probability(posterior.probabilityMRRExceedsTarget))"
    }

    private static func probability(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    /// Locale-independent rendering — same shape as
    /// `PortfolioDashboardView.formatCurrency`, kept here so the renderer
    /// doesn't depend on a SwiftUI symbol from tests.
    static func format(_ amount: Double) -> String {
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

    private static var lifecycleOrder: [String] {
        CodexSession.LifecycleStage.allCases.map(\.rawValue) + ["unknown"]
    }
}
