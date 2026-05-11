import Foundation

struct CompanyLedgerEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case revenue
        case cost
        case refund
    }

    enum Category: String, Codable, Hashable {
        case sales
        case refund
        case subscription
        case ads
        case tools
        case cloudCompute
        case tokenUsage
        case manualLabor
        case paymentFees
        case purchases
        case other
    }

    enum Confidence: String, Codable, Hashable {
        case verified
        case manual
        case estimated
        case manualOverride
    }

    let id: String
    let companyID: String?
    let occurredAt: Date?
    let kind: Kind
    var category: Category? = nil
    let amountUSD: Double
    let source: String
    var sourceEventID: UUID? = nil
    var sourceReference: String? = nil
    let confidence: Confidence
    let note: String

    var isTraceable: Bool {
        sourceEventID != nil ||
        sourceReference?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ||
        note.lowercased().contains("id=") ||
        note.lowercased().contains("receipt=") ||
        note.lowercased().contains("invoice=") ||
        note.lowercased().contains("checkout")
    }
}

struct CompanyLedgerSummary: Codable, Hashable {
    let entries: [CompanyLedgerEntry]

    var revenueUSD: Double {
        entries.filter { $0.kind == .revenue }.reduce(0) { $0 + $1.amountUSD }
    }

    var refundUSD: Double {
        entries.filter { $0.kind == .refund }.reduce(0) { $0 + $1.amountUSD }
    }

    var netRevenueUSD: Double {
        revenueUSD - refundUSD
    }

    var costUSD: Double {
        entries.filter { $0.kind == .cost }.reduce(0) { $0 + $1.amountUSD }
    }

    var netUSD: Double {
        netRevenueUSD - costUSD
    }

    var verifiedRevenueUSD: Double {
        entries
            .filter { $0.kind == .revenue && $0.confidence == .verified }
            .reduce(0) { $0 + $1.amountUSD }
    }

    var hasVerifiedRevenue: Bool {
        verifiedRevenueUSD > 0
    }

    var hasManualProfitOverride: Bool {
        entries.contains { $0.kind == .revenue && $0.confidence == .manualOverride && $0.amountUSD > 0 }
    }

    var canMarkProfitable: Bool {
        netUSD > 0 && (hasVerifiedRevenue || hasManualProfitOverride)
    }

    var contributionMargin: Double? {
        guard netRevenueUSD > 0 else { return nil }
        return netUSD / netRevenueUSD
    }

    var roi: Double? {
        guard costUSD > 0 else { return nil }
        return netUSD / costUSD
    }

    var paybackPeriodDays: Double? {
        guard netUSD > 0,
              let firstCost = datedEntries(kind: .cost).first?.occurredAt,
              let firstRevenue = datedEntries(kind: .revenue)
                .first(where: { $0.confidence == .verified || $0.confidence == .manualOverride })?.occurredAt
        else { return nil }
        return max(0, firstRevenue.timeIntervalSince(firstCost) / 86_400)
    }

    var runwayDays: Double? {
        let costs = datedEntries(kind: .cost)
        guard netUSD > 0, costs.count >= 2,
              let first = costs.first?.occurredAt,
              let last = costs.last?.occurredAt
        else { return nil }
        let days = max(1, last.timeIntervalSince(first) / 86_400)
        let dailyBurn = costUSD / days
        guard dailyBurn > 0 else { return nil }
        return netUSD / dailyBurn
    }

    var tracedEntryCount: Int {
        entries.filter(\.isTraceable).count
    }

    var untracedEntries: [CompanyLedgerEntry] {
        entries.filter { !$0.isTraceable }
    }

    var estimatedEntryCount: Int {
        entries.filter { $0.confidence == .estimated }.count
    }

    var verifiedEntryCount: Int {
        entries.filter { $0.confidence == .verified }.count
    }

    static let empty = CompanyLedgerSummary(entries: [])

    private func datedEntries(kind: CompanyLedgerEntry.Kind) -> [CompanyLedgerEntry] {
        entries
            .filter { $0.kind == kind && $0.occurredAt != nil }
            .sorted { ($0.occurredAt ?? .distantPast) < ($1.occurredAt ?? .distantPast) }
    }
}

struct CompanyProfitabilityPolicy: Codable, Hashable {
    var maxNetLossUSD: Double
    var minimumContributionMargin: Double
    var minimumVerifiedRevenueBeforeProfit: Double

    static let productionDefault = CompanyProfitabilityPolicy(
        maxNetLossUSD: 50,
        minimumContributionMargin: 0,
        minimumVerifiedRevenueBeforeProfit: 1
    )
}

struct CompanyProfitabilityDecision: Codable, Hashable {
    var shouldPause: Bool
    var canMarkProfitable: Bool
    var reasons: [String]
}

enum CompanyProfitabilityGuard {
    static func evaluate(
        summary: CompanyLedgerSummary,
        policy: CompanyProfitabilityPolicy = .productionDefault
    ) -> CompanyProfitabilityDecision {
        var reasons: [String] = []

        if summary.netUSD < -abs(policy.maxNetLossUSD) {
            reasons.append("netLoss")
        }
        if summary.verifiedRevenueUSD > 0,
           let margin = summary.contributionMargin,
           margin < policy.minimumContributionMargin {
            reasons.append("contributionMargin")
        }
        if summary.netUSD > 0,
           !summary.hasManualProfitOverride,
           summary.verifiedRevenueUSD < policy.minimumVerifiedRevenueBeforeProfit {
            reasons.append("unverifiedProfit")
        }

        return CompanyProfitabilityDecision(
            shouldPause: reasons.contains("netLoss") || reasons.contains("contributionMargin"),
            canMarkProfitable: summary.canMarkProfitable,
            reasons: reasons
        )
    }
}

enum CompanyLedgerParser {
    static func summarize(revenueMarkdown: String, ledgerJSON: String = "") -> CompanyLedgerSummary {
        let jsonEntries = decodeJSONEntries(ledgerJSON)
        let markdownEntries = parseMarkdown(revenueMarkdown)
        return CompanyLedgerSummary(entries: jsonEntries + markdownEntries)
    }

    static func decodeJSONEntries(_ raw: String) -> [CompanyLedgerEntry] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        let defaultDecoder = JSONDecoder()
        if let entries = try? defaultDecoder.decode([CompanyLedgerEntry].self, from: data) {
            return entries
        }
        let isoDecoder = JSONDecoder()
        isoDecoder.dateDecodingStrategy = .iso8601
        return (try? isoDecoder.decode([CompanyLedgerEntry].self, from: data)) ?? []
    }

    private static func parseMarkdown(_ raw: String) -> [CompanyLedgerEntry] {
        raw.components(separatedBy: .newlines).compactMap { parseLine($0) }
    }

    private static func parseLine(_ rawLine: String) -> CompanyLedgerEntry? {
        let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
        let lower = line.lowercased()
        guard !line.isEmpty,
              !lower.contains("no revenue"),
              !lower.contains("unmeasured"),
              !lower.contains("possible ") else {
            return nil
        }

        guard let amount = firstDollarAmount(in: line), amount > 0 else { return nil }

        let kind: CompanyLedgerEntry.Kind = lower.contains("refund")
            ? .refund
            : lower.contains("cost") ||
                lower.contains("spend") ||
                lower.contains("spent") ||
                lower.contains("expense") ||
                lower.contains("fee") ||
                lower.contains("cloud") ||
                lower.contains("token") ||
                lower.contains("api") ||
                lower.contains("ad ")
                ? .cost
                : .revenue

        let confidence: CompanyLedgerEntry.Confidence
        if lower.contains("manual override") || lower.contains("founder override") {
            confidence = .manualOverride
        } else if lower.contains("estimated") || lower.contains("projection") || lower.contains("forecast") {
            confidence = .estimated
        } else if lower.contains("manual") {
            confidence = .manual
        } else if lower.contains("verified") ||
                    lower.contains("stripe") ||
                    lower.contains("payout") ||
                    lower.contains("checkout") ||
                    lower.contains("transaction") ||
                    lower.contains("receipt") ||
                    lower.contains(" id=") {
            confidence = .verified
        } else {
            confidence = .manual
        }

        return CompanyLedgerEntry(
            id: stableID(for: line),
            companyID: nil,
            occurredAt: nil,
            kind: kind,
            category: category(for: lower, kind: kind),
            amountUSD: amount,
            source: confidence == .verified ? "verified-markdown" : "markdown",
            sourceReference: sourceReference(in: line),
            confidence: confidence,
            note: line
        )
    }

    private static func category(for lower: String, kind: CompanyLedgerEntry.Kind) -> CompanyLedgerEntry.Category {
        if kind == .refund { return .refund }
        if lower.contains("subscription") { return .subscription }
        if lower.contains(" ad ") || lower.contains("ads") || lower.contains("advertis") { return .ads }
        if lower.contains("tool") || lower.contains("software") || lower.contains("api") { return .tools }
        if lower.contains("cloud") || lower.contains("orgo") || lower.contains("vm") || lower.contains("compute") { return .cloudCompute }
        if lower.contains("token") || lower.contains("codex") || lower.contains("claude") || lower.contains("openai") { return .tokenUsage }
        if lower.contains("labor") || lower.contains("contractor") || lower.contains("manual work") { return .manualLabor }
        if lower.contains("fee") || lower.contains("stripe") || lower.contains("paypal") { return .paymentFees }
        if lower.contains("purchase") || lower.contains("bought") || lower.contains("domain") { return .purchases }
        if kind == .revenue { return .sales }
        return .other
    }

    private static func sourceReference(in line: String) -> String? {
        let lower = line.lowercased()
        let markers = ["id=", "receipt=", "invoice=", "checkout="]
        guard let marker = markers.first(where: { lower.contains($0) }),
              let range = lower.range(of: marker)
        else { return nil }
        let suffix = line[range.lowerBound...]
        return String(suffix.split(separator: " ").first ?? "")
    }

    private static func firstDollarAmount(in line: String) -> Double? {
        for part in line.components(separatedBy: "$").dropFirst() {
            let amountPrefix = part.prefix { char in
                char.isNumber || char == "." || char == ","
            }
            let normalized = String(amountPrefix).replacingOccurrences(of: ",", with: "")
            if let value = Double(normalized) {
                return value
            }
        }
        return nil
    }

    private static func stableID(for line: String) -> String {
        String(line.unicodeScalars.reduce(UInt64(14_695_981_039_346_656_037)) { hash, scalar in
            (hash ^ UInt64(scalar.value)) &* 1_099_511_628_211
        }, radix: 16)
    }
}
