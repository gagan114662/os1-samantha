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
}
