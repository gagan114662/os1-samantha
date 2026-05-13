import Foundation
import Testing
@testable import OS1

struct PaymentsHealthCardTests {
    @Test
    @MainActor
    func paymentsHealthCardRendersFixtureRows() {
        let snapshot = PaymentsHealthSnapshot.fixture(rows: [
            .init(provider: "Stripe", endpoint: "/webhooks/stripe", lastEvent: "evt_1", reconciliation: "balanced", replayStoreSize: 2),
            .init(provider: "Gumroad", endpoint: "/webhooks/gumroad", lastEvent: "sale_1", reconciliation: "balanced", replayStoreSize: 1)
        ])

        let rows = PaymentsHealthCard.renderedRows(snapshot: snapshot)

        #expect(rows == [
            "Stripe|/webhooks/stripe|evt_1|balanced|2",
            "Gumroad|/webhooks/gumroad|sale_1|balanced|1"
        ])
        #expect(DoctorViewModel.paymentsHealthSnapshot(replayStoreSize: 3).rows.first?.replayStoreSize == 3)
    }

    @Test
    @MainActor
    func paymentsHealthSnapshotReportsLatestProviderEventTimestamp() {
        let older = CompanyEvent(
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            companyID: "co",
            kind: .ledgerEntryRecorded,
            summary: "Verified stripe payment ledger entry recorded",
            metadata: ["provider": "stripe", "eventID": "evt_old"]
        )
        let newer = CompanyEvent(
            occurredAt: Date(timeIntervalSince1970: 1_800_000_060),
            companyID: "co",
            kind: .ledgerEntryRecorded,
            summary: "Verified stripe payment ledger entry recorded",
            metadata: ["provider": "stripe", "eventID": "evt_new"]
        )

        let snapshot = DoctorViewModel.paymentsHealthSnapshot(recentEvents: [older, newer])

        #expect(snapshot.rows.first?.lastEvent.contains("evt_new @") == true)
    }
}
