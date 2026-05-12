import Foundation
import Testing
@testable import OS1

struct PaymentsEndToEndSmokeTests {
    @Test
    func threeTemplatePaymentsProduceVerifiedLedgerEntries() throws {
        let stripe = try stripeLedger(companyID: "micro-saas-\(UUID().uuidString)")
        let gumroad = try gumroadLedger(companyID: "course-\(UUID().uuidString)")
        let etsy = try etsyLedger(companyID: "printable-\(UUID().uuidString)")

        #expect(stripe.category == .sales)
        #expect(stripe.amountUSD == 29)
        #expect(stripe.source == "stripe")
        #expect(stripe.sourceReference == "pi_smoke")

        #expect(gumroad.category == .sales)
        #expect(gumroad.amountUSD == 49)
        #expect(gumroad.source == "gumroad")
        #expect(gumroad.sourceReference == "sale_smoke")

        #expect(etsy.category == .sales)
        #expect(etsy.amountUSD == 12.50)
        #expect(etsy.source == "etsy")
        #expect(etsy.sourceReference == "E-SMOKE")
    }

    private func stripeLedger(companyID: String) throws -> CompanyLedgerEntry {
        CompanyAccessControl.grantCapabilities([.payments], companyID: companyID)
        let payload = Data(#"{"id":"evt_smoke","type":"checkout.session.completed","amount_total":2900,"currency":"usd","payment_intent":"pi_smoke","metadata":{"company_id":"\#(companyID)","utm_campaign":"\#(companyID)","utm_content":"micro-saas"}}"#.utf8)
        let timestamp = 1_800_000_000
        let header = PaymentWebhookReceiver.stripeSignatureHeader(
            payload: payload,
            timestamp: timestamp,
            endpointSecret: "whsec_smoke"
        )
        let event = try PaymentWebhookReceiver.verifiedStripe(
            companyID: companyID,
            payload: payload,
            signatureHeader: header,
            endpointSecret: "whsec_smoke",
            seenEventIDs: [],
            now: Date(timeIntervalSince1970: TimeInterval(timestamp + 10))
        )
        return PaymentWebhookReceiver.ledgerEntry(for: event)
    }

    private func gumroadLedger(companyID: String) throws -> CompanyLedgerEntry {
        CompanyAccessControl.grantCapabilities([.payments], companyID: companyID)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gumroad-smoke-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        let payload = Data(#"{"id":"sale_smoke","price_cents":4900,"currency":"usd","product_id":"course-smoke","product_name":"Course"}"#.utf8)
        let signature = PaymentWebhookReceiver.gumroadSignatureHeader(payload: payload, applicationSecret: "gumroad_smoke")
        let event = try PaymentWebhookReceiver.verifiedGumroad(
            companyID: companyID,
            payload: payload,
            signatureHeader: signature,
            applicationSecret: "gumroad_smoke",
            seenEventStore: PaymentWebhookSeenEventStore(url: url),
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        return PaymentWebhookReceiver.ledgerEntry(for: event)
    }

    private func etsyLedger(companyID: String) throws -> CompanyLedgerEntry {
        let csv = """
        Order ID,Date,Item Total,Currency,SKU
        E-SMOKE,2026-05-01,12.50,USD,printable-smoke
        """
        let event = try #require(EtsyCSVIngest.ingest(csv: csv, companyID: companyID).first)
        return PaymentWebhookReceiver.ledgerEntry(for: event)
    }
}
