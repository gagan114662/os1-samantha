import Foundation
import Testing
@testable import OS1

struct PaymentRuntimeWiringTests {
    @Test
    func stripeSandboxCheckoutClientCreatesMetadataRichCheckoutLink() async throws {
        let http = StubStripeCheckoutHTTPClient(
            data: Data(#"{"id":"cs_test_123","url":"https://checkout.stripe.com/c/pay/cs_test_123"}"#.utf8),
            statusCode: 200
        )
        let client = StripeCheckoutSessionClient(
            apiKeyProvider: { "sk_test_123" },
            httpClient: http
        )

        let link = try await client.createTestCheckoutSession(
            companyID: "co",
            productName: "Guide",
            amountUSD: 19,
            postID: "post-1"
        )

        let request = try #require(http.lastRequest)
        let body = String(data: try #require(request.httpBody), encoding: .utf8) ?? ""
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk_test_123")
        #expect(body.contains("metadata%5Bcompany_id%5D=co"))
        #expect(body.contains("metadata%5Butm_content%5D=post-1"))
        #expect(link.id == "cs_test_123")
        #expect(link.checkoutURL?.absoluteString == "https://checkout.stripe.com/c/pay/cs_test_123")
    }

    @Test
    func managerAppendsVerifiedStripeWebhookToLedgerJSON() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("payment-runtime-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("co", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "[]".write(to: worktree.appendingPathComponent("LEDGER.json"), atomically: true, encoding: .utf8)

        let payload = Data(#"{"id":"evt_ledger","type":"checkout.session.completed","amount_total":2900,"currency":"usd","payment_intent":"pi_ledger","metadata":{"company_id":"co","utm_campaign":"co","utm_content":"post-1"}}"#.utf8)
        let timestamp = 1_800_000_000
        let header = PaymentWebhookReceiver.stripeSignatureHeader(
            payload: payload,
            timestamp: timestamp,
            endpointSecret: "whsec_test"
        )
        let store = PaymentWebhookSeenEventStore(
            url: root.appendingPathComponent("seen.sqlite")
        )

        let result = try await MainActor.run {
            let manager = CodexSessionManager(testRoot: root)
            let session = CodexSession(
                id: "co",
                title: "co",
                task: "sell a guide",
                worktreePath: worktree.path,
                branch: "company/co",
                status: .idle,
                startedAt: Date(timeIntervalSince1970: 1)
            )
            manager.replaceSessionsForTesting([session])
            CompanyAccessControl.grantCapabilities([.payments], companyID: "co")
            let entry = try manager.recordStripeWebhook(
                companyID: "co",
                payload: payload,
                signatureHeader: header,
                endpointSecret: "whsec_test",
                seenEventStore: store,
                now: Date(timeIntervalSince1970: TimeInterval(timestamp + 10))
            )
            let summary = manager.ledgerSummary(id: "co")
            return (
                entry: entry,
                entryCount: summary.entries.count,
                verifiedCount: summary.verifiedEntryCount,
                tracedCount: summary.tracedEntryCount,
                revenueUSD: summary.revenueUSD
            )
        }

        #expect(result.entry.id == "payment-evt_ledger")
        #expect(result.entry.confidence == .verified)
        #expect(result.entry.source == "stripe")
        #expect(result.entry.sourceReference == "pi_ledger")
        #expect(result.entry.sourceEventID != nil)
        #expect(result.entryCount == 1)
        #expect(result.verifiedCount == 1)
        #expect(result.tracedCount == 1)
        #expect(result.revenueUSD == 29)
    }

    @Test
    func stripeParserRoutesNamedLaunchEvents() throws {
        let cases: [(type: String, object: String, amountUSD: Double, reference: String)] = [
            (
                "checkout.session.completed",
                #"{"id":"cs_launch","amount_total":1900,"currency":"usd","payment_intent":"pi_launch","metadata":{"company_id":"co","utm_campaign":"co","utm_content":"checkout"}}"#,
                19,
                "pi_launch"
            ),
            (
                "payment_intent.succeeded",
                #"{"id":"pi_launch","amount_received":2100,"currency":"usd","metadata":{"company_id":"co","utm_campaign":"co","utm_content":"intent"}}"#,
                21,
                "pi_launch"
            ),
            (
                "customer.subscription.updated",
                #"{"id":"sub_launch","currency":"usd","metadata":{"company_id":"co","utm_campaign":"co","utm_content":"subscription"}}"#,
                0,
                "sub_launch"
            ),
            (
                "invoice.paid",
                #"{"id":"in_launch","amount_paid":3200,"currency":"usd","payment_intent":"pi_invoice","metadata":{"company_id":"co","utm_campaign":"co","utm_content":"invoice"}}"#,
                32,
                "pi_invoice"
            )
        ]

        for item in cases {
            let eventID = "evt_\(item.type.replacingOccurrences(of: ".", with: "_"))"
            let payload = Data(#"{"id":"\#(eventID)","type":"\#(item.type)","data":{"object":\#(item.object)}}"#.utf8)

            let event = try PaymentWebhookReceiver.stripe(payload: payload, receivedAt: Date(timeIntervalSince1970: 1_800_000_000))

            #expect(event.companyID == "co")
            #expect(event.kind == .checkoutCompleted)
            #expect(event.amountUSD == item.amountUSD)
            #expect(event.providerReference == item.reference)
            #expect(event.metadata?["stripe_event_type"] == item.type)
        }
    }

    @Test
    func wuphfStripeWebhookRouteRecordsSignedNestedStripeEvent() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("wuphf-stripe-route-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let worktree = root.appendingPathComponent("co", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try "[]".write(to: worktree.appendingPathComponent("LEDGER.json"), atomically: true, encoding: .utf8)

        let payload = Data(#"{"id":"evt_route","type":"checkout.session.completed","data":{"object":{"id":"cs_route","amount_total":4300,"currency":"usd","payment_intent":"pi_route","metadata":{"company_id":"co","utm_campaign":"co","utm_content":"launch"}}}}"#.utf8)
        let timestamp = 1_800_000_000
        let header = PaymentWebhookReceiver.stripeSignatureHeader(
            payload: payload,
            timestamp: timestamp,
            endpointSecret: "whsec_route"
        )
        var requestData = Data()
        requestData.appendString("POST /webhooks/stripe HTTP/1.1\r\n")
        requestData.appendString("Host: localhost:7891\r\n")
        requestData.appendString("Stripe-Signature: \(header)\r\n")
        requestData.appendString("Content-Type: application/json\r\n")
        requestData.appendString("Content-Length: \(payload.count)\r\n")
        requestData.appendString("\r\n")
        requestData.append(payload)
        let request = try #require(HTTPRequest(data: requestData))

        let result = await MainActor.run {
            let manager = CodexSessionManager(testRoot: root)
            let session = CodexSession(
                id: "co",
                title: "co",
                task: "sell a guide",
                worktreePath: worktree.path,
                branch: "company/co",
                status: .idle,
                startedAt: Date(timeIntervalSince1970: 1)
            )
            manager.replaceSessionsForTesting([session])
            CompanyAccessControl.grantCapabilities([.payments], companyID: "co")
            let server = RealtimeVoiceSessionServer(
                elevenLabsAPIKeyProvider: { "eleven" },
                agentIDProvider: { "agent" }
            )
            let response = server.stripeWebhookResponse(
                request: request,
                manager: manager,
                endpointSecretProvider: { "whsec_route" },
                seenEventStore: PaymentWebhookSeenEventStore(
                    url: root.appendingPathComponent("route-seen.sqlite")
                ),
                now: Date(timeIntervalSince1970: TimeInterval(timestamp + 10))
            )
            let body = String(data: response.body, encoding: .utf8) ?? ""
            return (
                status: response.status,
                body: body,
                summary: manager.ledgerSummary(id: "co")
            )
        }

        #expect(result.status == 200)
        #expect(result.body.contains(#""event_id":"evt_route""#))
        #expect(result.body.contains(#""event_type":"checkout.session.completed""#))
        #expect(result.summary.entries.count == 1)
        #expect(result.summary.entries.first?.amountUSD == 43)
        #expect(result.summary.entries.first?.sourceReference == "pi_route")
    }
}

private final class StubStripeCheckoutHTTPClient: StripeCheckoutHTTPClient, @unchecked Sendable {
    var lastRequest: URLRequest?
    let data: Data
    let statusCode: Int

    init(data: Data, statusCode: Int) {
        self.data = data
        self.statusCode = statusCode
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        lastRequest = request
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}
