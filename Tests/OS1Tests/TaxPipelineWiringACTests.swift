import Foundation
import Testing
@testable import OS1

/// Acceptance-criteria tests for the #191 wiring follow-up. PR #201 landed
/// the foundation; this suite covers the four wiring gaps the content audit
/// flagged on the reopened issue:
///
/// - AC2 — `entity_id` on every `CompanyPaymentProviderEvent` + ledger line
/// - AC7 — quarterly tax-estimate UI surface
/// - AC8 — Doctor `tax-pipeline` row (red on missing-mappings / unclassified)
/// - AC9 — in-app per-entity-per-tax-year export action
struct TaxPipelineWiringACTests {

    // MARK: AC2 — entity_id propagated onto source event types

    @Test
    func ac2_paymentProviderEventCarriesEntityIDThroughRoundTrip() throws {
        let event = CompanyPaymentProviderEvent(
            id: "ch_1",
            companyID: "co-acme",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            provider: "stripe",
            kind: .charge,
            amountUSD: 250,
            sourceReference: "ch_1",
            entityID: "llc-acme"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(event)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CompanyPaymentProviderEvent.self, from: data)
        #expect(decoded.entityID == "llc-acme")
        #expect(decoded == event)
    }

    @Test
    func ac2_legacyPaymentEventOnDiskDecodesWithNilEntityIDAndBackfillsFromRegistry() throws {
        // Legacy bytes from before this PR — no `entityID` key.
        let legacy = #"""
        {
          "id": "ch_legacy",
          "companyID": "co-acme",
          "occurredAt": "2026-04-01T00:00:00Z",
          "provider": "stripe",
          "kind": "charge",
          "amountUSD": 100,
          "sourceReference": "ch_legacy"
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CompanyPaymentProviderEvent.self, from: Data(legacy.utf8))
        #expect(decoded.entityID == nil)

        let registry = TaxEntityRegistry(
            entities: [TaxEntity(
                id: "llc-acme",
                legalName: "Acme",
                entityType: .llcSingleMember,
                primaryJurisdiction: "US-FED"
            )],
            companyToEntity: ["co-acme": "llc-acme"]
        )
        let backfilled = decoded.withEntityID(from: registry)
        #expect(backfilled.entityID == "llc-acme")
    }

    @Test
    func ac2_ledgerEntryCarriesEntityIDAndIsPreferredOverRegistryFallback() {
        let registry = TaxEntityRegistry(
            entities: [
                TaxEntity(id: "llc-acme", legalName: "Acme", entityType: .llcSingleMember, primaryJurisdiction: "US-FED"),
                TaxEntity(id: "llc-other", legalName: "Other", entityType: .llcSingleMember, primaryJurisdiction: "US-FED")
            ],
            // Registry would resolve co-acme → llc-other, but the entry's own
            // entity_id (llc-acme) must win.
            companyToEntity: ["co-acme": "llc-other"]
        )
        let entry = CompanyLedgerEntry(
            id: "ledger-1",
            companyID: "co-acme",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            kind: .revenue,
            category: .sales,
            amountUSD: 500,
            source: "stripe",
            confidence: .verified,
            note: "Tagged at write time",
            entityID: "llc-acme"
        )
        let line = TaxLedgerLine.from(entry: entry, registry: registry)
        #expect(line?.entityID == "llc-acme")
    }

    @Test
    func ac2_paymentEventBridgeReturnsNilWhenNeitherEventNorRegistryHasEntity() {
        let event = CompanyPaymentProviderEvent(
            id: "ch_2",
            companyID: "co-unknown",
            occurredAt: nil,
            provider: "stripe",
            kind: .charge,
            amountUSD: 50,
            sourceReference: "ch_2"
        )
        let line = TaxLedgerLine.from(paymentEvent: event, registry: TaxEntityRegistry())
        #expect(line == nil)
    }

    // MARK: AC7 — quarterly tax-estimate UI panel

    @MainActor
    @Test
    func ac7_quarterlyEstimatesAppearForEveryFedOrCAJurisdictionWhenEntitySelected() async {
        let entity = TaxEntity(
            id: "llc-acme",
            legalName: "Acme",
            entityType: .llcSingleMember,
            primaryJurisdiction: "US-FED",
            additionalJurisdictions: ["US-CA"],
            fiscalYearStartMonth: 1
        )
        let registry = TaxEntityRegistry(
            entities: [entity],
            companyToEntity: [:]
        )
        let vm = TaxViewModel(registry: registry, taxYear: 2026)
        vm.recomputeQuarterlyEstimates(now: makeDate(2026, 1, 1))
        #expect(vm.quarterlyEstimates.count == 8) // 2 jurisdictions × 4 quarters
        let fedDeadlines = vm.quarterlyEstimates
            .filter { $0.jurisdiction == "US-FED" }
            .map(\.deadline)
        #expect(fedDeadlines == ["2026-04-15", "2026-06-15", "2026-09-15", "2027-01-15"])
    }

    @MainActor
    @Test
    func ac7_quarterlyEstimatesAreEmptyWhenEntityHasNoFedOrCAJurisdiction() async {
        let entity = TaxEntity(
            id: "ltd-uk",
            legalName: "UK Ltd",
            entityType: .foreignEntity,
            primaryJurisdiction: "GB",
            fiscalYearStartMonth: 4
        )
        let registry = TaxEntityRegistry(entities: [entity])
        let vm = TaxViewModel(registry: registry, taxYear: 2026)
        vm.recomputeQuarterlyEstimates(now: makeDate(2026, 5, 1))
        #expect(vm.quarterlyEstimates.isEmpty)
    }

    // MARK: AC8 — Doctor tax-pipeline row red/green threshold

    @Test
    func ac8_doctorTaxPipelineRowTurnsRedWhenLedgerHasUnmappedEntities() {
        let row = TaxPipelineDoctorRow(
            unclassifiedCostCount: 0,
            missingEntityMappingCount: 3,
            salesTaxAccruedSinceLastFilingUSD: 0,
            nextQuarterlyEstimateDeadline: nil,
            daysUntilNextDeadline: nil
        )
        let check = DoctorViewModel.taxPipelineDoctorRow(row: row)
        #expect(check.severity == .error)
        #expect(check.summary.contains("3 untagged"))
    }

    @Test
    func ac8_doctorTaxPipelineRowTurnsWarnWhenManyUnclassifiedCosts() {
        let row = TaxPipelineDoctorRow(
            unclassifiedCostCount: 4,
            missingEntityMappingCount: 0,
            salesTaxAccruedSinceLastFilingUSD: 0,
            nextQuarterlyEstimateDeadline: nil,
            daysUntilNextDeadline: nil
        )
        let check = DoctorViewModel.taxPipelineDoctorRow(row: row)
        #expect(check.severity == .warn)
    }

    @Test
    func ac8_doctorTaxPipelineRowGoesGreenWhenAllEntriesAreTaggedAndClassified() {
        let row = TaxPipelineDoctorRow(
            unclassifiedCostCount: 0,
            missingEntityMappingCount: 0,
            salesTaxAccruedSinceLastFilingUSD: 580.0,
            nextQuarterlyEstimateDeadline: "2026-04-15",
            daysUntilNextDeadline: 60
        )
        let check = DoctorViewModel.taxPipelineDoctorRow(row: row)
        #expect(check.severity == .ok)
        #expect(check.detail?.contains("US-CA") == false) // detail wording sanity
    }

    @Test
    func ac8_doctorTaxPipelineRowWarnsWhenDeadlineIsImminent() {
        let row = TaxPipelineDoctorRow(
            unclassifiedCostCount: 0,
            missingEntityMappingCount: 0,
            salesTaxAccruedSinceLastFilingUSD: 0,
            nextQuarterlyEstimateDeadline: "2026-04-15",
            daysUntilNextDeadline: 10
        )
        let check = DoctorViewModel.taxPipelineDoctorRow(row: row)
        #expect(check.severity == .warn)
        #expect(check.summary.contains("10"))
    }

    @Test
    func ac8_doctorTaxPipelineRowWarnsWhenRegistryIsEmpty() {
        let row = TaxPipelineDoctorRow(
            unclassifiedCostCount: 0,
            missingEntityMappingCount: 0,
            salesTaxAccruedSinceLastFilingUSD: 0,
            nextQuarterlyEstimateDeadline: nil,
            daysUntilNextDeadline: nil
        )
        let check = DoctorViewModel.taxPipelineDoctorRow(row: row, registryIsEmpty: true)
        #expect(check.severity == .warn)
        #expect(check.summary.contains("No tax entities"))
    }

    // MARK: AC9 — in-app per-entity-per-tax-year export action

    @MainActor
    @Test
    func ac9_oneClickExportProducesDocumentedBundleLayoutOnDisk() async throws {
        let entity = TaxEntity(
            id: "llc-acme",
            legalName: "Acme",
            entityType: .llcSingleMember,
            primaryJurisdiction: "US-FED",
            additionalJurisdictions: ["US-CA"]
        )
        let registry = TaxEntityRegistry(
            entities: [entity],
            companyToEntity: ["co-acme": "llc-acme"]
        )
        let vm = TaxViewModel(
            registry: registry,
            taxYear: 2026,
            fxRates: TaxFXRateTable(asOf: Date(), rates: [:])
        )
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("tax-export-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        let line = TaxLedgerLine(
            id: "rev-1",
            entityID: "llc-acme",
            occurredAt: makeDate(2026, 5, 1),
            kind: .revenue,
            category: .sales,
            amount: 1_000
        )
        let result = try vm.runExport(
            to: tmp,
            ledgerLines: [line],
            sourceLedgerCommitHash: "abcd1234",
            now: makeDate(2026, 6, 1)
        )
        #expect(result.bundleCount == 2)
        #expect(result.jurisdictions == ["US-CA", "US-FED"])
        // Per-jurisdiction sub-folder layout per docs/tax-export.md
        let fedDir = tmp.appendingPathComponent("llc-acme__US-FED__2026")
        let caDir = tmp.appendingPathComponent("llc-acme__US-CA__2026")
        #expect(FileManager.default.fileExists(atPath: fedDir.path))
        #expect(FileManager.default.fileExists(atPath: caDir.path))
        for name in ["pl.csv", "revenue_register.csv", "expense_register.csv", "manifest.json"] {
            #expect(FileManager.default.fileExists(atPath: fedDir.appendingPathComponent(name).path), "missing \(name) in US-FED bundle")
            #expect(FileManager.default.fileExists(atPath: caDir.appendingPathComponent(name).path), "missing \(name) in US-CA bundle")
        }
        // US-FED specific files
        #expect(FileManager.default.fileExists(atPath: fedDir.appendingPathComponent("irs_line_items.csv").path))
        #expect(FileManager.default.fileExists(atPath: fedDir.appendingPathComponent("1099_register.csv").path))
        #expect(FileManager.default.fileExists(atPath: fedDir.appendingPathComponent("quarterly_estimates.csv").path))
        // US-CA specific files
        #expect(FileManager.default.fileExists(atPath: caDir.appendingPathComponent("sales_tax_summary.csv").path))
    }

    @MainActor
    @Test
    func ac9_exportFailsCleanlyWhenNoEntitySelected() async {
        let vm = TaxViewModel(registry: TaxEntityRegistry())
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: tmp) }
        var threw = false
        do {
            _ = try vm.runExport(to: tmp, sourceLedgerCommitHash: "x")
        } catch {
            threw = true
        }
        #expect(threw == true)
    }

    @Test
    func ac9_bundleWriterIsAtomicAndProducesSortedFileList() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let bundle = try makeMinimalBundle(now: now)
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundle-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let output = try TaxExportBundleWriter.write(bundle, to: tmp)
        #expect(output.filePaths == output.filePaths.sorted())
        #expect(output.directory.lastPathComponent == "llc-acme__US-FED__2026")
    }

    // MARK: - Helpers

    private func makeDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        return calendar.date(from: DateComponents(year: y, month: m, day: d))!
    }

    private func makeMinimalBundle(now: Date) throws -> TaxExportBundle {
        let entity = TaxEntity(
            id: "llc-acme",
            legalName: "Acme",
            entityType: .llcSingleMember,
            primaryJurisdiction: "US-FED"
        )
        let request = TaxExportRequest(
            entity: entity,
            taxYear: 2026,
            ledgerLines: [],
            fxRates: TaxFXRateTable(asOf: now, rates: [:]),
            sourceLedgerCommitHash: "deadbeef",
            exportTimestamp: now
        )
        return try TaxExportPipeline.generate(request).first!
    }
}
