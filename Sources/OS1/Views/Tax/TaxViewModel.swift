import Foundation
import SwiftUI

/// Drives the Tax tab. Owns the in-memory `TaxEntityRegistry`, the most-
/// recent export status, and the quarterly-estimate panel data. UI is
/// deliberately thin (`TaxView`) — the testable logic lives here.
@MainActor
final class TaxViewModel: ObservableObject {
    @Published private(set) var registry: TaxEntityRegistry
    @Published var selectedEntityID: String?
    @Published var taxYear: Int
    @Published private(set) var lastExport: TaxExportResult?
    @Published private(set) var quarterlyEstimates: [QuarterlyEstimate] = []
    @Published var statusMessage: String?

    struct TaxExportResult: Equatable {
        var directory: URL
        var entityID: String
        var taxYear: Int
        var jurisdictions: [String]
        var bundleCount: Int
    }

    struct QuarterlyEstimate: Equatable, Identifiable {
        var id: String { "\(jurisdiction)-\(quarter)" }
        var jurisdiction: String
        var quarter: String       // "Q1" / "Q2" / "Q3" / "Q4"
        var deadline: String      // YYYY-MM-DD
        var daysUntilDeadline: Int
    }

    private let registryURL: URL
    private let fxRates: TaxFXRateTable

    init(
        registry: TaxEntityRegistry? = nil,
        registryURL: URL = TaxViewModel.defaultRegistryURL(),
        taxYear: Int? = nil,
        fxRates: TaxFXRateTable = TaxViewModel.defaultFXRateTable()
    ) {
        self.registryURL = registryURL
        self.fxRates = fxRates
        if let registry {
            self.registry = registry
        } else {
            self.registry = TaxViewModel.loadRegistry(at: registryURL) ?? TaxEntityRegistry()
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        self.taxYear = taxYear ?? calendar.component(.year, from: Date())
        self.selectedEntityID = self.registry.entities.first?.id
        recomputeQuarterlyEstimates(now: Date())
    }

    /// Run the export pipeline for `selectedEntityID` and write every
    /// resulting bundle into `root`. Returns a summary suitable for display.
    @discardableResult
    func runExport(
        to root: URL,
        ledgerLines: [TaxLedgerLine] = [],
        contractorPayments: [TaxContractorPayment] = [],
        sourceLedgerCommitHash: String,
        now: Date = Date()
    ) throws -> TaxExportResult {
        guard let entityID = selectedEntityID,
              let entity = registry.entities.first(where: { $0.id == entityID }) else {
            throw ExportError.noEntitySelected
        }
        let request = TaxExportRequest(
            entity: entity,
            taxYear: taxYear,
            ledgerLines: ledgerLines,
            contractorPayments: contractorPayments,
            fxRates: fxRates,
            sourceLedgerCommitHash: sourceLedgerCommitHash,
            exportTimestamp: now
        )
        let bundles = try TaxExportPipeline.generate(request)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outputs = try TaxExportBundleWriter.write(bundles, to: root)
        let result = TaxExportResult(
            directory: root,
            entityID: entityID,
            taxYear: taxYear,
            jurisdictions: bundles.map(\.jurisdiction).sorted(),
            bundleCount: bundles.count
        )
        lastExport = result
        statusMessage = "Wrote \(outputs.count) bundle(s) to \(root.path)"
        return result
    }

    func recomputeQuarterlyEstimates(now: Date = Date()) {
        guard let entityID = selectedEntityID,
              let entity = registry.entities.first(where: { $0.id == entityID }) else {
            quarterlyEstimates = []
            return
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let deadlines = TaxExportPipeline.quarterlyDeadlines(taxYear: taxYear, entity: entity)
        var rows: [QuarterlyEstimate] = []
        for jurisdiction in entity.allJurisdictions where jurisdiction == "US-FED" || jurisdiction == "US-CA" {
            for (idx, deadline) in deadlines.enumerated() {
                let daysUntil = Self.days(from: now, toYMD: deadline, calendar: calendar) ?? 0
                rows.append(QuarterlyEstimate(
                    jurisdiction: jurisdiction,
                    quarter: ["Q1", "Q2", "Q3", "Q4"][idx],
                    deadline: deadline,
                    daysUntilDeadline: daysUntil
                ))
            }
        }
        quarterlyEstimates = rows
    }

    /// Static factory — workaround for a Swift 6 SILGen crash that fires when
    /// `@StateObject private var taxViewModel = TaxViewModel()` is lowered.
    /// RootView calls this instead of the bare initializer.
    static func make() -> TaxViewModel {
        TaxViewModel()
    }

    static func defaultRegistryURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".os1", isDirectory: true)
            .appendingPathComponent(TaxEntityRegistry.fileName)
    }

    static func loadRegistry(at url: URL) -> TaxEntityRegistry? {
        guard FileManager.default.fileExists(atPath: url.path),
              let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(TaxEntityRegistry.self, from: data)
    }

    /// Default FX fixture used when the operator has not pinned a snapshot
    /// for the tax year. Filing-year-correct FX rates ship with the export
    /// fixtures (`docs/tax-export.md`); this table is a safety floor.
    static func defaultFXRateTable(now: Date = Date()) -> TaxFXRateTable {
        TaxFXRateTable(
            asOf: now,
            rates: ["EUR": 1.08, "GBP": 1.27, "CAD": 0.74, "JPY": 0.0067]
        )
    }

    enum ExportError: Error, LocalizedError {
        case noEntitySelected

        var errorDescription: String? {
            switch self {
            case .noEntitySelected:
                return "Select an entity before running the export."
            }
        }
    }

    private static func days(from now: Date, toYMD ymd: String, calendar: Calendar) -> Int? {
        let parts = ymd.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3,
              let date = calendar.date(from: DateComponents(
                  year: parts[0],
                  month: parts[1],
                  day: parts[2]
              )) else { return nil }
        return max(0, calendar.dateComponents([.day], from: now, to: date).day ?? 0)
    }
}
