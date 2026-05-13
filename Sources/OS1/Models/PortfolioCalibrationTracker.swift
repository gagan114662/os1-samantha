import Foundation

/// Closes acceptance bullet "Calibration tracker: how well did last quarter's
/// posteriors predict actual outcomes?"
///
/// Snapshots the nightly Bayesian posterior at time T (via `recordSnapshot`)
/// and, at T + `horizonDays` (default 90), compares each snapshotted EV /
/// credible band against the realized revenue. Stores one JSON file per
/// snapshot at `~/.os1/portfolio-calibration/<ISO-stamp>.json`.
///
/// Persistence path is intentionally **separate** from PR #208's
/// `~/.os1/portfolio-snapshots/`:
///
/// - `portfolio-snapshots/` holds `PortfolioAggregateReport` (revenue/cost
///   rollups for the live dashboard cold-start).
/// - `portfolio-calibration/` holds `CompanyProfitNightlySnapshot` (Bayesian
///   posteriors snapshot frozen for T+90d evaluation).
///
/// The shapes are different and the lifecycle is different (aggregator
/// snapshots refresh daily, calibration snapshots are immutable once
/// recorded). Keeping them apart prevents accidental overwrites and makes
/// the audit trail easier to reason about.
struct PortfolioCalibrationTracker {
    static let directoryName = "portfolio-calibration"
    static let defaultHorizonDays: Int = 90

    var directory: URL

    static func defaultStore() -> PortfolioCalibrationTracker {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return PortfolioCalibrationTracker(
            directory: home.appendingPathComponent(".os1", isDirectory: true)
                .appendingPathComponent(Self.directoryName, isDirectory: true)
        )
    }

    /// One on-disk snapshot. The `id` is also the filename stem (UTC stamp).
    struct Snapshot: Codable, Hashable, Identifiable {
        var id: String
        var takenAt: Date
        var posteriors: [CompanyProfitPosterior]

        init(id: String? = nil, takenAt: Date, posteriors: [CompanyProfitPosterior]) {
            self.takenAt = takenAt
            self.posteriors = posteriors
            if let id {
                self.id = id
            } else {
                self.id = Self.fileStem(for: takenAt)
            }
        }

        static func fileStem(for date: Date) -> String {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: date)
            return String(
                format: "%04d-%02d-%02dT%02d-%02d-%02d",
                c.year ?? 0, c.month ?? 0, c.day ?? 0,
                c.hour ?? 0, c.minute ?? 0, c.second ?? 0
            )
        }
    }

    struct EvaluationRow: Codable, Hashable, Identifiable {
        var id: String { companyID }
        var companyID: String
        var templateID: String
        var predictedEVUSD: Double
        var predictedLowerUSD: Double
        var predictedUpperUSD: Double
        var actualRevenueUSD: Double
        var withinCredibleBand: Bool
        var absoluteErrorUSD: Double
        var relativeError: Double
    }

    struct EvaluationReport: Codable, Hashable {
        var snapshotID: String
        var snapshotTakenAt: Date
        var evaluatedAt: Date
        var horizonDays: Int
        var rows: [EvaluationRow]
        var calibrationError: Double        // mean relative error across rows
        var bandCoverage: Double            // fraction of actuals that fell inside [low, high]
    }

    @discardableResult
    func recordSnapshot(_ snapshot: Snapshot) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(snapshot.id).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(snapshot).write(to: url, options: .atomic)
        return url
    }

    func loadSnapshots() throws -> [Snapshot] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { try? decoder.decode(Snapshot.self, from: Data(contentsOf: $0)) }
            .sorted { $0.takenAt < $1.takenAt }
    }

    /// Return the snapshot eligible for evaluation at `evaluationDate`,
    /// i.e. the most recent snapshot whose `takenAt + horizonDays <=
    /// evaluationDate`. Nil if no snapshot has matured yet.
    func snapshotDue(at evaluationDate: Date, horizonDays: Int = defaultHorizonDays) throws -> Snapshot? {
        let cutoff = evaluationDate.addingTimeInterval(-Double(horizonDays) * 86_400)
        let snapshots = try loadSnapshots()
        return snapshots.last { $0.takenAt <= cutoff }
    }

    /// Pure evaluator over a snapshot and a dictionary of actual realized
    /// revenue per company. Exposed as a static so the tracker stays I/O-free
    /// and tests can drive it with synthetic fixtures.
    static func evaluate(
        snapshot: Snapshot,
        actualRevenueUSD: [String: Double],
        evaluatedAt: Date,
        horizonDays: Int = defaultHorizonDays
    ) -> EvaluationReport {
        let rows: [EvaluationRow] = snapshot.posteriors.compactMap { p in
            guard let actual = actualRevenueUSD[p.companyID] else { return nil }
            let withinBand = actual >= p.lowerCredibleUSD && actual <= p.upperCredibleUSD
            let absError = abs(p.expectedValueUSD - actual)
            let relError = absError / max(1, abs(actual))
            return EvaluationRow(
                companyID: p.companyID,
                templateID: p.templateID,
                predictedEVUSD: p.expectedValueUSD,
                predictedLowerUSD: p.lowerCredibleUSD,
                predictedUpperUSD: p.upperCredibleUSD,
                actualRevenueUSD: actual,
                withinCredibleBand: withinBand,
                absoluteErrorUSD: absError,
                relativeError: relError
            )
        }
        let sorted = rows.sorted { $0.companyID < $1.companyID }
        let meanError = sorted.isEmpty
            ? 0
            : sorted.map(\.relativeError).reduce(0, +) / Double(sorted.count)
        let coverage = sorted.isEmpty
            ? 0
            : Double(sorted.filter(\.withinCredibleBand).count) / Double(sorted.count)
        return EvaluationReport(
            snapshotID: snapshot.id,
            snapshotTakenAt: snapshot.takenAt,
            evaluatedAt: evaluatedAt,
            horizonDays: horizonDays,
            rows: sorted,
            calibrationError: meanError,
            bandCoverage: coverage
        )
    }
}
