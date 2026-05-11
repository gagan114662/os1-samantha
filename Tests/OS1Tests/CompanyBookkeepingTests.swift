import Foundation
import Testing
@testable import OS1

struct CompanyBookkeepingTests {
    @Test
    func monthlyCompanyReportExportsLedgerRowsForAccountingAndQBO() {
        let report = CompanyBookkeepingEngine.monthlyCompanyReport(
            companyID: "co-1",
            month: .init(year: 2026, month: 5),
            ledger: CompanyLedgerSummary(entries: [
                entry(
                    id: "charge",
                    kind: .revenue,
                    category: .sales,
                    amountUSD: 120,
                    reference: "checkout=cs_1"
                ),
                entry(
                    id: "fee",
                    kind: .cost,
                    category: .paymentFees,
                    amountUSD: 4.20,
                    reference: "fee=fee_1"
                )
            ]),
            providerEvents: [],
            accountingProfile: completeProfile()
        )

        let csv = CompanyBookkeepingExporter.monthlyCSV(report)
        let qbo = CompanyBookkeepingExporter.qboCSV(report)

        #expect(csv.contains("2026-05,co-1,2026-05-11,revenue,salesRevenue,120.00"))
        #expect(csv.contains("2026-05,co-1,2026-05-11,cost,paymentProcessingFees,-4.20"))
        #expect(qbo.contains("Sales"))
        #expect(qbo.contains("Merchant Fees"))
    }

    @Test
    func providerTotalsReconcileToLedgerTotals() {
        let report = CompanyBookkeepingEngine.monthlyCompanyReport(
            companyID: "co-1",
            month: .init(year: 2026, month: 5),
            ledger: CompanyLedgerSummary(entries: [
                entry(
                    id: "charge",
                    kind: .revenue,
                    category: .sales,
                    amountUSD: 120,
                    reference: "cs_1"
                ),
                entry(
                    id: "refund",
                    kind: .refund,
                    category: .refund,
                    amountUSD: 20,
                    reference: "re_1"
                )
            ]),
            providerEvents: [
                provider(id: "stripe-charge", kind: .charge, amountUSD: 120, reference: "cs_1"),
                provider(id: "stripe-refund", kind: .refund, amountUSD: 20, reference: "re_1")
            ],
            accountingProfile: completeProfile()
        )

        #expect(report.providerTotalsUSD[.charge] == 120)
        #expect(report.providerTotalsUSD[.refund] == 20)
        #expect(report.ledgerTotalsUSD[.revenue] == 120)
        #expect(report.ledgerTotalsUSD[.refund] == 20)
        #expect(report.isReconciled)
        #expect(report.reconciliationLines.allSatisfy { $0.status == .matched })
    }

    @Test
    func unreconciledAndManualOverrideEntriesAreVisible() {
        let report = CompanyBookkeepingEngine.monthlyCompanyReport(
            companyID: "co-1",
            month: .init(year: 2026, month: 5),
            ledger: CompanyLedgerSummary(entries: [
                entry(
                    id: "manual-override",
                    kind: .revenue,
                    category: .sales,
                    amountUSD: 75,
                    confidence: .manualOverride,
                    reference: "bank-deposit-1"
                ),
                entry(
                    id: "missing-provider",
                    kind: .cost,
                    category: .ads,
                    amountUSD: 15,
                    reference: "ad-receipt-1"
                )
            ]),
            providerEvents: [
                provider(id: "stripe-charge", kind: .charge, amountUSD: 75, reference: "bank-deposit-1"),
                provider(id: "stripe-fee", kind: .fee, amountUSD: 2, reference: "fee_1")
            ],
            accountingProfile: completeProfile()
        )

        #expect(report.manualOverrideEntries.map(\.id) == ["manual-override"])
        #expect(report.reconciliationLines.contains { $0.status == .manualOverride })
        #expect(report.reconciliationLines.contains { $0.status == .missingLedgerEntry })
        #expect(report.unreconciledEntries.map(\.id) == ["missing-provider"])
        #expect(!report.isReconciled)
    }

    @Test
    func paidCompaniesRequireTaxAndAccountingMetadata() {
        let missingProfileReport = CompanyBookkeepingEngine.monthlyCompanyReport(
            companyID: "co-1",
            month: .init(year: 2026, month: 5),
            ledger: CompanyLedgerSummary(entries: [
                entry(id: "charge", kind: .revenue, category: .sales, amountUSD: 25, reference: "cs_1")
            ]),
            providerEvents: []
        )
        let incompleteProfileReport = CompanyBookkeepingEngine.monthlyCompanyReport(
            companyID: "co-1",
            month: .init(year: 2026, month: 5),
            ledger: CompanyLedgerSummary(entries: [
                entry(id: "charge", kind: .revenue, category: .sales, amountUSD: 25, reference: "cs_1")
            ]),
            providerEvents: [],
            accountingProfile: CompanyAccountingProfile(
                companyID: "co-1",
                legalName: "",
                entityType: "LLC",
                taxCountry: "US",
                taxRegion: "DE",
                currency: "USD",
                taxIdentifierLast4: nil,
                vendorTaxForms: [vendorForm(status: .missing)]
            )
        )

        #expect(missingProfileReport.missingPaidCompanyMetadata == ["accountingProfile"])
        #expect(incompleteProfileReport.missingPaidCompanyMetadata.contains("legalName"))
        #expect(incompleteProfileReport.missingPaidCompanyMetadata.contains("vendorTaxForms"))
    }

    @Test
    func portfolioReportAggregatesMonthlyCompanies() {
        let may = CompanyAccountingMonth(year: 2026, month: 5)
        let first = CompanyBookkeepingEngine.monthlyCompanyReport(
            companyID: "co-1",
            month: may,
            ledger: CompanyLedgerSummary(entries: [
                entry(id: "co1", kind: .revenue, category: .sales, amountUSD: 100, reference: "cs_1")
            ]),
            providerEvents: [],
            accountingProfile: completeProfile(companyID: "co-1")
        )
        let second = CompanyBookkeepingEngine.monthlyCompanyReport(
            companyID: "co-2",
            month: may,
            ledger: CompanyLedgerSummary(entries: [
                entry(id: "co2", companyID: "co-2", kind: .cost, category: .tools, amountUSD: 10, reference: "r_1")
            ]),
            providerEvents: []
        )

        let portfolio = CompanyBookkeepingEngine.portfolioReport(month: may, reports: [second, first])
        let csv = CompanyBookkeepingExporter.portfolioCSV(portfolio)

        #expect(portfolio.ledgerSummary.revenueUSD == 100)
        #expect(portfolio.ledgerSummary.costUSD == 10)
        #expect(portfolio.missingMetadataCompanyIDs == ["co-2"])
        #expect(csv.contains("2026-05,co-1,100.00,0.00,0.00,100.00"))
        #expect(csv.contains("2026-05,co-2,0.00,0.00,10.00,-10.00"))
    }

    private func entry(
        id: String,
        companyID: String = "co-1",
        kind: CompanyLedgerEntry.Kind,
        category: CompanyLedgerEntry.Category,
        amountUSD: Double,
        confidence: CompanyLedgerEntry.Confidence = .verified,
        reference: String
    ) -> CompanyLedgerEntry {
        CompanyLedgerEntry(
            id: id,
            companyID: companyID,
            occurredAt: Date(timeIntervalSince1970: 1_778_515_200),
            kind: kind,
            category: category,
            amountUSD: amountUSD,
            source: "stripe",
            sourceReference: reference,
            confidence: confidence,
            note: reference
        )
    }

    private func provider(
        id: String,
        kind: CompanyPaymentProviderEvent.Kind,
        amountUSD: Double,
        reference: String
    ) -> CompanyPaymentProviderEvent {
        CompanyPaymentProviderEvent(
            id: id,
            companyID: "co-1",
            occurredAt: Date(timeIntervalSince1970: 1_778_515_200),
            provider: "stripe",
            kind: kind,
            amountUSD: amountUSD,
            sourceReference: reference
        )
    }

    private func completeProfile(companyID: String = "co-1") -> CompanyAccountingProfile {
        CompanyAccountingProfile(
            companyID: companyID,
            legalName: "OS1 Test LLC",
            entityType: "LLC",
            taxCountry: "US",
            taxRegion: "DE",
            currency: "USD",
            taxIdentifierLast4: "1234",
            vendorTaxForms: [vendorForm(status: .received)]
        )
    }

    private func vendorForm(status: CompanyVendorTaxForm.Status) -> CompanyVendorTaxForm {
        CompanyVendorTaxForm(
            id: "w9-1",
            vendorName: "Contractor",
            formType: "W-9",
            taxYear: 2026,
            amountPaidUSD: 650,
            status: status,
            reference: "drive://w9"
        )
    }
}
