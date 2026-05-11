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

        for toolkit in toolkits {
            #expect(!toolkit.requiredScopes.isEmpty, "\(toolkit.slug) should show scopes before OAuth.")
            if toolkit.tag == .social || toolkit.tag == .video || toolkit.tag == .community {
                #expect(toolkit.riskTier != .low, "\(toolkit.slug) should not be low risk.")
            }
        }
    }
}
