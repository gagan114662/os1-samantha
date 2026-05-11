import Foundation

struct CompanyMeasurement: Codable, Hashable, Identifiable {
    enum Source: String, Codable, CaseIterable, Hashable {
        case ga4
        case plausible
        case youtubeAnalytics
        case cloakedRedirect
        case paymentsLedger
    }

    enum Metric: String, Codable, CaseIterable, Hashable {
        case impressions
        case clicks
        case replies
        case conversions
        case revenueUSD
    }

    enum Confidence: String, Codable, CaseIterable, Hashable {
        case calibrated
        case estimated
        case inferred
    }

    var id: String
    var companyID: String
    var channel: CompanyGrowthCampaign.Channel
    var postID: String
    var metric: Metric
    var value: Double
    var periodStart: Date
    var periodEnd: Date
    var source: Source
    var confidence: Confidence
}

struct CompanyAnalyticsSourceHealth: Codable, Hashable, Identifiable {
    var id: String { source.rawValue }
    var source: CompanyMeasurement.Source
    var lastSuccessfulSync: Date?
    var lagSeconds: TimeInterval
    var errorCount: Int
    var quotaRemaining: Int?
}

struct CompanyAnalyticsHealthReport: Codable, Hashable {
    var companyID: String
    var sources: [CompanyAnalyticsSourceHealth]

    var unhealthySources: [CompanyMeasurement.Source] {
        sources.filter { $0.errorCount > 0 }.map(\.source)
    }
}

enum CompanyAnalyticsAdapter {
    static func ga4(payload: Data, companyID: String, channel: CompanyGrowthCampaign.Channel, now: Date = Date()) throws -> [CompanyMeasurement] {
        struct Row: Decodable {
            let postID: String
            let impressions: Double
            let clicks: Double
            let conversions: Double
            let revenueUSD: Double
        }
        let rows = try JSONDecoder().decode([Row].self, from: payload)
        return rows.flatMap { row in
            measurements(companyID: companyID, channel: channel, postID: row.postID, source: .ga4, confidence: .calibrated, values: [
                .impressions: row.impressions,
                .clicks: row.clicks,
                .conversions: row.conversions,
                .revenueUSD: row.revenueUSD
            ], now: now)
        }
    }

    static func plausible(payload: Data, companyID: String, channel: CompanyGrowthCampaign.Channel, now: Date = Date()) throws -> [CompanyMeasurement] {
        struct Response: Decodable {
            let results: [Row]
            struct Row: Decodable {
                let postID: String
                let visitors: Double
                let clicks: Double
                let conversions: Double
            }
        }
        let response = try JSONDecoder().decode(Response.self, from: payload)
        return response.results.flatMap { row in
            measurements(companyID: companyID, channel: channel, postID: row.postID, source: .plausible, confidence: .calibrated, values: [
                .impressions: row.visitors,
                .clicks: row.clicks,
                .conversions: row.conversions
            ], now: now)
        }
    }

    static func youtubeAnalytics(payload: Data, companyID: String, now: Date = Date()) throws -> [CompanyMeasurement] {
        struct Response: Decodable {
            let rows: [Row]
            struct Row: Decodable {
                let videoID: String
                let views: Double
                let clicks: Double
                let subscribersGained: Double
            }
        }
        let response = try JSONDecoder().decode(Response.self, from: payload)
        return response.rows.flatMap { row in
            measurements(companyID: companyID, channel: .youtubeUpload, postID: row.videoID, source: .youtubeAnalytics, confidence: .calibrated, values: [
                .impressions: row.views,
                .clicks: row.clicks,
                .conversions: row.subscribersGained
            ], now: now)
        }
    }

    private static func measurements(
        companyID: String,
        channel: CompanyGrowthCampaign.Channel,
        postID: String,
        source: CompanyMeasurement.Source,
        confidence: CompanyMeasurement.Confidence,
        values: [CompanyMeasurement.Metric: Double],
        now: Date
    ) -> [CompanyMeasurement] {
        values.map { metric, value in
            CompanyMeasurement(
                id: "\(companyID)-\(postID)-\(source.rawValue)-\(metric.rawValue)",
                companyID: companyID,
                channel: channel,
                postID: postID,
                metric: metric,
                value: value,
                periodStart: now.addingTimeInterval(-86_400),
                periodEnd: now,
                source: source,
                confidence: confidence
            )
        }
    }
}

enum CompanyAnalyticsIngestor {
    static func persist(_ measurements: [CompanyMeasurement], to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let lines = try measurements.map { measurement -> String in
            String(data: try encoder.encode(measurement), encoding: .utf8) ?? "{}"
        }.joined(separator: "\n")
        try (lines + (lines.isEmpty ? "" : "\n")).write(to: url, atomically: true, encoding: .utf8)
    }

    static func load(from url: URL) throws -> [CompanyMeasurement] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n")
            .map { try decoder.decode(CompanyMeasurement.self, from: Data($0.utf8)) }
    }

    static func health(companyID: String, measurements: [CompanyMeasurement], now: Date = Date()) -> CompanyAnalyticsHealthReport {
        let sourceGroups = Dictionary(grouping: measurements.filter { $0.companyID == companyID }, by: \.source)
        return CompanyAnalyticsHealthReport(
            companyID: companyID,
            sources: CompanyMeasurement.Source.allCases.map { source in
                let last = sourceGroups[source]?.map(\.periodEnd).max()
                return CompanyAnalyticsSourceHealth(
                    source: source,
                    lastSuccessfulSync: last,
                    lagSeconds: last.map { now.timeIntervalSince($0) } ?? .infinity,
                    errorCount: last == nil ? 1 : 0,
                    quotaRemaining: nil
                )
            }
        )
    }
}

struct CompanyCloakedLink: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var postID: String
    var destinationURL: URL
    var cloakedPath: String
    var utmCampaign: String
    var utmContent: String
}

struct CompanyAffiliateLink: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var postID: String
    var merchant: String
    var destinationURL: URL
    var cloakedLink: CompanyCloakedLink

    var redirectURL: URL {
        URL(string: "https://r.os1.local\(cloakedLink.cloakedPath)")!
    }
}

struct CompanyCloakedLinkClick: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var postID: String
    var utmCampaign: String
    var utmContent: String
    var occurredAt: Date
}

enum CompanyAffiliateLinkCloaker {
    static func affiliateLink(
        companyID: String,
        postID: String,
        merchant: String,
        destinationURL: URL
    ) -> CompanyAffiliateLink {
        let link = create(companyID: companyID, postID: postID, destinationURL: destinationURL)
        return CompanyAffiliateLink(
            id: "aff-\(companyID)-\(postID)",
            companyID: companyID,
            postID: postID,
            merchant: merchant,
            destinationURL: destinationURL,
            cloakedLink: link
        )
    }

    static func create(companyID: String, postID: String, destinationURL: URL) -> CompanyCloakedLink {
        CompanyCloakedLink(
            id: "\(companyID)-\(postID)",
            companyID: companyID,
            postID: postID,
            destinationURL: destinationURL,
            cloakedPath: "/go/\(companyID)/\(postID)",
            utmCampaign: companyID,
            utmContent: postID
        )
    }

    static func recordClick(link: CompanyCloakedLink, id: String = UUID().uuidString, at date: Date = Date()) -> CompanyCloakedLinkClick {
        CompanyCloakedLinkClick(
            id: id,
            companyID: link.companyID,
            postID: link.postID,
            utmCampaign: link.utmCampaign,
            utmContent: link.utmContent,
            occurredAt: date
        )
    }
}

struct CompanyPaymentConversionEvent: Codable, Hashable, Identifiable {
    enum Provider: String, Codable, CaseIterable, Hashable {
        case stripe
        case paypal
    }

    enum Kind: String, Codable, CaseIterable, Hashable {
        case checkoutCompleted
        case refundCreated
        case chargebackOpened
    }

    var id: String
    var companyID: String
    var provider: Provider
    var kind: Kind
    var amountUSD: Double
    var currency: String
    var utmCampaign: String?
    var utmContent: String?
    var providerReference: String
    var occurredAt: Date
}

struct CompanyCheckoutLink: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var provider: CompanyPaymentConversionEvent.Provider
    var productName: String
    var amountUSD: Double
    var successURL: URL
    var metadata: [String: String]
}

enum CompanyPaymentCheckout {
    static func createTestCheckoutLink(
        companyID: String,
        provider: CompanyPaymentConversionEvent.Provider,
        productName: String,
        amountUSD: Double,
        postID: String,
        accessControl: CompanyAccessControl
    ) -> CompanyCheckoutLink? {
        guard accessControl.paymentProviderAllowlist.contains(provider.rawValue) else { return nil }
        return CompanyCheckoutLink(
            id: "\(companyID)-\(provider.rawValue)-\(postID)",
            companyID: companyID,
            provider: provider,
            productName: productName,
            amountUSD: amountUSD,
            successURL: URL(string: "https://example.com/success?utm_campaign=\(companyID)&utm_content=\(postID)")!,
            metadata: [
                "utm_campaign": companyID,
                "utm_content": postID,
                "mode": "test"
            ]
        )
    }
}

enum PaymentWebhookReceiver {
    static func stripe(payload: Data, receivedAt: Date = Date()) throws -> CompanyPaymentConversionEvent {
        struct StripeFixture: Decodable {
            let id: String
            let type: String
            let amount_total: Double?
            let amount_refunded: Double?
            let currency: String
            let payment_intent: String?
            let metadata: [String: String]
        }
        let fixture = try JSONDecoder().decode(StripeFixture.self, from: payload)
        let kind: CompanyPaymentConversionEvent.Kind
        let amount: Double
        if fixture.type.contains("refund") {
            kind = .refundCreated
            amount = fixture.amount_refunded ?? fixture.amount_total ?? 0
        } else if fixture.type.contains("chargeback") || fixture.type.contains("dispute") {
            kind = .chargebackOpened
            amount = fixture.amount_total ?? 0
        } else {
            kind = .checkoutCompleted
            amount = fixture.amount_total ?? 0
        }
        return CompanyPaymentConversionEvent(
            id: fixture.id,
            companyID: fixture.metadata["company_id"] ?? fixture.metadata["utm_campaign"] ?? "",
            provider: .stripe,
            kind: kind,
            amountUSD: amount / 100,
            currency: fixture.currency.uppercased(),
            utmCampaign: fixture.metadata["utm_campaign"],
            utmContent: fixture.metadata["utm_content"],
            providerReference: fixture.payment_intent ?? fixture.id,
            occurredAt: receivedAt
        )
    }

    static func ledgerEntry(for event: CompanyPaymentConversionEvent) -> CompanyLedgerEntry {
        let kind: CompanyLedgerEntry.Kind = event.kind == .refundCreated || event.kind == .chargebackOpened ? .refund : .revenue
        return CompanyLedgerEntry(
            id: "payment-\(event.id)",
            companyID: event.companyID,
            occurredAt: event.occurredAt,
            kind: kind,
            category: kind == .refund ? .refund : .sales,
            amountUSD: event.amountUSD,
            source: event.provider.rawValue,
            sourceReference: event.providerReference,
            confidence: .verified,
            note: "payment_webhook=\(event.id) kind=\(event.kind.rawValue)"
        )
    }
}

enum CompanyAttribution {
    static func growthResult(
        companyID: String,
        campaignID: String,
        channel: CompanyGrowthCampaign.Channel,
        postID: String,
        clicks: [CompanyCloakedLinkClick],
        payments: [CompanyPaymentConversionEvent]
    ) -> CompanyGrowthResult {
        let scopedClicks = clicks.filter { $0.companyID == companyID && $0.utmCampaign == companyID && $0.utmContent == postID }
        let scopedPayments = payments.filter { payment in
            payment.companyID == companyID &&
            payment.kind == .checkoutCompleted &&
            payment.utmCampaign == companyID &&
            payment.utmContent == postID
        }
        return CompanyGrowthResult(
            companyID: companyID,
            campaignID: campaignID,
            impressions: 0,
            clicks: scopedClicks.count,
            replies: 0,
            conversions: scopedPayments.count,
            revenueUSD: scopedPayments.map { $0.amountUSD }.reduce(0, +),
            costUSD: 0,
            sourceReference: "utm_campaign=\(companyID)&utm_content=\(postID)"
        )
    }

    static func canRecommendKillOrScale(measurements: [CompanyMeasurement]) -> Bool {
        !measurements.isEmpty && measurements.contains { $0.confidence != .inferred }
    }
}
