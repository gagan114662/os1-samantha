import Foundation
import Testing
@testable import OS1

@MainActor
struct RealtimeStripeWebhookEndpointTests {
    @Test
    func stripeWebhookRouteRecordsVerifiedLedgerEntry() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("stripe-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("co", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "[]".write(to: worktree.appendingPathComponent("LEDGER.json"), atomically: true, encoding: .utf8)

        let manager = CodexSessionManager(testRoot: root)
        manager.replaceSessionsForTesting([
            CodexSession(
                id: "co",
                title: "co",
                task: "sell",
                worktreePath: worktree.path,
                branch: "company/co",
                status: .idle,
                startedAt: Date(timeIntervalSince1970: 1)
            )
        ])
        CompanyAccessControl.grantCapabilities([.payments], companyID: "co")

        let payload = Data(#"{"id":"evt_route","type":"checkout.session.completed","data":{"object":{"id":"cs_route","amount_total":4200,"currency":"usd","payment_intent":"pi_route","metadata":{"company_id":"co","utm_campaign":"co","utm_content":"post-route"}}}}"#.utf8)
        let timestamp = 1_800_000_000
        let signature = PaymentWebhookReceiver.stripeSignatureHeader(
            payload: payload,
            timestamp: timestamp,
            endpointSecret: "whsec_route"
        )
        let request = try Self.request(path: "/webhooks/stripe", body: payload, stripeSignature: signature)
        let store = PaymentWebhookSeenEventStore(url: root.appendingPathComponent("seen.sqlite"))

        let response = RealtimeVoiceSessionServer().stripeWebhookResponse(
            request: request,
            manager: manager,
            endpointSecretProvider: { "whsec_route" },
            seenEventStore: store,
            now: Date(timeIntervalSince1970: TimeInterval(timestamp + 10))
        )

        #expect(response.status == 200)
        let json = try #require(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        #expect(json["ok"] as? Bool == true)
        #expect(json["event_id"] as? String == "evt_route")
        #expect(json["event_type"] as? String == "checkout.session.completed")
        #expect(json["ledger_entry_id"] as? String == "payment-evt_route")
        let entries = CompanyLedgerParser.decodeJSONEntries(
            try String(contentsOf: worktree.appendingPathComponent("LEDGER.json"), encoding: .utf8)
        )
        #expect(entries.count == 1)
        #expect(entries.first?.amountUSD == 42)
        #expect(entries.first?.source == "stripe")
    }

    @Test
    func stripeWebhookRouteRejectsMissingSignature() throws {
        let payload = Data(#"{"id":"evt_missing","type":"checkout.session.completed","amount_total":4200,"currency":"usd","payment_intent":"pi_missing","metadata":{"company_id":"co"}}"#.utf8)
        let request = try Self.request(path: "/webhooks/stripe", body: payload, stripeSignature: nil)

        let response = RealtimeVoiceSessionServer().stripeWebhookResponse(
            request: request,
            manager: CodexSessionManager(testRoot: FileManager.default.temporaryDirectory.appendingPathComponent("unused-\(UUID().uuidString)")),
            endpointSecretProvider: { "whsec_route" }
        )

        #expect(response.status == 400)
        let body = String(data: response.body, encoding: .utf8) ?? ""
        #expect(body.contains("Stripe-Signature header is required"))
    }

    @Test
    func stripeStatusReportsSecretConfiguration() {
        let response = RealtimeVoiceSessionServer().stripeStatusResponse(endpointSecretProvider: { "whsec_route" })

        #expect(response.status == 200)
        let json = try? JSONSerialization.jsonObject(with: response.body) as? [String: Any]
        #expect(json?["webhook_secret_configured"] as? Bool == true)
        #expect(json?["endpoint"] as? String == "/webhooks/stripe")
    }

    private static func request(path: String, body: Data, stripeSignature: String?) throws -> HTTPRequest {
        var raw = Data()
        raw.appendString("POST \(path) HTTP/1.1\r\n")
        raw.appendString("Host: 127.0.0.1\r\n")
        raw.appendString("Content-Type: application/json\r\n")
        if let stripeSignature {
            raw.appendString("Stripe-Signature: \(stripeSignature)\r\n")
        }
        raw.appendString("Content-Length: \(body.count)\r\n")
        raw.appendString("\r\n")
        raw.append(body)
        return try #require(HTTPRequest(data: raw))
    }
}
