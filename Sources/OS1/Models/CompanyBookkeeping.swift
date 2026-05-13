import Foundation

struct CompanyAccountingMonth: Codable, Hashable, Comparable, CustomStringConvertible {
    var year: Int
    var month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = min(12, max(1, month))
    }

    var description: String {
        String(format: "%04d-%02d", year, month)
    }

    static func < (lhs: CompanyAccountingMonth, rhs: CompanyAccountingMonth) -> Bool {
        lhs.year == rhs.year ? lhs.month < rhs.month : lhs.year < rhs.year
    }

    static func containing(_ date: Date?, calendar: Calendar = .init(identifier: .gregorian)) -> Self {
        guard let date else { return Self(year: 1970, month: 1) }
        let components = calendar.dateComponents([.year, .month], from: date)
        return Self(year: components.year ?? 1970, month: components.month ?? 1)
    }
}

enum CompanyAccountingCategory: String, Codable, Hashable {
    case salesRevenue
    case subscriptionRevenue
    case refunds
    case paymentProcessingFees
    case advertising
    case software
    case cloudInfrastructure
    case aiUsage
    case contractorLabor
    case purchases
    case taxes
    case transfers
    case otherExpense
}

struct CompanyVendorTaxForm: Codable, Hashable, Identifiable {
    enum Status: String, Codable, Hashable {
        case missing
        case requested
        case received
        case notRequired
    }

    var id: String
    var vendorName: String
    var formType: String
    var taxYear: Int
    var amountPaidUSD: Double
    var status: Status
    var reference: String?
}

struct CompanyAccountingProfile: Codable, Hashable {
    var companyID: String
    var legalName: String
    var entityType: String
    var taxCountry: String
    var taxRegion: String?
    var currency: String
    var taxIdentifierLast4: String?
    var vendorTaxForms: [CompanyVendorTaxForm]

    var missingPaidCompanyFields: [String] {
        var fields: [String] = []
        if legalName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("legalName") }
        if entityType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("entityType") }
        if taxCountry.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("taxCountry") }
        if currency.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { fields.append("currency") }
        if vendorTaxForms.contains(where: { $0.status == .missing }) { fields.append("vendorTaxForms") }
        return fields
    }
}

struct CompanyFinancialDocument: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case invoice
        case receipt
    }

    enum Status: String, Codable, Hashable {
        case draft
        case sent
        case paid
        case void
        case missing
    }

    var id: String
    var companyID: String
    var kind: Kind
    var counterparty: String
    var amountUSD: Double
    var issuedAt: Date?
    var sourceReference: String?
    var status: Status
}

struct CompanyPaymentProviderEvent: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case charge
        case refund
        case fee
        case tax
        case payout
        case transfer
    }

    var id: String
    var companyID: String
    var occurredAt: Date?
    var provider: String
    var kind: Kind
    var amountUSD: Double
    var sourceReference: String
    /// Tax entity this event belongs to. Filled either at construction time or
    /// via `withEntityID(from:)` once the operator's `TaxEntityRegistry` is
    /// available. Optional for backward-compatibility with existing on-disk
    /// `PAYMENT_PROVIDER_EVENTS.json` files (legacy rows decode to nil and the
    /// Doctor `tax-pipeline` row surfaces the gap for backfill).
    var entityID: String? = nil

    /// Returns a copy with `entityID` populated by looking up `companyID` in
    /// the registry. If the registry has no mapping for the company, the
    /// `entityID` is left nil — Doctor's missing-entity-mapping count picks it
    /// up so the operator knows to register the entity.
    func withEntityID(from registry: TaxEntityRegistry) -> CompanyPaymentProviderEvent {
        guard let mapped = registry.companyToEntity[companyID] else { return self }
        var copy = self
        copy.entityID = mapped
        return copy
    }
}

extension CompanyPaymentProviderEvent {
    init(conversionEvent event: CompanyPaymentConversionEvent) {
        let kind: Kind = switch event.kind {
        case .checkoutCompleted:
            .charge
        case .refundCreated, .chargebackOpened:
            .refund
        }
        self.init(
            id: "\(event.provider.rawValue)-\(event.id)",
            companyID: event.companyID,
            occurredAt: event.occurredAt,
            provider: event.provider.rawValue,
            kind: kind,
            amountUSD: event.amountUSD,
            sourceReference: event.providerReference
        )
    }
}

struct CompanyPaymentProviderEventStore {
    static let fileName = "PAYMENT_PROVIDER_EVENTS.json"

    var url: URL

    func load() throws -> [CompanyPaymentProviderEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([CompanyPaymentProviderEvent].self, from: Data(contentsOf: url))
    }

    @discardableResult
    func appendIfNew(_ event: CompanyPaymentProviderEvent) throws -> CompanyPaymentProviderEvent {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var events = try load()
        if let existing = events.first(where: { $0.id == event.id }) {
            return existing
        }
        events.append(event)
        events.sort { lhs, rhs in
            switch (lhs.occurredAt, rhs.occurredAt) {
            case let (left?, right?) where left != right:
                return left < right
            default:
                return lhs.id < rhs.id
            }
        }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(events).write(to: url, options: .atomic)
        return event
    }
}

struct CompanyReconciliationLine: Codable, Hashable, Identifiable {
    enum Status: String, Codable, Hashable {
        case matched
        case amountMismatch
        case missingLedgerEntry
        case manualOverride
        case unreconciledLedgerEntry
    }

    var id: String
    var providerEventID: String?
    var ledgerEntryID: String?
    var status: Status
    var providerAmountUSD: Double
    var ledgerAmountUSD: Double
    var varianceUSD: Double
    var note: String
}

struct CompanyAccountingRow: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var date: Date?
    var kind: CompanyLedgerEntry.Kind
    var accountingCategory: CompanyAccountingCategory
    var amountUSD: Double
    var source: String
    var sourceReference: String?
    var confidence: CompanyLedgerEntry.Confidence
    var memo: String
}

struct CompanyMonthlyFinancialReport: Codable, Hashable {
    var companyID: String
    var month: CompanyAccountingMonth
    var ledgerSummary: CompanyLedgerSummary
    var providerTotalsUSD: [CompanyPaymentProviderEvent.Kind: Double]
    var ledgerTotalsUSD: [CompanyLedgerEntry.Kind: Double]
    var accountingRows: [CompanyAccountingRow]
    var reconciliationLines: [CompanyReconciliationLine]
    var invoices: [CompanyFinancialDocument]
    var receipts: [CompanyFinancialDocument]
    var accountingProfile: CompanyAccountingProfile?

    var manualOverrideEntries: [CompanyLedgerEntry] {
        ledgerSummary.entries.filter { $0.confidence == .manualOverride }
    }

    var unreconciledEntries: [CompanyLedgerEntry] {
        let unreconciledIDs = Set(reconciliationLines.compactMap { line in
            line.status == .unreconciledLedgerEntry ? line.ledgerEntryID : nil
        })
        return ledgerSummary.entries.filter { unreconciledIDs.contains($0.id) }
    }

    var providerLedgerVarianceUSD: Double {
        reconciliationLines.reduce(0) { $0 + abs($1.varianceUSD) }
    }

    var isReconciled: Bool {
        reconciliationLines.allSatisfy { $0.status == .matched || $0.status == .manualOverride }
    }

    var missingPaidCompanyMetadata: [String] {
        guard ledgerSummary.revenueUSD > 0 || ledgerSummary.costUSD > 0 else { return [] }
        guard let accountingProfile else { return ["accountingProfile"] }
        return accountingProfile.missingPaidCompanyFields
    }
}

struct CompanyPortfolioFinancialReport: Codable, Hashable {
    var month: CompanyAccountingMonth
    var companyReports: [CompanyMonthlyFinancialReport]

    var ledgerSummary: CompanyLedgerSummary {
        CompanyLedgerSummary(entries: companyReports.flatMap(\.ledgerSummary.entries))
    }

    var unreconciledCount: Int {
        companyReports.reduce(0) { $0 + $1.unreconciledEntries.count }
    }

    var missingMetadataCompanyIDs: [String] {
        companyReports
            .filter { !$0.missingPaidCompanyMetadata.isEmpty }
            .map(\.companyID)
            .sorted()
    }
}

enum CompanyBookkeepingEngine {
    static func monthlyCompanyReport(
        companyID: String,
        month: CompanyAccountingMonth,
        ledger: CompanyLedgerSummary,
        providerEvents: [CompanyPaymentProviderEvent],
        documents: [CompanyFinancialDocument] = [],
        accountingProfile: CompanyAccountingProfile? = nil
    ) -> CompanyMonthlyFinancialReport {
        let ledgerEntries = ledger.entries.filter {
            ($0.companyID == nil || $0.companyID == companyID) &&
                CompanyAccountingMonth.containing($0.occurredAt) == month
        }
        let monthlyLedger = CompanyLedgerSummary(entries: ledgerEntries)
        let monthlyProviderEvents = providerEvents.filter {
            $0.companyID == companyID && CompanyAccountingMonth.containing($0.occurredAt) == month
        }
        let monthlyDocuments = documents.filter {
            $0.companyID == companyID && CompanyAccountingMonth.containing($0.issuedAt) == month
        }

        return CompanyMonthlyFinancialReport(
            companyID: companyID,
            month: month,
            ledgerSummary: monthlyLedger,
            providerTotalsUSD: totalsByProviderKind(monthlyProviderEvents),
            ledgerTotalsUSD: totalsByLedgerKind(monthlyLedger.entries),
            accountingRows: monthlyLedger.entries.map(accountingRow),
            reconciliationLines: reconcile(ledgerEntries: monthlyLedger.entries, providerEvents: monthlyProviderEvents),
            invoices: monthlyDocuments.filter { $0.kind == .invoice },
            receipts: monthlyDocuments.filter { $0.kind == .receipt },
            accountingProfile: accountingProfile
        )
    }

    static func portfolioReport(month: CompanyAccountingMonth, reports: [CompanyMonthlyFinancialReport])
        -> CompanyPortfolioFinancialReport {
        CompanyPortfolioFinancialReport(
            month: month,
            companyReports: reports.filter { $0.month == month }.sorted { $0.companyID < $1.companyID }
        )
    }

    static func accountingCategory(for entry: CompanyLedgerEntry) -> CompanyAccountingCategory {
        switch entry.category {
        case .sales:
            return .salesRevenue
        case .subscription:
            return .subscriptionRevenue
        case .refund:
            return .refunds
        case .paymentFees:
            return .paymentProcessingFees
        case .ads:
            return .advertising
        case .tools:
            return .software
        case .cloudCompute:
            return .cloudInfrastructure
        case .tokenUsage:
            return .aiUsage
        case .manualLabor:
            return .contractorLabor
        case .purchases:
            return .purchases
        case .other, .none:
            return entry.kind == .revenue ? .salesRevenue : .otherExpense
        }
    }

    private static func accountingRow(_ entry: CompanyLedgerEntry) -> CompanyAccountingRow {
        CompanyAccountingRow(
            id: entry.id,
            companyID: entry.companyID ?? "",
            date: entry.occurredAt,
            kind: entry.kind,
            accountingCategory: accountingCategory(for: entry),
            amountUSD: signedAmount(for: entry),
            source: entry.source,
            sourceReference: entry.sourceReference,
            confidence: entry.confidence,
            memo: entry.note
        )
    }

    private static func reconcile(
        ledgerEntries: [CompanyLedgerEntry],
        providerEvents: [CompanyPaymentProviderEvent],
        toleranceUSD: Double = 0.01
    ) -> [CompanyReconciliationLine] {
        var usedLedgerIDs = Set<String>()
        var lines: [CompanyReconciliationLine] = providerEvents.map { event in
            guard let entry = bestMatch(for: event, entries: ledgerEntries, excluding: usedLedgerIDs) else {
                return CompanyReconciliationLine(
                    id: "provider-\(event.id)",
                    providerEventID: event.id,
                    ledgerEntryID: nil,
                    status: .missingLedgerEntry,
                    providerAmountUSD: event.amountUSD,
                    ledgerAmountUSD: 0,
                    varianceUSD: event.amountUSD,
                    note: "Provider event is missing from OS1 ledger."
                )
            }
            usedLedgerIDs.insert(entry.id)
            let ledgerAmount = comparableAmount(for: entry)
            let variance = event.amountUSD - ledgerAmount
            let status: CompanyReconciliationLine.Status = abs(variance) <= toleranceUSD ? .matched : .amountMismatch
            return CompanyReconciliationLine(
                id: "provider-\(event.id)",
                providerEventID: event.id,
                ledgerEntryID: entry.id,
                status: entry.confidence == .manualOverride ? .manualOverride : status,
                providerAmountUSD: event.amountUSD,
                ledgerAmountUSD: ledgerAmount,
                varianceUSD: variance,
                note: status == .matched ? "Provider total reconciles to OS1 ledger." : "Provider and ledger differ."
            )
        }

        for entry in ledgerEntries where !usedLedgerIDs.contains(entry.id) {
            let status: CompanyReconciliationLine.Status = entry.confidence == .manualOverride
                ? .manualOverride
                : .unreconciledLedgerEntry
            lines.append(
                CompanyReconciliationLine(
                    id: "ledger-\(entry.id)",
                    providerEventID: nil,
                    ledgerEntryID: entry.id,
                    status: status,
                    providerAmountUSD: 0,
                    ledgerAmountUSD: comparableAmount(for: entry),
                    varianceUSD: -comparableAmount(for: entry),
                    note: status == .manualOverride
                        ? "Manual override requires accounting review."
                        : "No provider match."
                )
            )
        }
        return lines.sorted { $0.id < $1.id }
    }

    private static func bestMatch(
        for event: CompanyPaymentProviderEvent,
        entries: [CompanyLedgerEntry],
        excluding usedLedgerIDs: Set<String>
    ) -> CompanyLedgerEntry? {
        entries.first { entry in
            !usedLedgerIDs.contains(entry.id) &&
                ledgerKind(for: event.kind) == entry.kind &&
                referencesMatch(event.sourceReference, entry.sourceReference ?? entry.note)
        }
    }

    private static func referencesMatch(_ providerReference: String, _ ledgerReference: String) -> Bool {
        let provider = providerReference.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        let ledger = ledgerReference.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        return !provider.isEmpty && ledger.contains(provider)
    }

    private static func ledgerKind(for providerKind: CompanyPaymentProviderEvent.Kind) -> CompanyLedgerEntry.Kind {
        switch providerKind {
        case .charge:
            return .revenue
        case .refund:
            return .refund
        case .fee, .tax, .payout, .transfer:
            return .cost
        }
    }

    private static func signedAmount(for entry: CompanyLedgerEntry) -> Double {
        entry.kind == .revenue ? entry.amountUSD : -entry.amountUSD
    }

    private static func comparableAmount(for entry: CompanyLedgerEntry) -> Double {
        entry.amountUSD
    }

    private static func totalsByProviderKind(_ events: [CompanyPaymentProviderEvent])
        -> [CompanyPaymentProviderEvent.Kind: Double] {
        events.reduce(into: [:]) { totals, event in
            totals[event.kind, default: 0] += event.amountUSD
        }
    }

    private static func totalsByLedgerKind(_ entries: [CompanyLedgerEntry]) -> [CompanyLedgerEntry.Kind: Double] {
        entries.reduce(into: [:]) { totals, entry in
            totals[entry.kind, default: 0] += entry.amountUSD
        }
    }
}

enum CompanyBookkeepingExporter {
    static func monthlyCSV(_ report: CompanyMonthlyFinancialReport) -> String {
        csv(
            header: [
                "month", "company_id", "date", "kind", "accounting_category", "amount_usd",
                "source", "source_reference", "confidence", "memo"
            ],
            rows: report.accountingRows.map { row in
                [
                    report.month.description,
                    report.companyID,
                    dateString(row.date),
                    row.kind.rawValue,
                    row.accountingCategory.rawValue,
                    money(row.amountUSD),
                    row.source,
                    row.sourceReference ?? "",
                    row.confidence.rawValue,
                    row.memo
                ]
            }
        )
    }

    static func qboCSV(_ report: CompanyMonthlyFinancialReport) -> String {
        csv(
            header: ["Date", "Account", "Name", "Memo", "Amount"],
            rows: report.accountingRows.map { row in
                [
                    dateString(row.date),
                    qboAccount(for: row.accountingCategory),
                    report.accountingProfile?.legalName ?? report.companyID,
                    row.memo,
                    money(row.amountUSD)
                ]
            }
        )
    }

    static func portfolioCSV(_ report: CompanyPortfolioFinancialReport) -> String {
        csv(
            header: [
                "month", "company_id", "revenue_usd", "refund_usd", "cost_usd", "net_usd",
                "unreconciled_count", "missing_metadata"
            ],
            rows: report.companyReports.map { company in
                [
                    report.month.description,
                    company.companyID,
                    money(company.ledgerSummary.revenueUSD),
                    money(company.ledgerSummary.refundUSD),
                    money(company.ledgerSummary.costUSD),
                    money(company.ledgerSummary.netUSD),
                    String(company.unreconciledEntries.count),
                    company.missingPaidCompanyMetadata.joined(separator: "|")
                ]
            }
        )
    }

    private static func qboAccount(for category: CompanyAccountingCategory) -> String {
        switch category {
        case .salesRevenue:
            return "Sales"
        case .subscriptionRevenue:
            return "Subscription Income"
        case .refunds:
            return "Refunds and Allowances"
        case .paymentProcessingFees:
            return "Merchant Fees"
        case .advertising:
            return "Advertising"
        case .software:
            return "Software"
        case .cloudInfrastructure:
            return "Hosting"
        case .aiUsage:
            return "AI Usage"
        case .contractorLabor:
            return "Contract Labor"
        case .purchases:
            return "Purchases"
        case .taxes:
            return "Taxes"
        case .transfers:
            return "Transfers"
        case .otherExpense:
            return "Other Business Expense"
        }
    }

    private static func csv(header: [String], rows: [[String]]) -> String {
        ([header] + rows)
            .map { $0.map(escape).joined(separator: ",") }
            .joined(separator: "\n")
    }

    private static func escape(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else { return value }
        return "\"\(value.replacingOccurrences(of: "\"", with: "\"\""))\""
    }

    private static func money(_ value: Double) -> String {
        String(format: "%.2f", value)
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter.string(from: date)
    }
}
