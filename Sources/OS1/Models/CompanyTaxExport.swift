import Foundation
import CryptoKit

// MARK: - Input types

/// A normalized ledger row consumed by `TaxExportPipeline`. Decoupled from
/// `CompanyLedgerEntry` so the pipeline can ingest from any source (in-app
/// ledger, CSV import, JSON dump) and reason about multi-currency / multi-
/// jurisdiction allocation uniformly.
struct TaxLedgerLine: Codable, Hashable, Identifiable {
    let id: String
    let entityID: String
    let occurredAt: Date
    let kind: CompanyLedgerEntry.Kind
    let category: CompanyLedgerEntry.Category?
    let amount: Double
    let currency: String
    /// Optional jurisdiction code (e.g. "US-CA"). If set, this line is pinned
    /// to that jurisdiction. If nil, the entity's allocation rule applies.
    let jurisdiction: String?
    let counterparty: String?
    let memo: String

    init(
        id: String,
        entityID: String,
        occurredAt: Date,
        kind: CompanyLedgerEntry.Kind,
        category: CompanyLedgerEntry.Category? = nil,
        amount: Double,
        currency: String = "USD",
        jurisdiction: String? = nil,
        counterparty: String? = nil,
        memo: String = ""
    ) {
        self.id = id
        self.entityID = entityID
        self.occurredAt = occurredAt
        self.kind = kind
        self.category = category
        self.amount = amount
        self.currency = currency
        self.jurisdiction = jurisdiction
        self.counterparty = counterparty
        self.memo = memo
    }
}

extension TaxLedgerLine {
    /// Convert a `CompanyLedgerEntry` into a `TaxLedgerLine`. The entry's
    /// `companyID` is resolved against `TaxEntityRegistry`; entries with no
    /// mapped entity are dropped (surfaced separately by the Doctor row).
    static func from(
        entry: CompanyLedgerEntry,
        registry: TaxEntityRegistry,
        currency: String = "USD",
        jurisdiction: String? = nil
    ) -> TaxLedgerLine? {
        guard let entity = registry.entity(forCompany: entry.companyID) else { return nil }
        return TaxLedgerLine(
            id: entry.id,
            entityID: entity.id,
            occurredAt: entry.occurredAt ?? Date(timeIntervalSince1970: 0),
            kind: entry.kind,
            category: entry.category,
            amount: entry.amountUSD,
            currency: currency,
            jurisdiction: jurisdiction,
            counterparty: nil,
            memo: entry.note
        )
    }
}

/// Frozen FX-rate fixture. `rates[currency]` is the USD-per-unit conversion
/// rate. `USD` always maps to `1.0` regardless of the table contents.
struct TaxFXRateTable: Codable, Hashable {
    var asOf: Date
    var rates: [String: Double]

    init(asOf: Date, rates: [String: Double]) {
        self.asOf = asOf
        var normalized = rates
        normalized["USD"] = 1.0
        self.rates = normalized
    }

    func toUSD(amount: Double, currency: String) throws -> Double {
        guard let rate = rates[currency] else {
            throw TaxExportError.missingFXRate(currency: currency)
        }
        return amount * rate
    }
}

enum TaxExportError: Error, CustomStringConvertible {
    case missingFXRate(currency: String)
    case unknownEntity(id: String)
    case invalidTaxYear(year: Int)

    var description: String {
        switch self {
        case let .missingFXRate(currency):
            return "Missing FX rate for currency \(currency)"
        case let .unknownEntity(id):
            return "Unknown entity id \(id)"
        case let .invalidTaxYear(year):
            return "Invalid tax year \(year)"
        }
    }
}

// MARK: - Request / Output

struct TaxExportRequest {
    let entity: TaxEntity
    let taxYear: Int
    let ledgerLines: [TaxLedgerLine]
    let providerEvents: [CompanyPaymentProviderEvent]
    let contractorPayments: [TaxContractorPayment]
    let fxRates: TaxFXRateTable
    let sourceLedgerCommitHash: String
    let exportTimestamp: Date
    /// If empty, defaults to `entity.allJurisdictions`.
    let jurisdictionsOverride: [String]

    init(
        entity: TaxEntity,
        taxYear: Int,
        ledgerLines: [TaxLedgerLine],
        providerEvents: [CompanyPaymentProviderEvent] = [],
        contractorPayments: [TaxContractorPayment] = [],
        fxRates: TaxFXRateTable,
        sourceLedgerCommitHash: String,
        exportTimestamp: Date,
        jurisdictionsOverride: [String] = []
    ) {
        self.entity = entity
        self.taxYear = taxYear
        self.ledgerLines = ledgerLines
        self.providerEvents = providerEvents
        self.contractorPayments = contractorPayments
        self.fxRates = fxRates
        self.sourceLedgerCommitHash = sourceLedgerCommitHash
        self.exportTimestamp = exportTimestamp
        self.jurisdictionsOverride = jurisdictionsOverride
    }
}

struct TaxContractorPayment: Codable, Hashable, Identifiable {
    let id: String
    let payerEntityID: String
    let recipientName: String
    let recipientTaxID: String?
    let recipientCountry: String
    let amountUSD: Double
    let isUSResident: Bool
}

struct TaxExportFile: Hashable {
    let path: String
    let bytes: Data
    let sha256Hex: String

    init(path: String, bytes: Data) {
        self.path = path
        self.bytes = bytes
        self.sha256Hex = TaxExportPipeline.sha256Hex(bytes)
    }

    var stringContent: String {
        String(data: bytes, encoding: .utf8) ?? ""
    }
}

struct TaxExportManifest: Codable, Hashable {
    let entityID: String
    let entityLegalName: String
    let taxYear: Int
    let jurisdiction: String
    let sourceLedgerCommitHash: String
    let exportedAt: Date
    let totalsChecksum: String
    let files: [Entry]
    let totals: Totals
    let notes: [String]

    struct Entry: Codable, Hashable {
        let path: String
        let sha256: String
        let byteCount: Int
    }

    struct Totals: Codable, Hashable {
        let revenueUSD: Double
        let refundsUSD: Double
        let costUSD: Double
        let netUSD: Double
        let lineCount: Int
    }
}

struct TaxExportBundle {
    let entityID: String
    let jurisdiction: String
    let taxYear: Int
    let manifest: TaxExportManifest
    let files: [TaxExportFile]
}

// MARK: - IRS Schedule C / 1120 line items

enum IRSLineItem: String, Codable, Hashable, CaseIterable {
    case grossReceipts                       // Schedule C line 1 / 1120 line 1a
    case returnsAndAllowances                // Schedule C line 2 / 1120 line 1b
    case advertising                         // Schedule C line 8 / 1120 line 22
    case commissionsAndFees                  // Schedule C line 10
    case contractLabor                       // Schedule C line 11
    case officeExpense                       // Schedule C line 18
    case supplies                            // Schedule C line 22
    case utilities                           // Schedule C line 25
    case otherExpenses                       // Schedule C line 27a
    case taxesAndLicenses                    // Schedule C line 23
    case unclassified

    static func classify(_ category: CompanyLedgerEntry.Category?, kind: CompanyLedgerEntry.Kind) -> IRSLineItem {
        switch kind {
        case .revenue:
            return .grossReceipts
        case .refund:
            return .returnsAndAllowances
        case .cost:
            break
        }
        switch category {
        case .ads:           return .advertising
        case .paymentFees:   return .commissionsAndFees
        case .manualLabor:   return .contractLabor
        case .tools:         return .officeExpense
        case .purchases:     return .supplies
        case .cloudCompute:  return .utilities
        case .tokenUsage:    return .otherExpenses
        case .subscription:  return .otherExpenses
        case .sales, .refund, .other, .none:
            return .unclassified
        }
    }

    var displayName: String {
        switch self {
        case .grossReceipts:        return "Gross receipts or sales"
        case .returnsAndAllowances: return "Returns and allowances"
        case .advertising:          return "Advertising"
        case .commissionsAndFees:   return "Commissions and fees"
        case .contractLabor:        return "Contract labor"
        case .officeExpense:        return "Office expense"
        case .supplies:             return "Supplies"
        case .utilities:            return "Utilities (hosting/compute)"
        case .otherExpenses:        return "Other expenses"
        case .taxesAndLicenses:     return "Taxes and licenses"
        case .unclassified:         return "Unclassified"
        }
    }
}

// MARK: - Pipeline

/// Filing-ready export per (entity × jurisdiction) pair.
///
/// Deterministic by construction: stable sort on all inputs, fixed-precision
/// money formatting (`%.2f`), ISO8601 timestamps without fractional seconds,
/// sorted-keys JSON. Same inputs (including `exportTimestamp`) yield
/// byte-identical bytes — diffable across reruns.
enum TaxExportPipeline {
    static func generate(_ request: TaxExportRequest) throws -> [TaxExportBundle] {
        let jurisdictions = request.jurisdictionsOverride.isEmpty
            ? request.entity.allJurisdictions
            : Array(Set(request.jurisdictionsOverride)).sorted()

        guard jurisdictions.isEmpty == false else { return [] }

        let normalized = try normalize(lines: request.ledgerLines, fxRates: request.fxRates)
        let filtered = filterToEntityAndYear(normalized, entity: request.entity, taxYear: request.taxYear)

        let allocations = allocate(lines: filtered, entity: request.entity, jurisdictions: jurisdictions)
        let activeDays = activeDayFraction(entity: request.entity, taxYear: request.taxYear)

        var bundles: [TaxExportBundle] = []
        for jurisdiction in jurisdictions {
            let lines = allocations[jurisdiction] ?? []
            let bundle = try buildBundle(
                jurisdiction: jurisdiction,
                lines: lines,
                request: request,
                activeDayFraction: activeDays
            )
            bundles.append(bundle)
        }
        return bundles
    }

    // MARK: Normalization

    private static func normalize(lines: [TaxLedgerLine], fxRates: TaxFXRateTable) throws -> [TaxLedgerLine] {
        try lines.map { line in
            let usd = try fxRates.toUSD(amount: line.amount, currency: line.currency)
            return TaxLedgerLine(
                id: line.id,
                entityID: line.entityID,
                occurredAt: line.occurredAt,
                kind: line.kind,
                category: line.category,
                amount: round2(usd),
                currency: "USD",
                jurisdiction: line.jurisdiction,
                counterparty: line.counterparty,
                memo: line.memo
            )
        }
    }

    private static func filterToEntityAndYear(
        _ lines: [TaxLedgerLine],
        entity: TaxEntity,
        taxYear: Int
    ) -> [TaxLedgerLine] {
        let calendar = Calendar(identifier: .gregorian)
        let (start, end) = fiscalYearBounds(year: taxYear, entity: entity, calendar: calendar)
        let lowerActive = entity.incorporatedAt ?? Date.distantPast
        let upperActive = entity.dissolvedAt ?? Date.distantFuture
        return lines
            .filter { $0.entityID == entity.id }
            .filter { $0.occurredAt >= start && $0.occurredAt < end }
            .filter { $0.occurredAt >= lowerActive && $0.occurredAt <= upperActive }
            .sorted { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                return lhs.id < rhs.id
            }
    }

    private static func fiscalYearBounds(
        year: Int,
        entity: TaxEntity,
        calendar: Calendar
    ) -> (Date, Date) {
        var startComponents = DateComponents()
        startComponents.year = year
        startComponents.month = entity.fiscalYearStartMonth
        startComponents.day = 1
        startComponents.timeZone = TimeZone(identifier: "UTC")
        let start = calendar.date(from: startComponents) ?? Date(timeIntervalSince1970: 0)
        let end = calendar.date(byAdding: .year, value: 1, to: start) ?? start
        return (start, end)
    }

    // MARK: Allocation

    private static func allocate(
        lines: [TaxLedgerLine],
        entity: TaxEntity,
        jurisdictions: [String]
    ) -> [String: [TaxLedgerLine]] {
        var buckets: [String: [TaxLedgerLine]] = Dictionary(uniqueKeysWithValues: jurisdictions.map { ($0, []) })

        for line in lines {
            if let pinned = line.jurisdiction, buckets[pinned] != nil {
                buckets[pinned]?.append(line)
                continue
            }
            let splits = split(line: line, entity: entity, jurisdictions: jurisdictions)
            for (jurisdiction, fragment) in splits {
                buckets[jurisdiction, default: []].append(fragment)
            }
        }

        for key in buckets.keys {
            buckets[key]?.sort { lhs, rhs in
                if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
                return lhs.id < rhs.id
            }
        }
        return buckets
    }

    private static func split(
        line: TaxLedgerLine,
        entity: TaxEntity,
        jurisdictions: [String]
    ) -> [(String, TaxLedgerLine)] {
        switch entity.allocation {
        case .primaryOnly:
            return [(entity.primaryJurisdiction, line)]
        case .equalSplit:
            let share = 1.0 / Double(jurisdictions.count)
            return jurisdictions.map { jurisdiction in
                (jurisdiction, fragment(of: line, share: share, jurisdiction: jurisdiction))
            }
        case let .revenueProportional(weights):
            let total = jurisdictions.reduce(0.0) { $0 + max(0, weights[$1] ?? 0) }
            guard total > 0 else {
                return [(entity.primaryJurisdiction, line)]
            }
            return jurisdictions.map { jurisdiction in
                let share = max(0, weights[jurisdiction] ?? 0) / total
                return (jurisdiction, fragment(of: line, share: share, jurisdiction: jurisdiction))
            }
        }
    }

    private static func fragment(of line: TaxLedgerLine, share: Double, jurisdiction: String) -> TaxLedgerLine {
        TaxLedgerLine(
            id: "\(line.id)#\(jurisdiction)",
            entityID: line.entityID,
            occurredAt: line.occurredAt,
            kind: line.kind,
            category: line.category,
            amount: round2(line.amount * share),
            currency: "USD",
            jurisdiction: jurisdiction,
            counterparty: line.counterparty,
            memo: line.memo
        )
    }

    // MARK: Prorating

    private static func activeDayFraction(entity: TaxEntity, taxYear: Int) -> Double {
        let calendar = Calendar(identifier: .gregorian)
        let (yearStart, yearEnd) = fiscalYearBounds(year: taxYear, entity: entity, calendar: calendar)
        let totalDays = max(1, calendar.dateComponents([.day], from: yearStart, to: yearEnd).day ?? 365)

        let activeStart = max(entity.incorporatedAt ?? yearStart, yearStart)
        let activeEnd = min(entity.dissolvedAt ?? yearEnd, yearEnd)
        if activeEnd <= activeStart { return 0 }
        let activeDays = max(0, calendar.dateComponents([.day], from: activeStart, to: activeEnd).day ?? totalDays)
        return min(1.0, Double(activeDays) / Double(totalDays))
    }

    // MARK: Bundle assembly

    private static func buildBundle(
        jurisdiction: String,
        lines: [TaxLedgerLine],
        request: TaxExportRequest,
        activeDayFraction: Double
    ) throws -> TaxExportBundle {
        let isUSFed = jurisdiction == "US-FED"
        let isUSCA = jurisdiction == "US-CA"

        var files: [TaxExportFile] = []
        var notes: [String] = []
        if activeDayFraction < 1.0 {
            notes.append(String(
                format: "Active-day fraction: %.4f (prorated for mid-year incorporation/dissolution).",
                activeDayFraction
            ))
        }
        if lines.isEmpty {
            notes.append("Zero ledger activity for this jurisdiction; export contains empty registers and zero totals.")
        }

        files.append(makePLFile(lines: lines, jurisdiction: jurisdiction))
        files.append(makeRevenueRegisterFile(lines: lines))
        files.append(makeExpenseRegisterFile(lines: lines))

        if isUSFed {
            files.append(makeIRSLineItemFile(lines: lines, entity: request.entity))
            files.append(make1099Register(
                payments: request.contractorPayments,
                entity: request.entity,
                taxYear: request.taxYear
            ))
            files.append(makeQuarterlyEstimatesFile(
                lines: lines,
                entity: request.entity,
                taxYear: request.taxYear,
                jurisdiction: jurisdiction,
                activeDayFraction: activeDayFraction
            ))
            let unclassifiedCount = lines.filter {
                IRSLineItem.classify($0.category, kind: $0.kind) == .unclassified && $0.kind == .cost
            }.count
            if unclassifiedCount > 0 {
                notes.append("\(unclassifiedCount) cost line(s) classified as 'unclassified' — operator triage required.")
            }
        }

        if isUSCA {
            files.append(makeCASalesTaxFile(lines: lines))
            files.append(makeQuarterlyEstimatesFile(
                lines: lines,
                entity: request.entity,
                taxYear: request.taxYear,
                jurisdiction: jurisdiction,
                activeDayFraction: activeDayFraction
            ))
        }

        let totals = computeTotals(lines: lines)
        let totalsChecksum = computeTotalsChecksum(lines: lines, totals: totals)

        let manifest = TaxExportManifest(
            entityID: request.entity.id,
            entityLegalName: request.entity.legalName,
            taxYear: request.taxYear,
            jurisdiction: jurisdiction,
            sourceLedgerCommitHash: request.sourceLedgerCommitHash,
            exportedAt: request.exportTimestamp,
            totalsChecksum: totalsChecksum,
            files: files.map { TaxExportManifest.Entry(path: $0.path, sha256: $0.sha256Hex, byteCount: $0.bytes.count) },
            totals: totals,
            notes: notes
        )

        let manifestFile = try makeManifestFile(manifest)
        files.append(manifestFile)

        return TaxExportBundle(
            entityID: request.entity.id,
            jurisdiction: jurisdiction,
            taxYear: request.taxYear,
            manifest: manifest,
            files: files
        )
    }

    // MARK: File builders

    private static func makePLFile(lines: [TaxLedgerLine], jurisdiction: String) -> TaxExportFile {
        let revenue = sumUSD(lines.filter { $0.kind == .revenue })
        let refunds = sumUSD(lines.filter { $0.kind == .refund })
        let costs = sumUSD(lines.filter { $0.kind == .cost })
        let net = revenue - refunds - costs

        let header = csvHeader(for: jurisdiction)
        let rows: [[String]] = [
            ["Gross revenue", money(revenue)],
            ["Refunds and allowances", money(refunds)],
            ["Total costs", money(costs)],
            ["Net income", money(net)]
        ]
        let csv = csvBody(header: header, rows: rows)
        return TaxExportFile(path: "pl.csv", bytes: Data(csv.utf8))
    }

    private static func csvHeader(for jurisdiction: String) -> [String] {
        switch jurisdiction {
        case "US-FED", "US-CA":
            return ["line_item", "amount_usd"]
        default:
            return ["line_item", "amount_usd"]
        }
    }

    private static func makeRevenueRegisterFile(lines: [TaxLedgerLine]) -> TaxExportFile {
        let header = ["id", "occurred_at", "category", "amount_usd", "jurisdiction", "counterparty", "memo"]
        let rows = lines.filter { $0.kind == .revenue }.map { row(for: $0) }
        return TaxExportFile(path: "revenue_register.csv", bytes: Data(csvBody(header: header, rows: rows).utf8))
    }

    private static func makeExpenseRegisterFile(lines: [TaxLedgerLine]) -> TaxExportFile {
        let header = ["id", "occurred_at", "category", "amount_usd", "jurisdiction", "counterparty", "memo"]
        let rows = lines.filter { $0.kind == .cost }.map { row(for: $0) }
        return TaxExportFile(path: "expense_register.csv", bytes: Data(csvBody(header: header, rows: rows).utf8))
    }

    private static func makeIRSLineItemFile(lines: [TaxLedgerLine], entity: TaxEntity) -> TaxExportFile {
        var totals: [IRSLineItem: Double] = [:]
        for line in lines {
            let li = IRSLineItem.classify(line.category, kind: line.kind)
            totals[li, default: 0] += line.amount
        }
        let header = ["form", "line_item", "amount_usd"]
        let rows = IRSLineItem.allCases.map { li in
            [entity.entityType.usFederalForm, li.displayName, money(totals[li] ?? 0)]
        }
        return TaxExportFile(path: "irs_line_items.csv", bytes: Data(csvBody(header: header, rows: rows).utf8))
    }

    private static func make1099Register(
        payments: [TaxContractorPayment],
        entity: TaxEntity,
        taxYear: Int
    ) -> TaxExportFile {
        let header = [
            "recipient_name", "recipient_tax_id", "recipient_country",
            "amount_usd", "us_resident", "form_type", "withholding_required"
        ]
        let eligible = payments
            .filter { $0.payerEntityID == entity.id && $0.amountUSD >= 600.0 }
            .sorted { $0.recipientName < $1.recipientName }
        let rows: [[String]] = eligible.map { payment in
            let form = payment.isUSResident ? "1099-NEC" : "1042-S"
            let withhold = payment.isUSResident ? "no" : "yes"
            return [
                payment.recipientName,
                payment.recipientTaxID ?? "",
                payment.recipientCountry,
                money(payment.amountUSD),
                payment.isUSResident ? "yes" : "no",
                form,
                withhold
            ]
        }
        var body = csvBody(header: header, rows: rows)
        body += "\n# tax_year=\(taxYear) threshold_usd=600.00"
        return TaxExportFile(path: "1099_register.csv", bytes: Data(body.utf8))
    }

    private static func makeQuarterlyEstimatesFile(
        lines: [TaxLedgerLine],
        entity: TaxEntity,
        taxYear: Int,
        jurisdiction: String,
        activeDayFraction: Double
    ) -> TaxExportFile {
        let revenue = sumUSD(lines.filter { $0.kind == .revenue })
        let refunds = sumUSD(lines.filter { $0.kind == .refund })
        let costs = sumUSD(lines.filter { $0.kind == .cost })
        let net = max(0, revenue - refunds - costs)
        let rate = jurisdiction == "US-FED" ? 0.22 : 0.093  // federal default / CA top marginal-ish
        let estimatedTax = round2(net * rate * activeDayFraction)
        let perQuarter = round2(estimatedTax / 4.0)

        let deadlines = quarterlyDeadlines(taxYear: taxYear, jurisdiction: jurisdiction)
        let header = ["quarter", "deadline", "amount_usd", "basis"]
        let rows: [[String]] = zip(["Q1", "Q2", "Q3", "Q4"], deadlines).map { quarter, deadline in
            [
                quarter,
                deadline,
                money(perQuarter),
                "net=\(money(net)) rate=\(String(format: "%.4f", rate)) active=\(String(format: "%.4f", activeDayFraction))"
            ]
        }
        return TaxExportFile(path: "quarterly_estimates.csv", bytes: Data(csvBody(header: header, rows: rows).utf8))
    }

    private static func quarterlyDeadlines(taxYear: Int, jurisdiction: String) -> [String] {
        // US Federal estimated tax deadlines (1040-ES): Apr 15, Jun 15, Sep 15, Jan 15 (following year)
        // CA FTB Form 540-ES uses the same calendar dates.
        let nextYear = taxYear + 1
        return [
            String(format: "%04d-04-15", taxYear),
            String(format: "%04d-06-15", taxYear),
            String(format: "%04d-09-15", taxYear),
            String(format: "%04d-01-15", nextYear)
        ]
    }

    private static func makeCASalesTaxFile(lines: [TaxLedgerLine]) -> TaxExportFile {
        // Lightweight CA sales-tax accrual: revenue with `jurisdiction == "US-CA"`
        // accrues sales tax at the documented baseline rate (7.25% statewide minimum).
        let caRevenue = lines.filter { $0.kind == .revenue && ($0.jurisdiction ?? "US-CA") == "US-CA" }
        let total = sumUSD(caRevenue)
        let tax = round2(total * 0.0725)
        let header = ["jurisdiction", "taxable_revenue_usd", "rate", "tax_owed_usd", "filing_form"]
        let rows: [[String]] = [
            ["US-CA", money(total), "0.0725", money(tax), "CDTFA-401"]
        ]
        return TaxExportFile(path: "sales_tax_summary.csv", bytes: Data(csvBody(header: header, rows: rows).utf8))
    }

    private static func makeManifestFile(_ manifest: TaxExportManifest) throws -> TaxExportFile {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(formatISO8601(date))
        }
        let data = try encoder.encode(manifest)
        return TaxExportFile(path: "manifest.json", bytes: data)
    }

    // MARK: Totals + checksum

    private static func computeTotals(lines: [TaxLedgerLine]) -> TaxExportManifest.Totals {
        let revenue = sumUSD(lines.filter { $0.kind == .revenue })
        let refunds = sumUSD(lines.filter { $0.kind == .refund })
        let costs = sumUSD(lines.filter { $0.kind == .cost })
        return TaxExportManifest.Totals(
            revenueUSD: round2(revenue),
            refundsUSD: round2(refunds),
            costUSD: round2(costs),
            netUSD: round2(revenue - refunds - costs),
            lineCount: lines.count
        )
    }

    private static func computeTotalsChecksum(
        lines: [TaxLedgerLine],
        totals: TaxExportManifest.Totals
    ) -> String {
        var canonical = ""
        for line in lines {
            canonical += "\(line.id)|\(line.kind.rawValue)|\(line.category?.rawValue ?? "-")|\(money(line.amount))\n"
        }
        canonical += "TOTAL|revenue=\(money(totals.revenueUSD))|refunds=\(money(totals.refundsUSD))|"
        canonical += "cost=\(money(totals.costUSD))|net=\(money(totals.netUSD))|count=\(totals.lineCount)"
        return sha256Hex(Data(canonical.utf8))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Formatting helpers

    private static func row(for line: TaxLedgerLine) -> [String] {
        [
            line.id,
            formatISO8601(line.occurredAt),
            line.category?.rawValue ?? "",
            money(line.amount),
            line.jurisdiction ?? "",
            line.counterparty ?? "",
            line.memo
        ]
    }

    private static func csvBody(header: [String], rows: [[String]]) -> String {
        ([header] + rows)
            .map { $0.map(csvEscape).joined(separator: ",") }
            .joined(separator: "\n")
    }

    private static func csvEscape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func money(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func round2(_ value: Double) -> Double {
        (value * 100.0).rounded() / 100.0
    }

    private static func sumUSD(_ lines: [TaxLedgerLine]) -> Double {
        lines.reduce(0) { $0 + $1.amount }
    }

    private static func formatISO8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: date)
    }
}

// MARK: - Doctor surface

struct TaxPipelineDoctorRow: Codable, Hashable {
    var unclassifiedCostCount: Int
    var missingEntityMappingCount: Int
    var salesTaxAccruedSinceLastFilingUSD: Double
    var nextQuarterlyEstimateDeadline: String?
    var daysUntilNextDeadline: Int?

    static func compute(
        ledger: [CompanyLedgerEntry],
        registry: TaxEntityRegistry,
        now: Date
    ) -> TaxPipelineDoctorRow {
        let missingMapping = ledger.filter { entry in
            guard let companyID = entry.companyID else { return true }
            return registry.companyToEntity[companyID] == nil
        }.count
        let unclassifiedCosts = ledger.filter { entry in
            entry.kind == .cost && IRSLineItem.classify(entry.category, kind: entry.kind) == .unclassified
        }.count

        let calendar = Calendar(identifier: .gregorian)
        let year = calendar.component(.year, from: now)
        let deadlines: [Date] = [
            calendar.date(from: DateComponents(year: year, month: 4, day: 15)),
            calendar.date(from: DateComponents(year: year, month: 6, day: 15)),
            calendar.date(from: DateComponents(year: year, month: 9, day: 15)),
            calendar.date(from: DateComponents(year: year + 1, month: 1, day: 15))
        ].compactMap { $0 }
        let next = deadlines.first(where: { $0 >= now })
        let nextString = next.map { formatYMD($0, calendar: calendar) }
        let daysUntil = next.map {
            max(0, calendar.dateComponents([.day], from: now, to: $0).day ?? 0)
        }

        return TaxPipelineDoctorRow(
            unclassifiedCostCount: unclassifiedCosts,
            missingEntityMappingCount: missingMapping,
            salesTaxAccruedSinceLastFilingUSD: 0,
            nextQuarterlyEstimateDeadline: nextString,
            daysUntilNextDeadline: daysUntil
        )
    }

    private static func formatYMD(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
