import Foundation

/// File-backed history of `PortfolioAggregateReport` instances.
///
/// Acceptance bullet 7 — "template scoreboard refreshes nightly (or on-demand)
/// and persists historical snapshots." Snapshots live as one JSON file per UTC
/// calendar day at `~/.os1/portfolio-snapshots/<YYYY-MM-DD>.json`. A second
/// load of the dashboard reads the most-recent snapshot via `loadLatest()`
/// before recomputing, so the dashboard never starts from a blank state on a
/// cold start.
struct PortfolioSnapshotStore {
    static let directoryName = "portfolio-snapshots"

    var directory: URL

    /// Default location: `~/.os1/portfolio-snapshots/`.
    static func defaultStore() -> PortfolioSnapshotStore {
        let home = FileManager.default.homeDirectoryForCurrentUser
        return PortfolioSnapshotStore(
            directory: home.appendingPathComponent(".os1", isDirectory: true)
                .appendingPathComponent(Self.directoryName, isDirectory: true)
        )
    }

    @discardableResult
    func save(_ report: PortfolioAggregateReport) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = Self.fileName(for: report.generatedAt)
        let url = directory.appendingPathComponent(filename)
        let data = try report.jsonExport()
        try data.write(to: url, options: .atomic)
        return url
    }

    func loadLatest() throws -> PortfolioAggregateReport? {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return nil }
        let sorted = urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent > $1.lastPathComponent }
        for url in sorted {
            if let data = try? Data(contentsOf: url),
               let report = try? Self.decoder.decode(PortfolioAggregateReport.self, from: data) {
                return report
            }
        }
        return nil
    }

    /// Returns `[oldest … newest]` so callers can plot trends without
    /// resorting again.
    func loadHistory(limit: Int = 30) throws -> [PortfolioAggregateReport] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else { return [] }
        let sorted = urls
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
            .suffix(limit)
        return sorted.compactMap { url in
            guard let data = try? Data(contentsOf: url) else { return nil }
            return try? Self.decoder.decode(PortfolioAggregateReport.self, from: data)
        }
    }

    static func fileName(for date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d.json",
            components.year ?? 1970,
            components.month ?? 1,
            components.day ?? 1
        )
    }

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}

/// Binds aggregator recompute to the heartbeat event stream so the dashboard
/// reflects the latest reality without operator action.
///
/// Acceptance bullet 4 — "Margin is computed deterministically and recomputed
/// on every heartbeat tick." The scheduler does not own the recompute logic
/// (that's `PortfolioAggregator.aggregate`); it owns the **trigger contract**:
/// every heartbeat event flips `lastTrigger == .heartbeat` and increments
/// `triggerCount`, invoking the injected `onRecompute` closure with the
/// trigger reason. The closure is what re-runs the aggregator; the scheduler
/// just guarantees it runs.
final class PortfolioRecomputeScheduler {
    private(set) var triggerCount: Int = 0
    private(set) var lastTrigger: PortfolioRecomputeTrigger?
    private(set) var lastTriggerAt: Date?

    private let onRecompute: (PortfolioRecomputeTrigger, Date) -> Void

    init(onRecompute: @escaping (PortfolioRecomputeTrigger, Date) -> Void) {
        self.onRecompute = onRecompute
    }

    /// Drop in a stream of `CompanyEvent`s. Heartbeat-started and
    /// heartbeat-finished events fire a recompute; everything else is ignored.
    func observe(events: [CompanyEvent], now: Date = Date()) {
        for event in events where Self.isHeartbeatTick(event) {
            fire(trigger: .heartbeat, at: now)
        }
    }

    /// Manual recompute (operator pressed Refresh). Always fires.
    func observeManualRefresh(now: Date = Date()) {
        fire(trigger: .manual, at: now)
    }

    /// Scheduled recompute (the nightly cron / Doctor sweep). Always fires.
    func observeScheduledTick(now: Date = Date()) {
        fire(trigger: .scheduled, at: now)
    }

    static func isHeartbeatTick(_ event: CompanyEvent) -> Bool {
        event.kind == .heartbeatStarted || event.kind == .heartbeatFinished
    }

    private func fire(trigger: PortfolioRecomputeTrigger, at date: Date) {
        triggerCount += 1
        lastTrigger = trigger
        lastTriggerAt = date
        onRecompute(trigger, date)
    }
}
