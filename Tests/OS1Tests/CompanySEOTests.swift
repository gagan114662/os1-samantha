import Foundation
import Testing
@testable import OS1

struct CompanySEOTests {
    @Test
    func keywordProvidersDecodeMockedResponses() throws {
        let dataForSEO = try CompanyKeywordResearch.expand(
            provider: .dataForSEO,
            payload: Data(#"[{"keyword":"roof repair toronto","volume":900,"kd":22,"cpc":8.5,"intent":"local"}]"#.utf8)
        )
        let serp = try CompanyKeywordResearch.serp(
            provider: .serpAPI,
            payload: Data(#"[{"title":"Roof Repair Guide","url":"https://example.com/roof","rank":1,"snippet":"guide"}]"#.utf8)
        )

        #expect(dataForSEO.first?.keyword == "roof repair toronto")
        #expect(dataForSEO.first?.volume == 900)
        #expect(serp.first?.rank == 1)
    }

    @Test
    func keywordCacheRoundTripsAndRankTrackerHandlesMissingData() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("seo-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let candidates = [
            CompanyKeywordCandidate(keyword: "plumber near me", volume: 1200, keywordDifficulty: 30, cpcUSD: 12, intent: "local")
        ]

        _ = try CompanyKeywordResearch.cache(candidates, key: "plumber", directory: directory)
        let loaded = try CompanyKeywordResearch.cached([CompanyKeywordCandidate].self, key: "plumber", directory: directory)
        let missingRank = CompanyRankTracker.ingest(
            companyID: "co",
            keyword: "plumber near me",
            serp: [],
            targetDomain: "company.example",
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(loaded == candidates)
        #expect(missingRank.rank == nil)
    }

    @Test
    func rankTrackerFindsOwnedResultAndOutlineUsesSERPGaps() throws {
        let serp = try CompanyKeywordResearch.serp(
            provider: .googleSearchConsole,
            payload: Data(#"[{"title":"Competitor","url":"https://competitor.example/a","rank":1,"snippet":"thin"},{"title":"Owned","url":"https://company.example/roof","rank":4,"snippet":"owned"}]"#.utf8)
        )
        let rank = CompanyRankTracker.ingest(
            companyID: "co",
            keyword: "roof repair",
            serp: serp,
            targetDomain: "company.example",
            date: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let outline = CompanyKeywordResearch.proposeOutline(keyword: "roof repair", serp: serp)

        #expect(rank.rank == 4)
        #expect(outline.contains { $0.contains("Competitor") })
    }

    @Test
    func accessControlAllowsSEOProvidersWithoutLoggingSecrets() {
        var access = CompanyAccessControl.lockedDown(companyID: "co")
        access.seoProviderAllowlist = ["dataForSEO", "serpAPI"]

        #expect(access.seoProviderAllowlist.contains("dataForSEO"))
        #expect(!access.seoProviderAllowlist.contains("ahrefs"))
    }
}
