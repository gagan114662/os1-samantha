import Foundation

struct CompanyLedgerEntry: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case revenue
        case cost
    }

    enum Confidence: String, Codable, Hashable {
        case verified
        case manual
        case estimated
    }

    let id: String
    let companyID: String?
    let occurredAt: Date?
    let kind: Kind
    let amountUSD: Double
    let source: String
    let confidence: Confidence
    let note: String
}

struct CompanyLedgerSummary: Codable, Hashable {
    let entries: [CompanyLedgerEntry]

    var revenueUSD: Double {
        entries.filter { $0.kind == .revenue }.reduce(0) { $0 + $1.amountUSD }
    }

    var costUSD: Double {
        entries.filter { $0.kind == .cost }.reduce(0) { $0 + $1.amountUSD }
    }

    var netUSD: Double {
        revenueUSD - costUSD
    }

    var verifiedRevenueUSD: Double {
        entries
            .filter { $0.kind == .revenue && $0.confidence == .verified }
            .reduce(0) { $0 + $1.amountUSD }
    }

    var hasVerifiedRevenue: Bool {
        verifiedRevenueUSD > 0
    }

    static let empty = CompanyLedgerSummary(entries: [])
}

enum CompanyLedgerParser {
    static func summarize(revenueMarkdown: String, ledgerJSON: String = "") -> CompanyLedgerSummary {
        let jsonEntries = decodeJSONEntries(ledgerJSON)
        let markdownEntries = parseMarkdown(revenueMarkdown)
        return CompanyLedgerSummary(entries: jsonEntries + markdownEntries)
    }

    private static func decodeJSONEntries(_ raw: String) -> [CompanyLedgerEntry] {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        return (try? JSONDecoder().decode([CompanyLedgerEntry].self, from: data)) ?? []
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

        let kind: CompanyLedgerEntry.Kind = lower.contains("cost") ||
            lower.contains("spend") ||
            lower.contains("spent") ||
            lower.contains("expense") ||
            lower.contains("refund") ||
            lower.contains("fee") ||
            lower.contains("cloud") ||
            lower.contains("token") ||
            lower.contains("api") ||
            lower.contains("ad ")
            ? .cost
            : .revenue

        let confidence: CompanyLedgerEntry.Confidence
        if lower.contains("estimated") || lower.contains("projection") || lower.contains("forecast") {
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
            amountUSD: amount,
            source: confidence == .verified ? "verified-markdown" : "markdown",
            confidence: confidence,
            note: line
        )
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
