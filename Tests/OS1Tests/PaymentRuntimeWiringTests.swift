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

        let entry = try await MainActor.run {
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
            return try manager.recordStripeWebhook(
                companyID: "co",
                payload: payload,
                signatureHeader: header,
                endpointSecret: "whsec_test",
                seenEventStore: store,
                now: Date(timeIntervalSince1970: TimeInterval(timestamp + 10))
            )
        }

        let ledgerJSON = try String(contentsOf: worktree.appendingPathComponent("LEDGER.json"), encoding: .utf8)
        let entries = CompanyLedgerParser.decodeJSONEntries(ledgerJSON)
        #expect(entries.count == 1)
        #expect(entries.first?.id == entry.id)
        #expect(entries.first?.confidence == .verified)
        #expect(entries.first?.source == "stripe")
        #expect(entries.first?.sourceReference == "pi_ledger")
        #expect(entries.first?.sourceEventID != nil)
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
