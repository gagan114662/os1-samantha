import Foundation

enum MarketplaceCSVIngestError: Error, Equatable {
    case missingColumn(String)
    case invalidAmount(row: Int, column: String)
}

enum EtsyCSVIngest {
    static func providerEvents(
        csv: String,
        companyID: String,
        fxConverter: (Double, String) -> Double = { amount, _ in amount }
    ) throws -> [CompanyPaymentProviderEvent] {
        try MarketplaceCSVParser.providerEvents(
            csv: csv,
            companyID: companyID,
            provider: .etsy,
            requiredColumns: ["Order ID", "Date", "Item Total", "Currency", "SKU"],
            idColumn: "Order ID",
            dateColumn: "Date",
            amountColumn: "Item Total",
            currencyColumn: "Currency",
            referenceColumn: "Order ID",
            contentColumn: "SKU",
            fxConverter: fxConverter
        )
    }

    static func ingest(
        csv: String,
        companyID: String,
        fxConverter: (Double, String) -> Double = { amount, _ in amount }
    ) throws -> [CompanyPaymentConversionEvent] {
        try MarketplaceCSVParser.events(
            csv: csv,
            companyID: companyID,
            provider: .etsy,
            requiredColumns: ["Order ID", "Date", "Item Total", "Currency", "SKU"],
            idColumn: "Order ID",
            dateColumn: "Date",
            amountColumn: "Item Total",
            currencyColumn: "Currency",
            referenceColumn: "Order ID",
            contentColumn: "SKU",
            fxConverter: fxConverter
        )
    }
}

enum KDPCSVIngest {
    static func ingest(
        csv: String,
        companyID: String,
        fxConverter: (Double, String) -> Double = { amount, _ in amount }
    ) throws -> [CompanyPaymentConversionEvent] {
        try MarketplaceCSVParser.events(
            csv: csv,
            companyID: companyID,
            provider: .amazonKDP,
            requiredColumns: ["Royalty Date", "Title", "ASIN", "Royalty", "Currency"],
            idColumn: "ASIN",
            dateColumn: "Royalty Date",
            amountColumn: "Royalty",
            currencyColumn: "Currency",
            referenceColumn: "ASIN",
            contentColumn: "Title",
            fxConverter: fxConverter
        )
    }
}

enum BandcampCSVIngest {
    static func ingest(
        csv: String,
        companyID: String,
        fxConverter: (Double, String) -> Double = { amount, _ in amount }
    ) throws -> [CompanyPaymentConversionEvent] {
        try MarketplaceCSVParser.events(
            csv: csv,
            companyID: companyID,
            provider: .bandcamp,
            requiredColumns: ["date", "item type", "item name", "amount you received", "currency"],
            idColumn: "item name",
            dateColumn: "date",
            amountColumn: "amount you received",
            currencyColumn: "currency",
            referenceColumn: "item name",
            contentColumn: "item type",
            fxConverter: fxConverter
        )
    }
}

enum AppStoreCSVIngest {
    static func ingest(
        csv: String,
        companyID: String,
        fxConverter: (Double, String) -> Double = { amount, _ in amount }
    ) throws -> [CompanyPaymentConversionEvent] {
        try MarketplaceCSVParser.events(
            csv: csv,
            companyID: companyID,
            provider: .appStore,
            requiredColumns: ["Begin Date", "Title", "SKU", "Developer Proceeds", "Currency of Proceeds"],
            idColumn: "SKU",
            dateColumn: "Begin Date",
            amountColumn: "Developer Proceeds",
            currencyColumn: "Currency of Proceeds",
            referenceColumn: "SKU",
            contentColumn: "Title",
            fxConverter: fxConverter
        )
    }
}

enum GooglePlayCSVIngest {
    static func ingest(
        csv: String,
        companyID: String,
        fxConverter: (Double, String) -> Double = { amount, _ in amount }
    ) throws -> [CompanyPaymentConversionEvent] {
        try MarketplaceCSVParser.events(
            csv: csv,
            companyID: companyID,
            provider: .googlePlay,
            requiredColumns: ["Transaction Date", "Product id", "Charged Amount", "Currency of Sale"],
            idColumn: "Product id",
            dateColumn: "Transaction Date",
            amountColumn: "Charged Amount",
            currencyColumn: "Currency of Sale",
            referenceColumn: "Product id",
            contentColumn: "Product id",
            fxConverter: fxConverter
        )
    }
}

enum MarketplaceCSVParser {
    static func providerEvents(
        csv: String,
        companyID: String,
        provider: CompanyPaymentConversionEvent.Provider,
        requiredColumns: [String],
        idColumn: String,
        dateColumn: String,
        amountColumn: String,
        currencyColumn: String,
        referenceColumn: String,
        contentColumn: String,
        fxConverter: (Double, String) -> Double
    ) throws -> [CompanyPaymentProviderEvent] {
        try events(
            csv: csv,
            companyID: companyID,
            provider: provider,
            requiredColumns: requiredColumns,
            idColumn: idColumn,
            dateColumn: dateColumn,
            amountColumn: amountColumn,
            currencyColumn: currencyColumn,
            referenceColumn: referenceColumn,
            contentColumn: contentColumn,
            fxConverter: fxConverter
        ).map(CompanyPaymentProviderEvent.init(conversionEvent:))
    }

    static func events(
        csv: String,
        companyID: String,
        provider: CompanyPaymentConversionEvent.Provider,
        requiredColumns: [String],
        idColumn: String,
        dateColumn: String,
        amountColumn: String,
        currencyColumn: String,
        referenceColumn: String,
        contentColumn: String,
        fxConverter: (Double, String) -> Double
    ) throws -> [CompanyPaymentConversionEvent] {
        let rows = parse(csv)
        guard let header = rows.first else { return [] }
        let indexes = Dictionary(uniqueKeysWithValues: header.enumerated().map { ($0.element, $0.offset) })
        for column in requiredColumns where indexes[column] == nil {
            throw MarketplaceCSVIngestError.missingColumn(column)
        }

        return try rows.dropFirst().enumerated().compactMap { offset, row in
            let rowNumber = offset + 2
            let rawAmount = value(row, indexes[amountColumn]).replacingOccurrences(of: "$", with: "")
            guard let amount = Double(rawAmount.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw MarketplaceCSVIngestError.invalidAmount(row: rowNumber, column: amountColumn)
            }
            let currency = value(row, indexes[currencyColumn]).uppercased()
            let rawID = value(row, indexes[idColumn])
            let reference = value(row, indexes[referenceColumn])
            let content = value(row, indexes[contentColumn])
            return CompanyPaymentConversionEvent(
                id: "\(provider.rawValue)-\(rawID)-row-\(rowNumber)",
                companyID: companyID,
                provider: provider,
                kind: .checkoutCompleted,
                amountUSD: fxConverter(amount, currency),
                currency: currency,
                utmCampaign: companyID,
                utmContent: content,
                providerReference: reference,
                occurredAt: parseDate(value(row, indexes[dateColumn])),
                metadata: [
                    "company_id": companyID,
                    "csv_row": "\(rowNumber)",
                    "payment_intent": reference,
                    "amount_total": "\(amount)"
                ]
            )
        }
    }

    private static func value(_ row: [String], _ index: Int?) -> String {
        guard let index, row.indices.contains(index) else { return "" }
        return row[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parseDate(_ raw: String) -> Date {
        let formats = ["yyyy-MM-dd", "MM/dd/yyyy", "yyyy/MM/dd", "MMM d, yyyy"]
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) { return date }
        }
        return Date(timeIntervalSince1970: 0)
    }

    private static func parse(_ csv: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var iterator = csv.makeIterator()

        while let character = iterator.next() {
            if character == "\"" {
                if inQuotes, let next = iterator.next() {
                    if next == "\"" {
                        field.append("\"")
                    } else {
                        inQuotes = false
                        if next == "," {
                            row.append(field)
                            field = ""
                        } else if next == "\n" {
                            row.append(field)
                            rows.append(row)
                            row = []
                            field = ""
                        } else if next != "\r" {
                            field.append(next)
                        }
                    }
                } else {
                    inQuotes.toggle()
                }
            } else if character == ",", !inQuotes {
                row.append(field)
                field = ""
            } else if character == "\n", !inQuotes {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else if character != "\r" {
                field.append(character)
            }
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows.filter { !$0.allSatisfy { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    }
}
