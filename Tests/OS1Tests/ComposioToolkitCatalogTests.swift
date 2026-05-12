import Foundation
import Testing
@testable import OS1

struct ComposioToolkitCatalogTests {
    @Test
    func curatedToolkitsIncludeSocialPlatformsAndMetadata() {
        let toolkits = ComposioToolkitService.curatedToolkits
        let slugs = Set(toolkits.map(\.slug))
        let required: Set<String> = [
            "twitter",
            "linkedin",
            "instagram",
            "tiktok",
            "youtube",
            "reddit",
            "pinterest",
            "discord",
            "telegram",
            "threads"
        ]

        #expect(toolkits.count >= 18)
        #expect(required.isSubset(of: slugs))
        #expect(!toolkits.filter { $0.tag == .social }.isEmpty)
        #expect(!toolkits.filter { $0.tag == .video }.isEmpty)
        #expect(!toolkits.filter { $0.tag == .marketing }.isEmpty)
        #expect(!toolkits.filter { $0.tag == .community }.isEmpty)

        for toolkit in toolkits {
            #expect(!toolkit.requiredScopes.isEmpty, "\(toolkit.slug) should show scopes before OAuth.")
            if toolkit.tag == .social || toolkit.tag == .video || toolkit.tag == .community {
                #expect(toolkit.riskTier != .low, "\(toolkit.slug) should not be low risk.")
            }
        }
    }

    @Test
    func socialToolkitGrantsRequireApprovalDuringFirstSevenCleanDays() throws {
        let twitter = try #require(ComposioToolkitService.curatedToolkits.first { $0.slug == "twitter" })
        let notion = try #require(ComposioToolkitService.curatedToolkits.first { $0.slug == "notion" })
        let access = CompanyAccessControl(
            companyID: "co-1",
            mediaProviderAllowlist: [],
            seoProviderAllowlist: [],
            composioToolkitAllowlist: ["twitter", "notion"],
            embeddingProviderAllowlist: [],
            experimentationEnabled: false
        )

        let earlyTwitter = access.composioToolkitAccess(for: twitter, cleanHistoryDays: 0)
        let matureTwitter = access.composioToolkitAccess(for: twitter, cleanHistoryDays: 7)
        let notionDecision = access.composioToolkitAccess(for: notion, cleanHistoryDays: 0)

        #expect(earlyTwitter.status == .approvalRequired)
        #expect(earlyTwitter.requiresApproval)
        #expect(matureTwitter.status == .allowed)
        #expect(!notionDecision.requiresApproval)
        #expect(notionDecision.status == .allowed)
        #expect(access.composioToolkitAccess(for: twitter, cleanHistoryDays: 0).status.rawValue == "approval_required")
    }
}
