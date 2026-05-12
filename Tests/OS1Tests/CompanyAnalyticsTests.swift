import Foundation
import Testing
@testable import OS1

struct CompanyAnalyticsTests {
    @Test
    func ingestorAdaptersNormalizeGA4PlausibleAndYouTubeFixtures() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ga4 = try CompanyAnalyticsAdapter.ga4(
            payload: Data(#"[{"postID":"x-1","impressions":100,"clicks":12,"conversions":2,"revenueUSD":50}]"#.utf8),
            companyID: "co",
            channel: .xPost,
            now: now
        )
        let plausible = try CompanyAnalyticsAdapter.plausible(
            payload: Data(#"{"results":[{"postID":"ig-1","visitors":80,"clicks":8,"conversions":1}]}"#.utf8),
            companyID: "co",
            channel: .instagramReel,
            now: now
        )
        let youtube = try CompanyAnalyticsAdapter.youtubeAnalytics(
            payload: Data(#"{"rows":[{"videoID":"yt-1","views":500,"clicks":25,"subscribersGained":4}]}"#.utf8),
            companyID: "co",
            now: now
        )

        #expect(ga4.contains { $0.metric == .revenueUSD && $0.value == 50 && $0.source == .ga4 })
        #expect(plausible.contains { $0.metric == .impressions && $0.value == 80 && $0.channel == .instagramReel })
        #expect(youtube.contains { $0.metric == .conversions && $0.value == 4 && $0.channel == .youtubeUpload })
    }

    @Test
    func measurementsPersistAsJSONL() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("measurements-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let measurements = try CompanyAnalyticsAdapter.ga4(
            payload: Data(#"[{"postID":"x-1","impressions":100,"clicks":12,"conversions":2,"revenueUSD":50}]"#.utf8),
            companyID: "co",
            channel: .xPost
        )

        try CompanyAnalyticsIngestor.persist(measurements, to: url)
        let loaded = try CompanyAnalyticsIngestor.load(from: url)

        #expect(loaded.map(\.id) == measurements.map(\.id))
        #expect(loaded.map(\.value) == measurements.map(\.value))
    }

    @Test
    func cloakedClickAndStripeWebhookRoundTripIntoGrowthResult() {
        let affiliate = CompanyAffiliateLinkCloaker.affiliateLink(
            companyID: "co",
            postID: "post-1",
            merchant: "merchant",
            destinationURL: URL(string: "https://merchant.example/product")!
        )
        let click = CompanyAffiliateLinkCloaker.recordClick(link: affiliate.cloakedLink, id: "click-1")
        let payment = CompanyPaymentConversionEvent(
            id: "evt-1",
            companyID: "co",
            provider: .stripe,
            kind: .checkoutCompleted,
            amountUSD: 29,
            currency: "USD",
            utmCampaign: "co",
            utmContent: "post-1",
            providerReference: "cs_test_123",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let result = CompanyAttribution.growthResult(
            companyID: "co",
            campaignID: "campaign-1",
            channel: .affiliateLink,
            postID: "post-1",
            clicks: [click],
            payments: [payment]
        )

        #expect(affiliate.redirectURL.path == "/go/co/post-1")
        #expect(result.clicks == 1)
        #expect(result.conversions == 1)
        #expect(result.revenueUSD == 29)
        #expect(result.sourceReference.contains("utm_content=post-1"))
    }

    @Test
    func paymentWebhookReceiverProducesConversionAndLedgerEntry() throws {
        let event = try PaymentWebhookReceiver.stripe(
            payload: Data(#"{"id":"evt_1","type":"checkout.session.completed","amount_total":2900,"currency":"usd","payment_intent":"pi_1","metadata":{"company_id":"co","utm_campaign":"co","utm_content":"post-1"}}"#.utf8),
            receivedAt: Date(timeIntervalSince1970: 10)
        )
        let ledger = PaymentWebhookReceiver.ledgerEntry(for: event)

        #expect(event.kind == .checkoutCompleted)
        #expect(event.amountUSD == 29)
        #expect(event.utmContent == "post-1")
        #expect(ledger.kind == .revenue)
        #expect(ledger.sourceReference == "pi_1")
    }

    @Test
    func signedStripeWebhookVerifiesAndBlocksReplay() throws {
        let payload = Data(#"{"id":"evt_signed","type":"checkout.session.completed","amount_total":2900,"currency":"usd","payment_intent":"pi_signed","metadata":{"company_id":"co","utm_campaign":"co","utm_content":"post-1"}}"#.utf8)
        let timestamp = 1_800_000_000
        let header = PaymentWebhookReceiver.stripeSignatureHeader(
            payload: payload,
            timestamp: timestamp,
            endpointSecret: "whsec_test"
        )

        let event = try PaymentWebhookReceiver.verifiedStripe(
            payload: payload,
            signatureHeader: header,
            endpointSecret: "whsec_test",
            seenEventIDs: [],
            now: Date(timeIntervalSince1970: TimeInterval(timestamp + 10)),
            toleranceSeconds: 300
        )

        #expect(event.id == "evt_signed")
        #expect(event.kind == .checkoutCompleted)
        #expect(event.providerReference == "pi_signed")
        #expect(throws: PaymentWebhookReceiver.Error.replayedEvent("evt_signed")) {
            _ = try PaymentWebhookReceiver.verifiedStripe(
                payload: payload,
                signatureHeader: header,
                endpointSecret: "whsec_test",
                seenEventIDs: ["evt_signed"],
                now: Date(timeIntervalSince1970: TimeInterval(timestamp + 10)),
                toleranceSeconds: 300
            )
        }
    }

    @Test
    func stripeWebhookRejectsTamperedStaleMissingAndMalformedSignatures() throws {
        let payload = Data(#"{"id":"evt_signed","type":"checkout.session.completed","amount_total":2900,"currency":"usd","payment_intent":"pi_signed","metadata":{"company_id":"co","utm_campaign":"co","utm_content":"post-1"}}"#.utf8)
        let tamperedPayload = Data(#"{"id":"evt_signed","type":"checkout.session.completed","amount_total":9900,"currency":"usd","payment_intent":"pi_signed","metadata":{"company_id":"co","utm_campaign":"co","utm_content":"post-1"}}"#.utf8)
        let timestamp = 1_800_000_000
        let header = PaymentWebhookReceiver.stripeSignatureHeader(
            payload: payload,
            timestamp: timestamp,
            endpointSecret: "whsec_test"
        )

        #expect(throws: PaymentWebhookReceiver.Error.signatureMismatch) {
            try PaymentWebhookReceiver.verifyStripeSignature(
                payload: tamperedPayload,
                signatureHeader: header,
                endpointSecret: "whsec_test",
                now: Date(timeIntervalSince1970: TimeInterval(timestamp + 10)),
                toleranceSeconds: 300
            )
        }
        #expect(throws: PaymentWebhookReceiver.Error.timestampOutsideTolerance) {
            try PaymentWebhookReceiver.verifyStripeSignature(
                payload: payload,
                signatureHeader: header,
                endpointSecret: "whsec_test",
                now: Date(timeIntervalSince1970: TimeInterval(timestamp + 301)),
                toleranceSeconds: 300
            )
        }
        #expect(throws: PaymentWebhookReceiver.Error.missingSignatureHeader) {
            try PaymentWebhookReceiver.verifyStripeSignature(
                payload: payload,
                signatureHeader: nil,
                endpointSecret: "whsec_test",
                now: Date(timeIntervalSince1970: TimeInterval(timestamp + 10)),
                toleranceSeconds: 300
            )
        }
        #expect(throws: PaymentWebhookReceiver.Error.invalidSignatureHeader) {
            try PaymentWebhookReceiver.verifyStripeSignature(
                payload: payload,
                signatureHeader: "v0=legacy",
                endpointSecret: "whsec_test",
                now: Date(timeIntervalSince1970: TimeInterval(timestamp + 10)),
                toleranceSeconds: 300
            )
        }
    }

    @Test
    func killScaleRecommendationRefusesOnlyInferredMeasurements() {
        let inferred = CompanyMeasurement(
            id: "m1",
            companyID: "co",
            channel: .xPost,
            postID: "post",
            metric: .clicks,
            value: 10,
            periodStart: Date(timeIntervalSince1970: 1),
            periodEnd: Date(timeIntervalSince1970: 2),
            source: .ga4,
            confidence: .inferred
        )
        var calibrated = inferred
        calibrated.id = "m2"
        calibrated.confidence = .calibrated

        #expect(!CompanyAttribution.canRecommendKillOrScale(measurements: [inferred]))
        #expect(CompanyAttribution.canRecommendKillOrScale(measurements: [inferred, calibrated]))
    }

    @Test
    func checkoutLinksRespectPerCompanyPaymentAllowlist() {
        let denied = CompanyAccessControl.lockedDown(companyID: "co")
        #expect(CompanyPaymentCheckout.createTestCheckoutLink(companyID: "co", provider: .stripe, productName: "Guide", amountUSD: 19, postID: "post", accessControl: denied) == nil)

        var allowed = denied
        allowed.paymentProviderAllowlist = ["stripe"]
        let link = CompanyPaymentCheckout.createTestCheckoutLink(
            companyID: "co",
            provider: .stripe,
            productName: "Guide",
            amountUSD: 19,
            postID: "post",
            accessControl: allowed
        )

        #expect(link?.metadata["utm_campaign"] == "co")
        #expect(link?.metadata["utm_content"] == "post")
    }

    @Test
    func fiveTemplateFamiliesCanRequireRealMeasurementsAtHeartbeatTime() {
        let templates = CompanyTemplateCatalog.all.filter {
            ["X", "YouTube", "Instagram", "LinkedIn", "Email newsletter"].contains($0.channel)
        }
        #expect(templates.count >= 5)
        let measurementBacked = templates.filter { template in
            template.validationSignals.contains {
                let signal = $0.lowercased()
                return signal.contains("rate") || signal.contains("conversion") || signal.contains("click") || signal.contains("subscriber")
            }
        }
        #expect(measurementBacked.count >= 5)
    }
}
