import Foundation
import Testing
@testable import OS1

struct CompanyCRMTests {
    @Test
    func outboundTargetsRequireSourceConsentAndNoSuppression() {
        let eligible = contact(email: "buyer@example.com", consent: .explicitOptIn)
        let noConsent = contact(email: "noconsent@example.com", consent: .noConsent)
        let missingSource = contact(email: "nosource@example.com", source: "", consent: .explicitOptIn)
        let suppressed = contact(email: "optout@example.com", consent: .existingCustomer)
        let suppressions = [
            CompanySuppressionEntry(
                id: "suppression-1",
                email: "OPTOUT@example.com",
                reason: .unsubscribe,
                sourceCompanyID: "company-2",
                recordedAt: Date(timeIntervalSince1970: 1_800_000_000)
            )
        ]

        let targets = CompanyCRMEngine.eligibleOutboundTargets(
            contacts: [eligible, noConsent, missingSource, suppressed],
            suppressions: suppressions
        )

        #expect(targets.map(\.normalizedEmail) == ["buyer@example.com"])
    }

    @Test
    func deduplicationMergesLinksAndKeepsSourceAttribution() {
        let first = contact(
            email: "Buyer@Example.com",
            consent: .unknown,
            ledgerIDs: ["ledger-1"],
            supportIDs: ["ticket-1"],
            campaignIDs: ["campaign-1"]
        )
        let second = contact(
            email: "buyer@example.com",
            consent: .existingCustomer,
            ledgerIDs: ["ledger-2"],
            supportIDs: ["ticket-2"],
            campaignIDs: ["campaign-2"]
        )

        let merged = CompanyCRMEngine.deduplicate([first, second])

        #expect(merged.count == 1)
        #expect(merged[0].consentBasis == .existingCustomer)
        #expect(merged[0].linkedLedgerEntryIDs == ["ledger-1", "ledger-2"])
        #expect(merged[0].linkedSupportTicketIDs == ["ticket-1", "ticket-2"])
        #expect(merged[0].linkedCampaignEventIDs == ["campaign-1", "campaign-2"])
        #expect(merged[0].source.source == "web-form")
    }

    @Test
    func exportAndDeletionAreSupportedPerContact() {
        let account = CompanyCRMAccount(
            id: "account-1",
            companyID: "company-1",
            name: "Buyer Co",
            owner: "samantha",
            notes: "trial account"
        )
        let original = contact(email: "buyer@example.com", accountID: account.id, consent: .existingCustomer)
        let exported = CompanyCRMEngine.exportContact(
            id: original.id,
            contacts: [original],
            accounts: [account],
            exportedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let deleted = CompanyCRMEngine.deleted(original, at: Date(timeIntervalSince1970: 1_800_000_001))

        #expect(exported?.contact.id == original.id)
        #expect(exported?.account?.id == account.id)
        #expect(deleted.email.isEmpty)
        #expect(deleted.name.isEmpty)
        #expect(deleted.lifecycleStage == .deleted)
        #expect(deleted.deletedAt != nil)
    }

    private func contact(
        email: String,
        accountID: String? = nil,
        source: String = "web-form",
        consent: CompanyCRMContact.ConsentBasis,
        ledgerIDs: [String] = [],
        supportIDs: [String] = [],
        campaignIDs: [String] = []
    ) -> CompanyCRMContact {
        CompanyCRMContact(
            id: UUID().uuidString,
            companyID: "company-1",
            accountID: accountID,
            email: email,
            name: "Buyer",
            source: CompanyContactSource(
                source: source,
                capturedAt: Date(timeIntervalSince1970: 1_800_000_000),
                campaignID: campaignIDs.first,
                evidenceURL: URL(string: "https://example.com/source")
            ),
            consentBasis: consent,
            lifecycleStage: .lead,
            owner: "samantha",
            notes: "note",
            linkedLedgerEntryIDs: ledgerIDs,
            linkedSupportTicketIDs: supportIDs,
            linkedCampaignEventIDs: campaignIDs,
            deletedAt: nil
        )
    }
}
