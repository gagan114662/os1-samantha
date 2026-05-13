import Foundation

/// Snapshot of a single company's financial state used as input to
/// `PortfolioAggregator`. Mirrors the data already on disk (ledger.jsonl,
/// PAYMENT_PROVIDER_EVENTS.json) but normalized to USD entries so the
/// aggregator does not need to know about currency conversion.
struct PortfolioCompanySnapshot: Codable, Hashable, Identifiable {
    var id: String { companyID }

    let companyID: String
    let displayName: String
    let lifecycleStage: CodexSession.LifecycleStage?
    let templateID: String?
    /// ISO 4217 code for the company's native currency. Aggregator output
    /// is always USD; this is recorded only for provenance + display.
    let nativeCurrency: String
    /// Already-normalized entries in USD. Callers that have non-USD values
    /// are responsible for converting before constructing the snapshot.
    let entries: [CompanyLedgerEntry]
    let lastUpdatedAt: Date?

    init(
        companyID: String,
        displayName: String,
        lifecycleStage: CodexSession.LifecycleStage?,
        templateID: String? = nil,
        nativeCurrency: String = "USD",
        entries: [CompanyLedgerEntry] = [],
        lastUpdatedAt: Date? = nil
    ) {
        self.companyID = companyID
        self.displayName = displayName
        self.lifecycleStage = lifecycleStage
        self.templateID = templateID
        self.nativeCurrency = nativeCurrency
        self.entries = entries
        self.lastUpdatedAt = lastUpdatedAt
    }

    /// True when the snapshot has at least one dated revenue or cost entry
    /// the aggregator can attribute to a bucket. Used to surface a
    /// "missing financial data" partial state.
    var hasFinancialData: Bool {
        entries.contains { $0.kind != .refund && $0.occurredAt != nil }
    }
}

enum PortfolioGranularity: String, Codable, CaseIterable, Hashable {
    case daily
    case weekly
    case monthly

    var bucketSeconds: TimeInterval {
        switch self {
        case .daily: return 86_400
        case .weekly: return 86_400 * 7
        case .monthly: return 86_400 * 30
        }
    }

    /// Default number of buckets to surface for each granularity. The
    /// dashboard summary covers a "current period" plus history.
    var defaultBucketCount: Int {
        switch self {
        case .daily: return 30
        case .weekly: return 12
        case .monthly: return 6
        }
    }

    var title: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        }
    }
}

struct PortfolioBucket: Codable, Hashable, Identifiable {
    var id: String { ISO8601DateFormatter().string(from: start) }
    let start: Date
    let end: Date
    let revenueUSD: Double
    let costUSD: Double

    var marginUSD: Double { revenueUSD - costUSD }
}

struct PortfolioCompanyReport: Codable, Hashable, Identifiable {
    var id: String { companyID }
    let companyID: String
    let displayName: String
    let lifecycleStage: CodexSession.LifecycleStage?
    let templateID: String?
    let revenueUSD: Double
    let costUSD: Double
    let hasFinancialData: Bool

    var marginUSD: Double { revenueUSD - costUSD }
}

struct PortfolioAggregateReport: Codable, Hashable {
    let generatedAt: Date
    let granularity: PortfolioGranularity
    let windowStart: Date
    let windowEnd: Date
    let totalRevenueUSD: Double
    let totalCostUSD: Double
    let buckets: [PortfolioBucket]
    let companyReports: [PortfolioCompanyReport]
    let lifecycleDistribution: [String: Int]
    let topPerformers: [PortfolioCompanyReport]
    let bottomPerformers: [PortfolioCompanyReport]
    let companyCount: Int
    let companiesWithMissingDataCount: Int
    let nativeCurrencies: [String]

    var totalMarginUSD: Double { totalRevenueUSD - totalCostUSD }

    var isEmpty: Bool { companyCount == 0 }

    /// Convenience helper: encodes the report as a JSON document suitable
    /// for the operator's weekly review export.
    func jsonExport() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(self)
    }
}

/// Pure aggregation logic. No I/O, no UI, deterministic for tests.
enum PortfolioAggregator {
    static func aggregate(
        snapshots: [PortfolioCompanySnapshot],
        granularity: PortfolioGranularity,
        now: Date,
        bucketCount: Int? = nil,
        topN: Int = 5
    ) -> PortfolioAggregateReport {
        let bucketsToShow = max(1, bucketCount ?? granularity.defaultBucketCount)
        let bucketSize = granularity.bucketSeconds
        let windowEnd = now
        let windowStart = windowEnd.addingTimeInterval(-bucketSize * Double(bucketsToShow))

        var bucketRevenue = [Double](repeating: 0, count: bucketsToShow)
        var bucketCost = [Double](repeating: 0, count: bucketsToShow)

        var totalRevenue = 0.0
        var totalCost = 0.0

        var companyReports: [PortfolioCompanyReport] = []
        var lifecycle: [String: Int] = [:]
        var currencies = Set<String>()
        var missingDataCount = 0

        for snapshot in snapshots {
            currencies.insert(snapshot.nativeCurrency)
            let stageKey = snapshot.lifecycleStage?.rawValue ?? "unknown"
            lifecycle[stageKey, default: 0] += 1

            if !snapshot.hasFinancialData {
                missingDataCount += 1
            }

            var companyRevenue = 0.0
            var companyCost = 0.0

            for entry in snapshot.entries {
                let inWindow: Bool
                if let occurred = entry.occurredAt {
                    inWindow = occurred >= windowStart && occurred <= windowEnd
                } else {
                    // Undated entries count toward the company total but not
                    // toward any time-series bucket. This keeps "current
                    // period" totals stable even when sources omit timestamps.
                    inWindow = true
                }

                switch entry.kind {
                case .revenue:
                    // AC: revenue must be verified-only. Estimated /
                    // manual-without-verification entries are excluded
                    // from portfolio totals.
                    guard entry.confidence == .verified || entry.confidence == .manualOverride else {
                        continue
                    }
                    if inWindow {
                        companyRevenue += entry.amountUSD
                        totalRevenue += entry.amountUSD
                        if let bucketIndex = bucketIndex(
                            for: entry.occurredAt,
                            windowStart: windowStart,
                            bucketSize: bucketSize,
                            count: bucketsToShow
                        ) {
                            bucketRevenue[bucketIndex] += entry.amountUSD
                        }
                    }
                case .cost:
                    if inWindow {
                        companyCost += entry.amountUSD
                        totalCost += entry.amountUSD
                        if let bucketIndex = bucketIndex(
                            for: entry.occurredAt,
                            windowStart: windowStart,
                            bucketSize: bucketSize,
                            count: bucketsToShow
                        ) {
                            bucketCost[bucketIndex] += entry.amountUSD
                        }
                    }
                case .refund:
                    if inWindow {
                        // Refunds reduce revenue and never count as cost.
                        companyRevenue -= entry.amountUSD
                        totalRevenue -= entry.amountUSD
                        if let bucketIndex = bucketIndex(
                            for: entry.occurredAt,
                            windowStart: windowStart,
                            bucketSize: bucketSize,
                            count: bucketsToShow
                        ) {
                            bucketRevenue[bucketIndex] -= entry.amountUSD
                        }
                    }
                }
            }

            companyReports.append(
                PortfolioCompanyReport(
                    companyID: snapshot.companyID,
                    displayName: snapshot.displayName,
                    lifecycleStage: snapshot.lifecycleStage,
                    templateID: snapshot.templateID,
                    revenueUSD: companyRevenue,
                    costUSD: companyCost,
                    hasFinancialData: snapshot.hasFinancialData
                )
            )
        }

        let buckets = (0..<bucketsToShow).map { index -> PortfolioBucket in
            let start = windowStart.addingTimeInterval(bucketSize * Double(index))
            let end = start.addingTimeInterval(bucketSize)
            return PortfolioBucket(
                start: start,
                end: end,
                revenueUSD: roundCurrency(bucketRevenue[index]),
                costUSD: roundCurrency(bucketCost[index])
            )
        }

        let rankable = companyReports.filter(\.hasFinancialData)
        let ranked = rankable.sorted { $0.marginUSD > $1.marginUSD }
        let top = Array(ranked.prefix(topN))
        let bottom = Array(ranked.suffix(topN).reversed())

        return PortfolioAggregateReport(
            generatedAt: now,
            granularity: granularity,
            windowStart: windowStart,
            windowEnd: windowEnd,
            totalRevenueUSD: roundCurrency(totalRevenue),
            totalCostUSD: roundCurrency(totalCost),
            buckets: buckets,
            companyReports: companyReports.sorted { $0.displayName < $1.displayName },
            lifecycleDistribution: lifecycle,
            topPerformers: top,
            bottomPerformers: bottom,
            companyCount: snapshots.count,
            companiesWithMissingDataCount: missingDataCount,
            nativeCurrencies: currencies.sorted()
        )
    }

    private static func bucketIndex(
        for date: Date?,
        windowStart: Date,
        bucketSize: TimeInterval,
        count: Int
    ) -> Int? {
        guard let date else { return nil }
        let offset = date.timeIntervalSince(windowStart)
        guard offset >= 0 else { return nil }
        let raw = Int(floor(offset / bucketSize))
        guard raw >= 0 && raw < count else { return nil }
        return raw
    }

    /// Rounds to two decimal places to keep aggregate outputs deterministic
    /// in the face of floating-point accumulation.
    private static func roundCurrency(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
