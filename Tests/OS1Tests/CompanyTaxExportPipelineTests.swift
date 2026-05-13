import Foundation
import Testing
@testable import OS1

struct CompanyTaxExportPipelineTests {

    // MARK: - Helpers

    private static let exportTimestamp = Date(timeIntervalSince1970: 1_735_689_600) // 2025-01-01T00:00:00Z
    private static let frozenCommit = "deadbeef00112233445566778899aabbccddeeff"

    private static let fxRates = TaxFXRateTable(
        asOf: Date(timeIntervalSince1970: 1_704_067_200), // 2024-01-01
        rates: [
            "USD": 1.0,
            "EUR": 1.1,
            "GBP": 1.27,
            "CAD": 0.74,
            "JPY": 0.0066
        ]
    )

    private func entity(
        id: String = "llc-acme",
        type: TaxEntityType = .llcSingleMember,
        primary: String = "US-FED",
        additional: [String] = [],
        allocation: TaxJurisdictionAllocation = .primaryOnly,
        incorporatedAt: Date? = nil,
        dissolvedAt: Date? = nil
    ) -> TaxEntity {
        TaxEntity(
            id: id,
            legalName: "Acme Holdings LLC",
            entityType: type,
            primaryJurisdiction: primary,
            additionalJurisdictions: additional,
            ein: "12-3456789",
            fiscalYearStartMonth: 1,
            incorporatedAt: incorporatedAt,
            dissolvedAt: dissolvedAt,
            allocation: allocation
        )
    }

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(identifier: "UTC")
        return Calendar(identifier: .gregorian).date(from: components)!
    }

    private func line(
        _ id: String,
        entity: String = "llc-acme",
        date occurredAt: Date,
        kind: CompanyLedgerEntry.Kind,
        category: CompanyLedgerEntry.Category? = nil,
        amount: Double,
        currency: String = "USD",
        jurisdiction: String? = nil
    ) -> TaxLedgerLine {
        TaxLedgerLine(
            id: id,
            entityID: entity,
            occurredAt: occurredAt,
            kind: kind,
            category: category,
            amount: amount,
            currency: currency,
            jurisdiction: jurisdiction,
            memo: id
        )
    }

    private func request(
        entity: TaxEntity,
        taxYear: Int = 2025,
        lines: [TaxLedgerLine] = [],
        contractors: [TaxContractorPayment] = [],
        jurisdictionsOverride: [String] = []
    ) -> TaxExportRequest {
        TaxExportRequest(
            entity: entity,
            taxYear: taxYear,
            ledgerLines: lines,
            providerEvents: [],
            contractorPayments: contractors,
            fxRates: Self.fxRates,
            sourceLedgerCommitHash: Self.frozenCommit,
            exportTimestamp: Self.exportTimestamp,
            jurisdictionsOverride: jurisdictionsOverride
        )
    }

    private func plLines(in bundle: TaxExportBundle) -> [String] {
        guard let pl = bundle.files.first(where: { $0.path == "pl.csv" }) else { return [] }
        return pl.stringContent.split(separator: "\n").map(String.init)
    }

    // MARK: - Determinism

    @Test
    func sameInputsProduceByteIdenticalOutput() throws {
        let req = request(
            entity: entity(),
            lines: [
                line("rev-a", date: date(2025, 3, 1), kind: .revenue, category: .sales, amount: 1_000),
                line("cost-a", date: date(2025, 3, 2), kind: .cost, category: .cloudCompute, amount: 100)
            ]
        )
        let firstRun = try TaxExportPipeline.generate(req)
        let secondRun = try TaxExportPipeline.generate(req)

        #expect(firstRun.count == secondRun.count)
        for (lhs, rhs) in zip(firstRun, secondRun) {
            #expect(lhs.files.count == rhs.files.count)
            for (a, b) in zip(lhs.files, rhs.files) {
                #expect(a.path == b.path)
                #expect(a.bytes == b.bytes)
                #expect(a.sha256Hex == b.sha256Hex)
            }
            #expect(lhs.manifest.totalsChecksum == rhs.manifest.totalsChecksum)
        }
    }

    // MARK: - Manifest

    @Test
    func manifestEmbedsCommitHashTimestampJurisdictionEntityChecksum() throws {
        let req = request(
            entity: entity(),
            lines: [line("rev-1", date: date(2025, 5, 5), kind: .revenue, category: .sales, amount: 250)]
        )
        let bundles = try TaxExportPipeline.generate(req)
        let bundle = try #require(bundles.first)

        #expect(bundle.manifest.sourceLedgerCommitHash == Self.frozenCommit)
        #expect(bundle.manifest.exportedAt == Self.exportTimestamp)
        #expect(bundle.manifest.jurisdiction == "US-FED")
        #expect(bundle.manifest.entityID == "llc-acme")
        #expect(bundle.manifest.taxYear == 2025)
        #expect(bundle.manifest.totalsChecksum.count == 64)
        #expect(bundle.manifest.totals.revenueUSD == 250.0)

        let manifestFile = try #require(bundle.files.first(where: { $0.path == "manifest.json" }))
        let payload = try JSONSerialization.jsonObject(with: manifestFile.bytes) as? [String: Any]
        #expect(payload?["sourceLedgerCommitHash"] as? String == Self.frozenCommit)
        #expect(payload?["jurisdiction"] as? String == "US-FED")
        #expect((payload?["files"] as? [[String: Any]])?.isEmpty == false)
    }

    // MARK: - Empty ledger

    @Test
    func emptyLedgerProducesEmptyExportWithZeroTotals() throws {
        let bundles = try TaxExportPipeline.generate(request(entity: entity(), lines: []))
        let bundle = try #require(bundles.first)
        #expect(bundle.manifest.totals.revenueUSD == 0)
        #expect(bundle.manifest.totals.costUSD == 0)
        #expect(bundle.manifest.totals.netUSD == 0)
        #expect(bundle.manifest.totals.lineCount == 0)
        #expect(bundle.manifest.notes.contains { $0.contains("Zero ledger activity") })
        // pl.csv still emits header + 4 lines (revenue, refunds, costs, net)
        #expect(plLines(in: bundle).count == 5)
    }

    // MARK: - Single entity, single jurisdiction

    @Test
    func singleEntitySingleJurisdictionAggregatesRevenueAndCosts() throws {
        let req = request(
            entity: entity(),
            lines: [
                line("rev-1", date: date(2025, 2, 1), kind: .revenue, category: .sales, amount: 1_200),
                line("rev-2", date: date(2025, 4, 1), kind: .revenue, category: .subscription, amount: 300),
                line("ref-1", date: date(2025, 4, 5), kind: .refund, category: .refund, amount: 50),
                line("cost-1", date: date(2025, 4, 6), kind: .cost, category: .cloudCompute, amount: 200),
                line("cost-2", date: date(2025, 5, 7), kind: .cost, category: .ads, amount: 100)
            ]
        )
        let bundles = try TaxExportPipeline.generate(req)
        let bundle = try #require(bundles.first)
        #expect(bundles.count == 1)
        #expect(bundle.manifest.totals.revenueUSD == 1_500)
        #expect(bundle.manifest.totals.refundsUSD == 50)
        #expect(bundle.manifest.totals.costUSD == 300)
        #expect(bundle.manifest.totals.netUSD == 1_150)
    }

    // MARK: - Multi-entity, single jurisdiction

    @Test
    func multiEntitySingleJurisdictionScopedToRequestedEntity() throws {
        let acme = entity(id: "llc-acme")
        let beta = entity(id: "llc-beta")
        let lines: [TaxLedgerLine] = [
            line("a-rev", entity: "llc-acme", date: date(2025, 3, 1), kind: .revenue, category: .sales, amount: 800),
            line("b-rev", entity: "llc-beta", date: date(2025, 3, 1), kind: .revenue, category: .sales, amount: 600),
            line("a-cost", entity: "llc-acme", date: date(2025, 3, 2), kind: .cost, category: .ads, amount: 100)
        ]
        let acmeBundle = try #require(try TaxExportPipeline.generate(request(entity: acme, lines: lines)).first)
        let betaBundle = try #require(try TaxExportPipeline.generate(request(entity: beta, lines: lines)).first)
        #expect(acmeBundle.manifest.totals.revenueUSD == 800)
        #expect(acmeBundle.manifest.totals.costUSD == 100)
        #expect(betaBundle.manifest.totals.revenueUSD == 600)
        #expect(betaBundle.manifest.totals.costUSD == 0)
        // Different entities must produce different checksums.
        #expect(acmeBundle.manifest.totalsChecksum != betaBundle.manifest.totalsChecksum)
    }

    // MARK: - Single entity, multi-jurisdiction

    @Test
    func singleEntityMultiJurisdictionEqualSplitDividesLines() throws {
        let entity = entity(
            primary: "US-FED",
            additional: ["US-CA"],
            allocation: .equalSplit
        )
        let req = request(
            entity: entity,
            lines: [
                line("rev-1", date: date(2025, 5, 1), kind: .revenue, category: .sales, amount: 1_000),
                line("cost-1", date: date(2025, 5, 2), kind: .cost, category: .ads, amount: 400)
            ]
        )
        let bundles = try TaxExportPipeline.generate(req)
        #expect(bundles.count == 2)
        let bundlesByJurisdiction = Dictionary(uniqueKeysWithValues: bundles.map { ($0.jurisdiction, $0) })
        let fed = try #require(bundlesByJurisdiction["US-FED"])
        let ca = try #require(bundlesByJurisdiction["US-CA"])
        #expect(fed.manifest.totals.revenueUSD == 500)
        #expect(fed.manifest.totals.costUSD == 200)
        #expect(ca.manifest.totals.revenueUSD == 500)
        #expect(ca.manifest.totals.costUSD == 200)
    }

    @Test
    func revenueProportionalAllocationRespectsWeights() throws {
        let entity = entity(
            primary: "US-FED",
            additional: ["US-CA"],
            allocation: .revenueProportional(weights: ["US-FED": 0.75, "US-CA": 0.25])
        )
        let req = request(
            entity: entity,
            lines: [line("rev-1", date: date(2025, 6, 1), kind: .revenue, category: .sales, amount: 1_000)]
        )
        let bundles = try TaxExportPipeline.generate(req)
        let map = Dictionary(uniqueKeysWithValues: bundles.map { ($0.jurisdiction, $0) })
        #expect(map["US-FED"]?.manifest.totals.revenueUSD == 750)
        #expect(map["US-CA"]?.manifest.totals.revenueUSD == 250)
    }

    @Test
    func pinnedJurisdictionLinesIgnoreAllocationRule() throws {
        let entity = entity(
            primary: "US-FED",
            additional: ["US-CA"],
            allocation: .equalSplit
        )
        let req = request(
            entity: entity,
            lines: [
                line("ca-only", date: date(2025, 4, 4), kind: .revenue, category: .sales, amount: 500, jurisdiction: "US-CA")
            ]
        )
        let bundles = try TaxExportPipeline.generate(req)
        let map = Dictionary(uniqueKeysWithValues: bundles.map { ($0.jurisdiction, $0) })
        #expect(map["US-FED"]?.manifest.totals.revenueUSD == 0)
        #expect(map["US-CA"]?.manifest.totals.revenueUSD == 500)
    }

    // MARK: - FY-aware quarterly deadlines

    @Test
    func quarterlyDeadlinesShiftWithFiscalYearStartMonth() throws {
        let calendarYear = entity()
        let calendarDeadlines = TaxExportPipeline.quarterlyDeadlines(taxYear: 2025, entity: calendarYear)
        #expect(calendarDeadlines == ["2025-04-15", "2025-06-15", "2025-09-15", "2026-01-15"])

        let julyFY = TaxEntity(
            id: "fy-jul",
            legalName: "July FY Co",
            entityType: .cCorp,
            primaryJurisdiction: "US-FED",
            fiscalYearStartMonth: 7
        )
        let julyDeadlines = TaxExportPipeline.quarterlyDeadlines(taxYear: 2025, entity: julyFY)
        #expect(julyDeadlines == ["2025-10-15", "2025-12-15", "2026-03-15", "2026-07-15"])

        let aprilFY = TaxEntity(
            id: "fy-apr",
            legalName: "April FY Co",
            entityType: .cCorp,
            primaryJurisdiction: "US-FED",
            fiscalYearStartMonth: 4
        )
        let aprilDeadlines = TaxExportPipeline.quarterlyDeadlines(taxYear: 2025, entity: aprilFY)
        #expect(aprilDeadlines == ["2025-07-15", "2025-09-15", "2025-12-15", "2026-04-15"])
    }

    // MARK: - Duplicate jurisdiction override

    @Test
    func duplicateJurisdictionOverrideIsDedupedNotCrashed() throws {
        let req = request(
            entity: entity(),
            lines: [line("rev-1", date: date(2025, 5, 5), kind: .revenue, category: .sales, amount: 100)],
            jurisdictionsOverride: ["US-FED", "US-FED", "US-CA", "US-CA"]
        )
        let bundles = try TaxExportPipeline.generate(req)
        let codes = bundles.map(\.jurisdiction).sorted()
        #expect(codes == ["US-CA", "US-FED"])
    }

    // MARK: - Mixed currencies w/ FX fixture

    @Test
    func mixedCurrenciesNormalizeToUSDViaFrozenFXTable() throws {
        let entity = entity()
        let req = request(
            entity: entity,
            lines: [
                line("rev-eur", date: date(2025, 2, 2), kind: .revenue, category: .sales, amount: 1_000, currency: "EUR"),
                line("rev-jpy", date: date(2025, 2, 3), kind: .revenue, category: .sales, amount: 100_000, currency: "JPY"),
                line("rev-cad", date: date(2025, 2, 4), kind: .revenue, category: .sales, amount: 500, currency: "CAD")
            ]
        )
        let bundle = try #require(try TaxExportPipeline.generate(req).first)
        // 1000 EUR * 1.1 + 100000 JPY * 0.0066 + 500 CAD * 0.74 = 1100 + 660 + 370 = 2130
        #expect(bundle.manifest.totals.revenueUSD == 2_130)
    }

    @Test
    func unknownCurrencyThrowsClearError() {
        let req = request(
            entity: entity(),
            lines: [line("rev-x", date: date(2025, 2, 1), kind: .revenue, category: .sales, amount: 1, currency: "XYZ")]
        )
        #expect(throws: TaxExportError.self) {
            _ = try TaxExportPipeline.generate(req)
        }
    }

    // MARK: - Mid-year incorporation prorating

    @Test
    func midYearIncorporationProratesQuarterlyEstimates() throws {
        // Incorporated 2025-07-01: ~184/365 active days → fraction ~0.504
        let entity = entity(incorporatedAt: date(2025, 7, 1))
        let req = request(
            entity: entity,
            lines: [
                line("rev-q3", date: date(2025, 8, 1), kind: .revenue, category: .sales, amount: 10_000)
            ]
        )
        let bundle = try #require(try TaxExportPipeline.generate(req).first)
        let estimatesFile = try #require(bundle.files.first(where: { $0.path == "quarterly_estimates.csv" }))
        let csv = estimatesFile.stringContent
        // Net revenue 10_000, federal rate 0.22, active fraction ≈ 0.504
        // Full-year tax would be 2200; prorated ≈ 1108.49; per-quarter ≈ 277.12
        // Check that the per-quarter amount is materially smaller than full-year/4 (550)
        let firstQuarterLine = csv.split(separator: "\n").first { $0.hasPrefix("Q1,") }
        let amount = firstQuarterLine.flatMap { $0.split(separator: ",")[safe: 2] }.flatMap { Double(String($0)) } ?? 0
        #expect(amount > 0)
        #expect(amount < 350)  // strictly less than the un-prorated 550
        #expect(bundle.manifest.notes.contains { $0.contains("Active-day fraction") })
    }

    @Test
    func entriesBeforeIncorporationAreDroppedFromExport() throws {
        let entity = entity(incorporatedAt: date(2025, 6, 1))
        let req = request(
            entity: entity,
            lines: [
                line("pre", date: date(2025, 2, 1), kind: .revenue, category: .sales, amount: 5_000),
                line("post", date: date(2025, 8, 1), kind: .revenue, category: .sales, amount: 1_000)
            ]
        )
        let bundle = try #require(try TaxExportPipeline.generate(req).first)
        #expect(bundle.manifest.totals.revenueUSD == 1_000)
    }

    // MARK: - 1099-NEC

    @Test
    func contractor1099RegisterEmitsRecipientsAboveThreshold() throws {
        let entity = entity()
        let req = request(
            entity: entity,
            lines: [line("rev-1", date: date(2025, 6, 1), kind: .revenue, category: .sales, amount: 5_000)],
            contractors: [
                TaxContractorPayment(id: "p1", payerEntityID: entity.id, recipientName: "Alpha", recipientTaxID: "xxx-xx-1234", recipientCountry: "US", amountUSD: 700, isUSResident: true),
                TaxContractorPayment(id: "p2", payerEntityID: entity.id, recipientName: "Bravo", recipientTaxID: "xxx-xx-5678", recipientCountry: "US", amountUSD: 400, isUSResident: true),
                TaxContractorPayment(id: "p3", payerEntityID: entity.id, recipientName: "Zulu Intl", recipientTaxID: nil, recipientCountry: "GB", amountUSD: 1_200, isUSResident: false)
            ]
        )
        let bundle = try #require(try TaxExportPipeline.generate(req).first)
        let registerFile = try #require(bundle.files.first(where: { $0.path == "1099_register.csv" }))
        let csv = registerFile.stringContent
        #expect(csv.contains("Alpha"))
        #expect(csv.contains("Zulu Intl"))
        #expect(!csv.contains("Bravo"))  // below $600 threshold
        #expect(csv.contains("1042-S"))  // foreign withholding form
    }

    // MARK: - CA jurisdiction

    @Test
    func californiaBundleIncludesSalesTaxSummary() throws {
        let entity = entity(
            primary: "US-CA",
            allocation: .primaryOnly
        )
        let req = request(
            entity: entity,
            lines: [
                line("ca-rev", date: date(2025, 5, 1), kind: .revenue, category: .sales, amount: 10_000)
            ]
        )
        let bundle = try #require(try TaxExportPipeline.generate(req).first)
        let stFile = try #require(bundle.files.first(where: { $0.path == "sales_tax_summary.csv" }))
        let csv = stFile.stringContent
        #expect(csv.contains("US-CA"))
        #expect(csv.contains("0.0725"))
        #expect(csv.contains("725.00"))  // 10000 * 0.0725
    }

    // MARK: - Non-US generic

    @Test
    func nonUSJurisdictionProducesGenericExportFiles() throws {
        let entity = entity(
            primary: "DE",
            allocation: .primaryOnly
        )
        let req = request(
            entity: entity,
            lines: [
                line("de-rev", date: date(2025, 4, 1), kind: .revenue, category: .sales, amount: 1_000, currency: "EUR")
            ]
        )
        let bundle = try #require(try TaxExportPipeline.generate(req).first)
        #expect(bundle.jurisdiction == "DE")
        #expect(bundle.files.contains { $0.path == "pl.csv" })
        #expect(bundle.files.contains { $0.path == "manifest.json" })
        // Non-US bundles do not include US-specific 1099/quarterly files.
        #expect(!bundle.files.contains { $0.path == "1099_register.csv" })
        #expect(!bundle.files.contains { $0.path == "quarterly_estimates.csv" })
    }

    // MARK: - Doctor row

    @Test
    func doctorRowAccruesCaliforniaSalesTaxSinceFilingStart() {
        let entity = entity(primary: "US-CA")
        let registry = TaxEntityRegistry(
            entities: [entity],
            companyToEntity: ["co-acme": entity.id]
        )
        let caLines: [TaxLedgerLine] = [
            line("ca-q1", date: date(2026, 2, 1), kind: .revenue, category: .sales, amount: 5_000, jurisdiction: "US-CA"),
            line("ca-q2", date: date(2026, 4, 1), kind: .revenue, category: .sales, amount: 3_000, jurisdiction: "US-CA"),
            line("non-ca", date: date(2026, 4, 1), kind: .revenue, category: .sales, amount: 10_000, jurisdiction: "US-FED"),
            line("ca-future", date: date(2027, 1, 1), kind: .revenue, category: .sales, amount: 9_999, jurisdiction: "US-CA")
        ]
        let row = TaxPipelineDoctorRow.compute(
            ledger: [],
            registry: registry,
            now: date(2026, 5, 1),
            taxLedgerLines: caLines
        )
        // CA-pinned revenue YTD = 8_000 × 0.0725 = 580.00
        #expect(row.salesTaxAccruedSinceLastFilingUSD == 580.0)
    }

    @Test
    func doctorRowSurfacesUnclassifiedAndMissingMappingCounts() {
        let registry = TaxEntityRegistry(
            entities: [entity()],
            companyToEntity: ["co-acme": "llc-acme"]
        )
        let entries: [CompanyLedgerEntry] = [
            CompanyLedgerEntry(
                id: "ok",
                companyID: "co-acme",
                occurredAt: date(2025, 3, 1),
                kind: .revenue,
                category: .sales,
                amountUSD: 100,
                source: "stripe",
                confidence: .verified,
                note: "ok"
            ),
            CompanyLedgerEntry(
                id: "unclassified",
                companyID: "co-acme",
                occurredAt: date(2025, 3, 1),
                kind: .cost,
                category: .other,
                amountUSD: 25,
                source: "manual",
                confidence: .manual,
                note: "uncategorized"
            ),
            CompanyLedgerEntry(
                id: "orphan",
                companyID: "co-mystery",
                occurredAt: date(2025, 3, 1),
                kind: .cost,
                category: .ads,
                amountUSD: 10,
                source: "manual",
                confidence: .manual,
                note: "no entity"
            )
        ]
        let row = TaxPipelineDoctorRow.compute(
            ledger: entries,
            registry: registry,
            now: date(2025, 3, 15)
        )
        #expect(row.unclassifiedCostCount == 1)
        #expect(row.missingEntityMappingCount == 1)
        #expect(row.nextQuarterlyEstimateDeadline == "2025-04-15")
        #expect((row.daysUntilNextDeadline ?? -1) > 0)
    }

    // MARK: - Registry codable

    @Test
    func entityRegistryRoundTripsThroughJSON() throws {
        let registry = TaxEntityRegistry(
            entities: [
                entity(),
                entity(id: "operator-personal", type: .soleProprietor, primary: "US-FED")
            ],
            companyToEntity: ["co-1": "llc-acme", "co-2": "operator-personal"]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(registry)
        let decoded = try JSONDecoder().decode(TaxEntityRegistry.self, from: data)
        #expect(decoded.entities.count == 2)
        #expect(decoded.entity(forCompany: "co-1")?.id == "llc-acme")
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
