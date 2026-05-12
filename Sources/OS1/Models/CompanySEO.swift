import Foundation

struct CompanyKeywordCandidate: Codable, Hashable, Identifiable {
    var id: String { keyword }
    var keyword: String
    var volume: Int
    var keywordDifficulty: Double
    var cpcUSD: Double
    var intent: String
}

struct CompanySERPResult: Codable, Hashable, Identifiable {
    var id: String { url.absoluteString }
    var title: String
    var url: URL
    var rank: Int
    var snippet: String
}

struct CompanyKeywordRank: Codable, Hashable, Identifiable {
    var id: String { "\(companyID)-\(keyword)-\(date.timeIntervalSince1970)" }
    var companyID: String
    var date: Date
    var keyword: String
    var rank: Int?
    var url: URL?
    var snippet: String?
}

enum SEOToolProvider: String, Codable, CaseIterable, Hashable {
    case dataForSEO
    case serpAPI
    case googleSearchConsole
}

struct CompanySEOProviderHealth: Codable, Hashable {
    var provider: SEOToolProvider
    var quotaRemaining: Int?
    var lastSuccessfulCall: Date?
    var errorCount: Int
    var costUSD: Double
}

enum CompanyKeywordResearch {
    static func expand(provider: SEOToolProvider, payload: Data) throws -> [CompanyKeywordCandidate] {
        struct Row: Decodable {
            let keyword: String
            let volume: Int
            let kd: Double
            let cpc: Double
            let intent: String
        }
        let rows = try JSONDecoder().decode([Row].self, from: payload)
        return rows.map { .init(keyword: $0.keyword, volume: $0.volume, keywordDifficulty: $0.kd, cpcUSD: $0.cpc, intent: $0.intent) }
    }

    static func serp(provider: SEOToolProvider, payload: Data) throws -> [CompanySERPResult] {
        struct Row: Decodable {
            let title: String
            let url: URL
            let rank: Int
            let snippet: String
        }
        return try JSONDecoder().decode([Row].self, from: payload).map {
            CompanySERPResult(title: $0.title, url: $0.url, rank: $0.rank, snippet: $0.snippet)
        }
    }

    static func cache<T: Encodable>(_ value: T, key: String, directory: URL) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("\(key).json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: file, options: .atomic)
        return file
    }

    static func cached<T: Decodable>(_ type: T.Type, key: String, directory: URL) throws -> T? {
        let file = directory.appendingPathComponent("\(key).json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return try JSONDecoder().decode(type, from: Data(contentsOf: file))
    }

    static func proposeOutline(keyword: String, serp: [CompanySERPResult]) -> [String] {
        let gaps = serp.prefix(5).map { "Cover what '\($0.title)' misses for \(keyword)" }
        return ["Intent: answer \(keyword) with sourced proof", "Comparison table", "FAQ section"] + gaps
    }
}

enum CompanyRankTracker {
    static func ingest(companyID: String, keyword: String, serp: [CompanySERPResult], targetDomain: String, date: Date) -> CompanyKeywordRank {
        let match = serp.first { $0.url.host?.contains(targetDomain) == true }
        return CompanyKeywordRank(
            companyID: companyID,
            date: date,
            keyword: keyword,
            rank: match?.rank,
            url: match?.url,
            snippet: match?.snippet
        )
    }
}
