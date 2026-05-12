import CryptoKit
import Foundation
import SQLite3

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
        case gumroad
        case etsy
        case amazonKDP
        case bandcamp
        case appStore
        case googlePlay
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
    var metadata: [String: String]? = nil
}

struct CompanyCheckoutLink: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var provider: CompanyPaymentConversionEvent.Provider
    var productName: String
    var amountUSD: Double
    var checkoutURL: URL?
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
        accessControl: CompanyAccessControl,
        checkoutID: String? = nil,
        checkoutURL: URL? = nil
    ) -> CompanyCheckoutLink? {
        guard accessControl.paymentProviderAllowlist.contains(provider.rawValue) else { return nil }
        let id = checkoutID ?? "\(companyID)-\(provider.rawValue)-\(postID)"
        return CompanyCheckoutLink(
            id: id,
            companyID: companyID,
            provider: provider,
            productName: productName,
            amountUSD: amountUSD,
            checkoutURL: checkoutURL,
            successURL: URL(string: "https://example.com/success?utm_campaign=\(companyID)&utm_content=\(postID)")!,
            metadata: [
                "company_id": companyID,
                "utm_campaign": companyID,
                "utm_content": postID,
                "mode": "test"
            ]
        )
    }
}

struct PaymentWebhookSeenEvent: Codable, Hashable, Identifiable, Sendable {
    var id: String
    var provider: CompanyPaymentConversionEvent.Provider
    var seenAt: Date
    var expiresAt: Date
}

struct PaymentWebhookSeenEventStore: Sendable {
    var url: URL
    var ttlSeconds: TimeInterval
    private static let databaseQueue = DispatchQueue(label: "OS1.PaymentWebhookSeenEventStore.database")

    init(url: URL, ttlSeconds: TimeInterval = 72 * 3_600) {
        self.url = url
        self.ttlSeconds = ttlSeconds
    }

    func recordIfNew(
        eventID: String,
        provider: CompanyPaymentConversionEvent.Provider,
        now: Date = Date()
    ) throws -> Bool {
        try Self.databaseQueue.sync {
            try recordIfNewUnlocked(eventID: eventID, provider: provider, now: now)
        }
    }

    private func recordIfNewUnlocked(
        eventID: String,
        provider: CompanyPaymentConversionEvent.Provider,
        now: Date
    ) throws -> Bool {
        let database = try openDatabase()
        defer { sqlite3_close(database) }
        try pruneExpired(database: database, now: now)
        try execute(
            database: database,
            sql: "INSERT OR IGNORE INTO seen_events (provider, id, expires_at) VALUES (?, ?, ?)",
            bindings: [.text(provider.rawValue), .text(eventID), .double(now.addingTimeInterval(ttlSeconds).timeIntervalSince1970)]
        )
        return sqlite3_changes(database) > 0
    }

    func contains(
        eventID: String,
        provider: CompanyPaymentConversionEvent.Provider,
        now: Date = Date()
    ) throws -> Bool {
        try activeEntries(now: now).contains { $0.id == eventID && $0.provider == provider }
    }

    func activeEntries(now: Date = Date()) throws -> [PaymentWebhookSeenEvent] {
        try Self.databaseQueue.sync {
            let database = try openDatabase()
            defer { sqlite3_close(database) }
            try pruneExpired(database: database, now: now)
            return try queryActiveEntries(database: database, now: now)
        }
    }

    func count(now: Date = Date()) throws -> Int {
        try activeEntries(now: now).count
    }

    private func openDatabase() throws -> OpaquePointer? {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let jsonEntries = try migrateableJSONEntries()
        if jsonEntries != nil, FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }

        var database: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown sqlite open error"
            if let database { sqlite3_close(database) }
            throw SQLitePaymentWebhookStoreError.open(message)
        }
        sqlite3_busy_timeout(database, 5_000)
        do {
            try execute(database: database, sql: "PRAGMA journal_mode=WAL")
            try execute(database: database, sql: "PRAGMA synchronous=NORMAL")
            try execute(
                database: database,
                sql: """
                CREATE TABLE IF NOT EXISTS seen_events (
                  id         TEXT NOT NULL,
                  provider   TEXT NOT NULL,
                  expires_at REAL NOT NULL,
                  PRIMARY KEY (provider, id)
                ) WITHOUT ROWID
                """
            )
            try execute(database: database, sql: "CREATE INDEX IF NOT EXISTS idx_expires ON seen_events(expires_at)")
            if let jsonEntries {
                try insertMigrated(entries: jsonEntries, database: database)
            }
            return database
        } catch {
            sqlite3_close(database)
            throw error
        }
    }

    private func migrateableJSONEntries() throws -> [PaymentWebhookSeenEvent]? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let data = try Data(contentsOf: url)
        guard let first = data.first(where: { !$0.isASCIIWhitespace }), first == UInt8(ascii: "[") else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try decoder.decode([PaymentWebhookSeenEvent].self, from: data)
    }

    private func insertMigrated(entries: [PaymentWebhookSeenEvent], database: OpaquePointer?) throws {
        for entry in entries {
            try execute(
                database: database,
                sql: "INSERT OR IGNORE INTO seen_events (provider, id, expires_at) VALUES (?, ?, ?)",
                bindings: [.text(entry.provider.rawValue), .text(entry.id), .double(entry.expiresAt.timeIntervalSince1970)]
            )
        }
    }

    private func pruneExpired(database: OpaquePointer?, now: Date) throws {
        try execute(
            database: database,
            sql: "DELETE FROM seen_events WHERE expires_at < ?",
            bindings: [.double(now.timeIntervalSince1970)]
        )
    }

    private func queryActiveEntries(database: OpaquePointer?, now: Date) throws -> [PaymentWebhookSeenEvent] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT provider, id, expires_at FROM seen_events WHERE expires_at > ? ORDER BY provider, id",
            -1,
            &statement,
            nil
        ) == SQLITE_OK else {
            throw SQLitePaymentWebhookStoreError.prepare(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, now.timeIntervalSince1970)

        var entries: [PaymentWebhookSeenEvent] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            let providerRaw = String(cString: sqlite3_column_text(statement, 0))
            let id = String(cString: sqlite3_column_text(statement, 1))
            let expiresAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, 2))
            guard let provider = CompanyPaymentConversionEvent.Provider(rawValue: providerRaw) else { continue }
            entries.append(PaymentWebhookSeenEvent(
                id: id,
                provider: provider,
                seenAt: expiresAt.addingTimeInterval(-ttlSeconds),
                expiresAt: expiresAt
            ))
        }
        return entries
    }

    private func execute(database: OpaquePointer?, sql: String, bindings: [SQLiteBinding] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK else {
            throw SQLitePaymentWebhookStoreError.prepare(errorMessage(database))
        }
        defer { sqlite3_finalize(statement) }
        for (offset, binding) in bindings.enumerated() {
            let index = Int32(offset + 1)
            switch binding {
            case .text(let value):
                sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
            case .double(let value):
                sqlite3_bind_double(statement, index, value)
            }
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE || result == SQLITE_ROW else {
            throw SQLitePaymentWebhookStoreError.execute(errorMessage(database))
        }
    }

    private func errorMessage(_ database: OpaquePointer?) -> String {
        database.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown sqlite error"
    }
}

private enum SQLitePaymentWebhookStoreError: Error, Equatable {
    case open(String)
    case prepare(String)
    case execute(String)
}

private enum SQLiteBinding {
    case text(String)
    case double(Double)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension UInt8 {
    var isASCIIWhitespace: Bool {
        self == UInt8(ascii: " ") ||
        self == UInt8(ascii: "\n") ||
        self == UInt8(ascii: "\r") ||
        self == UInt8(ascii: "\t")
    }
}

enum PaymentWebhookReceiver {
    enum Error: Swift.Error, Equatable {
        case paymentsCapabilityNotGranted(String)
        case missingSignatureHeader
        case invalidSignatureHeader
        case timestampOutsideTolerance
        case signatureMismatch
        case replayedEvent(String)
        case companyIDMismatch(expected: String, actual: String)
    }

    struct StripeSignature: Equatable {
        var timestamp: Int
        var signatures: [String]
    }

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
            occurredAt: receivedAt,
            metadata: fixture.metadata.merging([
                "payment_intent": fixture.payment_intent ?? fixture.id,
                "amount_total": "\(Int(amount))"
            ]) { current, _ in current }
        )
    }

    static func verifiedStripe(
        companyID: String,
        payload: Data,
        signatureHeader: String?,
        endpointSecret: String,
        seenEventIDs: Set<String>,
        now: Date = Date(),
        toleranceSeconds: TimeInterval = 300
    ) throws -> CompanyPaymentConversionEvent {
        try requirePaymentsCapability(companyID: companyID)
        try verifyStripeSignature(
            payload: payload,
            signatureHeader: signatureHeader,
            endpointSecret: endpointSecret,
            now: now,
            toleranceSeconds: toleranceSeconds
        )
        let event = try stripe(payload: payload, receivedAt: now)
        guard event.companyID == companyID else {
            throw Error.companyIDMismatch(expected: companyID, actual: event.companyID)
        }
        guard !seenEventIDs.contains(event.id) else {
            throw Error.replayedEvent(event.id)
        }
        return event
    }

    static func verifiedStripe(
        companyID: String,
        payload: Data,
        signatureHeader: String?,
        endpointSecret: String,
        seenEventStore: PaymentWebhookSeenEventStore,
        now: Date = Date(),
        toleranceSeconds: TimeInterval = 300
    ) throws -> CompanyPaymentConversionEvent {
        try requirePaymentsCapability(companyID: companyID)
        try verifyStripeSignature(
            payload: payload,
            signatureHeader: signatureHeader,
            endpointSecret: endpointSecret,
            now: now,
            toleranceSeconds: toleranceSeconds
        )
        let event = try stripe(payload: payload, receivedAt: now)
        guard event.companyID == companyID else {
            throw Error.companyIDMismatch(expected: companyID, actual: event.companyID)
        }
        guard try seenEventStore.recordIfNew(eventID: event.id, provider: event.provider, now: now) else {
            throw Error.replayedEvent(event.id)
        }
        return event
    }

    static func verifiedGumroad(
        companyID: String,
        payload: Data,
        signatureHeader: String?,
        applicationSecret: String,
        seenEventStore: PaymentWebhookSeenEventStore,
        now: Date = Date()
    ) throws -> CompanyPaymentConversionEvent {
        try requirePaymentsCapability(companyID: companyID)
        try verifyGumroadSignature(
            payload: payload,
            signatureHeader: signatureHeader,
            applicationSecret: applicationSecret
        )
        let event = try gumroad(payload: payload, companyID: companyID, receivedAt: now)
        guard try seenEventStore.recordIfNew(eventID: event.id, provider: event.provider, now: now) else {
            throw Error.replayedEvent(event.id)
        }
        return event
    }

    static func verifyStripeSignature(
        payload: Data,
        signatureHeader: String?,
        endpointSecret: String,
        now: Date = Date(),
        toleranceSeconds: TimeInterval = 300
    ) throws {
        guard let signatureHeader, !signatureHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.missingSignatureHeader
        }
        let parsed = try parseStripeSignatureHeader(signatureHeader)
        let age = abs(now.timeIntervalSince1970 - TimeInterval(parsed.timestamp))
        guard age <= toleranceSeconds else {
            throw Error.timestampOutsideTolerance
        }
        let expected = stripeSignature(payload: payload, timestamp: parsed.timestamp, endpointSecret: endpointSecret)
        guard parsed.signatures.contains(where: { constantTimeEqualHex($0, expected) }) else {
            throw Error.signatureMismatch
        }
    }

    static func stripeSignatureHeader(payload: Data, timestamp: Int, endpointSecret: String) -> String {
        "t=\(timestamp),v1=\(stripeSignature(payload: payload, timestamp: timestamp, endpointSecret: endpointSecret))"
    }

    static func verifyGumroadSignature(
        payload: Data,
        signatureHeader: String?,
        applicationSecret: String
    ) throws {
        guard let signatureHeader, !signatureHeader.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw Error.missingSignatureHeader
        }
        let expected = hmacHex(payload: payload, secret: applicationSecret)
        guard constantTimeEqualHex(signatureHeader.trimmingCharacters(in: .whitespacesAndNewlines), expected) else {
            throw Error.signatureMismatch
        }
    }

    static func gumroadSignatureHeader(payload: Data, applicationSecret: String) -> String {
        hmacHex(payload: payload, secret: applicationSecret)
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

    private static func requirePaymentsCapability(companyID: String) throws {
        guard CompanyAccessControl.canUse(companyID: companyID, capability: .payments) else {
            throw Error.paymentsCapabilityNotGranted(companyID)
        }
    }

    private static func gumroad(payload: Data, companyID: String, receivedAt: Date) throws -> CompanyPaymentConversionEvent {
        struct GumroadJSON: Decodable {
            let id: String?
            let sale_id: String?
            let price: Double?
            let price_cents: Double?
            let amount_cents: Double?
            let currency: String?
            let product_id: String?
            let product_name: String?
        }
        let fixture = try JSONDecoder().decode(GumroadJSON.self, from: payload)
        let id = fixture.id ?? fixture.sale_id ?? fixture.product_id ?? "gumroad-\(CompanyEvent.inputHash(for: String(data: payload, encoding: .utf8) ?? ""))"
        let currency = (fixture.currency ?? "USD").uppercased()
        let amount = fixture.price_cents.map { $0 / 100 } ?? fixture.amount_cents.map { $0 / 100 } ?? fixture.price ?? 0
        return CompanyPaymentConversionEvent(
            id: id,
            companyID: companyID,
            provider: .gumroad,
            kind: .checkoutCompleted,
            amountUSD: amount,
            currency: currency,
            utmCampaign: companyID,
            utmContent: fixture.product_id ?? fixture.product_name,
            providerReference: id,
            occurredAt: receivedAt,
            metadata: ["company_id": companyID, "payment_intent": id, "amount_total": "\(Int((amount * 100).rounded()))"]
        )
    }

    private static func parseStripeSignatureHeader(_ header: String) throws -> StripeSignature {
        var timestamp: Int?
        var signatures: [String] = []
        for component in header.split(separator: ",") {
            let pair = component.split(separator: "=", maxSplits: 1).map {
                String($0).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard pair.count == 2 else { continue }
            if pair[0] == "t" {
                timestamp = Int(pair[1])
            } else if pair[0] == "v1" {
                signatures.append(pair[1])
            }
        }
        guard let timestamp, !signatures.isEmpty else {
            throw Error.invalidSignatureHeader
        }
        return StripeSignature(timestamp: timestamp, signatures: signatures)
    }

    private static func stripeSignature(payload: Data, timestamp: Int, endpointSecret: String) -> String {
        var signedPayload = Data("\(timestamp).".utf8)
        signedPayload.append(payload)
        return hmacHex(payload: signedPayload, secret: endpointSecret)
    }

    private static func hmacHex(payload: Data, secret: String) -> String {
        let key = SymmetricKey(data: Data(secret.utf8))
        let digest = HMAC<SHA256>.authenticationCode(for: payload, using: key)
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqualHex(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.lowercased().utf8)
        let right = Array(rhs.lowercased().utf8)
        guard left.count == right.count else { return false }
        var diff: UInt8 = 0
        for index in left.indices {
            diff |= left[index] ^ right[index]
        }
        return diff == 0
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
