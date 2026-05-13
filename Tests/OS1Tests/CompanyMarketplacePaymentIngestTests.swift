import Foundation
import Testing
@testable import OS1

struct CompanyMarketplacePaymentIngestTests {
    @Test
    func etsyCSVIngestProducesExpectedEvents() throws {
        let csv = """
        Order ID,Date,Item Total,Currency,SKU
        E-1,2026-05-01,12.50,USD,printable-a
        E-2,2026-05-02,8.00,USD,printable-b
        E-3,2026-05-03,4.50,USD,printable-c
        """

        let events = try EtsyCSVIngest.ingest(csv: csv, companyID: "etsy-co")

        #expect(events.count == 3)
        #expect(events.map(\.amountUSD) == [12.50, 8.00, 4.50])
        #expect(events.first?.provider == .etsy)
        #expect(events.first?.providerReference == "E-1")
    }

    @Test
    func etsyCSVIngestProducesProviderEventsForReconciliation() throws {
        let csv = """
        Order ID,Date,Item Total,Currency,SKU
        E-1,2026-05-01,12.50,USD,printable-a
        E-2,2026-05-02,8.00,USD,printable-b
        E-3,2026-05-03,4.50,USD,printable-c
        """

        let events = try EtsyCSVIngest.providerEvents(csv: csv, companyID: "etsy-co")

        #expect(events.count == 3)
        #expect(events.allSatisfy { $0.kind == .charge })
        #expect(events.map(\.sourceReference) == ["E-1", "E-2", "E-3"])
        #expect(events.map(\.provider) == ["etsy", "etsy", "etsy"])
    }

    @Test
    func kdpCSVIngestProducesExpectedEvents() throws {
        let csv = """
        Royalty Date,Title,ASIN,Royalty,Currency
        2026-05-01,Guide One,B001,3.10,USD
        2026-05-02,Guide Two,B002,4.25,USD
        2026-05-03,Guide Three,B003,5.00,USD
        """

        let events = try KDPCSVIngest.ingest(csv: csv, companyID: "kdp-co")

        #expect(events.count == 3)
        #expect(events.map(\.amountUSD) == [3.10, 4.25, 5.00])
        #expect(events.first?.provider == .amazonKDP)
        #expect(events.first?.utmContent == "Guide One")
    }

    @Test
    func bandcampCSVIngestProducesExpectedEvents() throws {
        let csv = """
        date,item type,item name,amount you received,currency
        2026-05-01,album,Loops Vol 1,7.00,USD
        2026-05-02,track,Loop A,1.50,USD
        2026-05-03,merch,Sticker,2.25,USD
        """

        let events = try BandcampCSVIngest.ingest(csv: csv, companyID: "bandcamp-co")

        #expect(events.count == 3)
        #expect(events.map(\.amountUSD) == [7.00, 1.50, 2.25])
        #expect(events.first?.provider == .bandcamp)
        #expect(events.first?.providerReference == "Loops Vol 1")
    }

    @Test
    func appStoreCSVIngestProducesExpectedEvents() throws {
        let csv = """
        Begin Date,Title,SKU,Developer Proceeds,Currency of Proceeds
        2026-05-01,App Pro,app.pro,2.99,USD
        2026-05-02,App Pro,app.pro,2.99,USD
        2026-05-03,App Team,app.team,9.99,USD
        """

        let events = try AppStoreCSVIngest.ingest(csv: csv, companyID: "appstore-co")

        #expect(events.count == 3)
        #expect(events.map(\.amountUSD) == [2.99, 2.99, 9.99])
        #expect(events.first?.provider == .appStore)
        #expect(events.last?.providerReference == "app.team")
    }

    @Test
    func googlePlayCSVIngestProducesExpectedEvents() throws {
        let csv = """
        Transaction Date,Product id,Charged Amount,Currency of Sale
        2026-05-01,com.os1.pro,1.99,USD
        2026-05-02,com.os1.pro,1.99,USD
        2026-05-03,com.os1.team,6.99,USD
        """

        let events = try GooglePlayCSVIngest.ingest(csv: csv, companyID: "play-co")

        #expect(events.count == 3)
        #expect(events.map(\.amountUSD) == [1.99, 1.99, 6.99])
        #expect(events.first?.provider == .googlePlay)
        #expect(events.last?.metadata?["csv_row"] == "4")
    }
}
