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

    /// Build a snapshot from verified-by-construction `CompanyPaymentProviderEvent`
    /// records (Stripe webhooks, etc.) plus any pre-existing ledger entries.
    /// Payment events are converted to ledger entries with
    /// `confidence = .verified` — the aggregator's revenue filter then admits
    /// them while continuing to exclude estimated / unverified manual entries.
    /// This is the wiring path acceptance bullet 2 requires:
    /// "Revenue is sourced from verified `CompanyPaymentProviderEvent` records
    /// only — no estimated/projected revenue counted."
    static func from(
        companyID: String,
        displayName: String,
        lifecycleStage: CodexSession.LifecycleStage?,
        templateID: String? = nil,
        nativeCurrency: String = "USD",
        paymentEvents: [CompanyPaymentProviderEvent],
        ledgerEntries: [CompanyLedgerEntry] = [],
        lastUpdatedAt: Date? = nil
    ) -> PortfolioCompanySnapshot {
        let converted = paymentEvents.map(Self.ledgerEntry(from:))
        return PortfolioCompanySnapshot(
            companyID: companyID,
            displayName: displayName,
            lifecycleStage: lifecycleStage,
            templateID: templateID,
            nativeCurrency: nativeCurrency,
            entries: converted + ledgerEntries,
            lastUpdatedAt: lastUpdatedAt
        )
    }

    /// Map a provider event to a ledger entry. Provider events are
    /// inherently verified (the webhook carries the signed proof), so the
    /// confidence is hard-coded to `.verified`. `charge` and `payout` become
    /// revenue; `refund` is mirrored; `fee` / `tax` / `transfer` are costs.
    static func ledgerEntry(from event: CompanyPaymentProviderEvent) -> CompanyLedgerEntry {
        let kind: CompanyLedgerEntry.Kind
        let category: CompanyLedgerEntry.Category
        switch event.kind {
        case .charge, .payout:
            kind = .revenue
            category = .sales
        case .refund:
            kind = .refund
            category = .refund
        case .fee:
            kind = .cost
            category = .paymentFees
        case .tax, .transfer:
            kind = .cost
            category = .other
        }
        return CompanyLedgerEntry(
            id: "payment-\(event.id)",
            companyID: event.companyID,
            occurredAt: event.occurredAt,
            kind: kind,
            category: category,
            amountUSD: event.amountUSD,
            source: event.provider,
            sourceReference: event.sourceReference,
            confidence: .verified,
            note: "Provider event \(event.id)"
        )
    }
}

enum PortfolioGranularity: String, Codable, CaseIterable, Hashable {
    case daily
    case weekly
    case monthly

    /// Fixed-width granularities (daily, weekly) use this to size their
    /// buckets. Monthly is calendar-driven and ignores this value; see
    /// `PortfolioAggregator.bucketRanges`.
    var bucketSeconds: TimeInterval? {
        switch self {
        case .daily: return 86_400
        case .weekly: return 86_400 * 7
        case .monthly: return nil
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

/// Why the aggregator most recently re-ran. Surfaced in the report so the
/// dashboard can show provenance ("Last recomputed: heartbeat tick at …")
/// and so we can prove via tests that recompute is bound to heartbeats, not
/// to view-appear (acceptance bullet 4).
enum PortfolioRecomputeTrigger: String, Codable, Hashable, CaseIterable {
    case heartbeat
    case manual
    case scheduled
    case initialLoad
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
    let recomputeTrigger: PortfolioRecomputeTrigger

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
        topN: Int = 5,
        trigger: PortfolioRecomputeTrigger = .initialLoad
    ) -> PortfolioAggregateReport {
        let bucketsToShow = max(1, bucketCount ?? granularity.defaultBucketCount)
        let ranges = bucketRanges(
            granularity: granularity,
            now: now,
            bucketCount: bucketsToShow
        )
        // Window spans the earliest bucket start through the latest bucket
        // end. For monthly granularity that means it extends to the start
        // of the month after `now`, so end-of-month entries don't drop.
        let windowStart = ranges.first?.start ?? now
        let windowEnd = ranges.last?.end ?? now

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
                    inWindow = occurred >= windowStart && occurred < windowEnd
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
                        if let bucketIndex = bucketIndex(for: entry.occurredAt, ranges: ranges) {
                            bucketRevenue[bucketIndex] += entry.amountUSD
                        }
                    }
                case .cost:
                    if inWindow {
                        companyCost += entry.amountUSD
                        totalCost += entry.amountUSD
                        if let bucketIndex = bucketIndex(for: entry.occurredAt, ranges: ranges) {
                            bucketCost[bucketIndex] += entry.amountUSD
                        }
                    }
                case .refund:
                    if inWindow {
                        // Refunds reduce revenue and never count as cost.
                        companyRevenue -= entry.amountUSD
                        totalRevenue -= entry.amountUSD
                        if let bucketIndex = bucketIndex(for: entry.occurredAt, ranges: ranges) {
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

        let buckets = ranges.enumerated().map { index, range -> PortfolioBucket in
            PortfolioBucket(
                start: range.start,
                end: range.end,
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
            nativeCurrencies: currencies.sorted(),
            recomputeTrigger: trigger
        )
    }

    // MARK: - Doctor portfolio-p&l row (AC9)

    /// Health verdict for the Doctor `portfolio-p&l` row. The acceptance rule
    /// is "turns red if aggregate cost-rate exceeds aggregate revenue-rate for
    /// more than 7 days." We compute it from the daily-granularity report:
    /// take the trailing 7 daily buckets and check whether cost > revenue in
    /// every one. Fewer than 7 dated buckets → unknown (we don't have the data
    /// to make the call yet).
    enum PortfolioPnLVerdict: Equatable {
        case healthy(consecutiveCostHeavyDays: Int)
        case degraded(consecutiveCostHeavyDays: Int)
        case red(consecutiveCostHeavyDays: Int)
        case insufficientData
    }

    static func portfolioPnLVerdict(
        report: PortfolioAggregateReport,
        thresholdDays: Int = 7
    ) -> PortfolioPnLVerdict {
        guard report.granularity == .daily else {
            // Doctor row is defined on daily buckets — coarser granularities
            // can't answer the 7-day question deterministically.
            return .insufficientData
        }
        guard report.buckets.count >= thresholdDays else {
            return .insufficientData
        }
        let trailing = Array(report.buckets.suffix(thresholdDays))
        let costHeavy = trailing.allSatisfy { $0.costUSD > $0.revenueUSD }
        let streak = trailing.reversed().prefix(while: { $0.costUSD > $0.revenueUSD }).count
        if costHeavy {
            return .red(consecutiveCostHeavyDays: streak)
        }
        if streak >= thresholdDays / 2 {
            return .degraded(consecutiveCostHeavyDays: streak)
        }
        return .healthy(consecutiveCostHeavyDays: streak)
    }

    /// Returns the inclusive-start / exclusive-end ranges that buckets cover
    /// for a given granularity. Daily / weekly use a fixed `TimeInterval`;
    /// monthly is calendar-driven so months with 28–31 days don't silently
    /// misattribute transactions near month boundaries.
    static func bucketRanges(
        granularity: PortfolioGranularity,
        now: Date,
        bucketCount: Int
    ) -> [(start: Date, end: Date)] {
        switch granularity {
        case .daily, .weekly:
            guard let size = granularity.bucketSeconds else { return [] }
            let windowStart = now.addingTimeInterval(-size * Double(bucketCount))
            return (0..<bucketCount).map { index in
                let start = windowStart.addingTimeInterval(size * Double(index))
                return (start, start.addingTimeInterval(size))
            }
        case .monthly:
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
            let currentMonthStart = calendar.dateInterval(of: .month, for: now)?.start ?? now
            // Build `bucketCount` calendar-month ranges ending with the month
            // that contains `now`. Each range is [first-of-month,
            // first-of-next-month), so 28/29/30/31-day months get their
            // entries attributed correctly.
            var ranges: [(Date, Date)] = []
            var monthStart = currentMonthStart
            for _ in 0..<bucketCount {
                let nextMonth = calendar.date(byAdding: .month, value: 1, to: monthStart) ?? monthStart
                ranges.append((monthStart, nextMonth))
                guard let earlier = calendar.date(byAdding: .month, value: -1, to: monthStart) else { break }
                monthStart = earlier
            }
            return ranges.reversed()
        }
    }

    private static func bucketIndex(
        for date: Date?,
        ranges: [(start: Date, end: Date)]
    ) -> Int? {
        guard let date else { return nil }
        return ranges.firstIndex { date >= $0.start && date < $0.end }
    }

    /// Rounds to two decimal places to keep aggregate outputs deterministic
    /// in the face of floating-point accumulation.
    private static func roundCurrency(_ value: Double) -> Double {
        (value * 100).rounded() / 100
    }
}
