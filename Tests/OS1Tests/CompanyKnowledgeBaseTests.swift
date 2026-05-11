import Foundation
import Testing
@testable import OS1

struct CompanyKnowledgeBaseTests {
    @Test
    func ingestChunkRetrieveAndFreshnessWork() throws {
        var access = CompanyAccessControl.lockedDown(companyID: "co")
        access.embeddingProviderAllowlist = ["openai"]
        let fetchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let kb = try #require(CompanyKnowledgeBaseService.ingestMarkdown(
            companyID: "co",
            sourceID: "faq",
            markdown: "Refund policy: customers can request a refund within 14 days. Shipping takes five days.",
            provenance: "fixture://faq",
            fetchedAt: fetchedAt,
            refreshCadenceHours: 24,
            embeddingProvider: "openai",
            accessControl: access
        ))

        let retrievals = CompanyKnowledgeBaseService.retrieve(query: "what is your refund policy", kb: kb, k: 1)

        #expect(!kb.chunks.isEmpty)
        #expect(kb.sources.first?.isStale(at: fetchedAt.addingTimeInterval(86_500)) == true)
        #expect(retrievals.first?.chunk.text.contains("refund within 14 days") == true)
    }

    @Test
    func fixtureRefundReplyQuotesRetrievedChunkWithinFifteenWords() throws {
        var access = CompanyAccessControl.lockedDown(companyID: "co")
        access.embeddingProviderAllowlist = ["openai"]
        let kb = try #require(CompanyKnowledgeBaseService.ingestMarkdown(
            companyID: "co",
            sourceID: "homepage-faq",
            markdown: "Our refund policy allows refunds within 14 days for any unused digital product. Customers email support@example.com.",
            provenance: "fixture://homepage-faq",
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            embeddingProvider: "openai",
            accessControl: access
        ))
        let reply = try #require(CompanyKnowledgeBaseService.draftGroundedReply(
            question: "what's your refund policy",
            retrievals: CompanyKnowledgeBaseService.retrieve(query: "refund policy", kb: kb, k: 1)
        ))

        #expect(reply.split(whereSeparator: \.isWhitespace).count <= 15)
        #expect(reply.contains("refund policy allows refunds within 14 days"))
    }

    @Test
    func hallucinationCheckUsesCompanyKnowledgeBase() throws {
        var access = CompanyAccessControl.lockedDown(companyID: "co")
        access.embeddingProviderAllowlist = ["openai"]
        let kb = try #require(CompanyKnowledgeBaseService.ingestMarkdown(
            companyID: "co",
            sourceID: "faq",
            markdown: "The product costs $19 and includes a 14-day refund period.",
            provenance: "fixture://faq",
            fetchedAt: Date(timeIntervalSince1970: 1_800_000_000),
            embeddingProvider: "openai",
            accessControl: access
        ))

        let flags = CompanyKnowledgeBaseService.hallucinationFlags(draft: "The product costs $99 and has an 88% success rate.", kb: kb)

        #expect(flags.contains { $0.contains("$99") || $0.contains("88%") })
    }
}
