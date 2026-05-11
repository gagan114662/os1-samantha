import Foundation
import Testing
@testable import OS1

struct CompanyNewsletterTests {
    @Test
    func newsletterModelsRoundTripCodable() throws {
        let newsletter = fixtureNewsletter()
        let issue = NewsletterIssue(id: "issue-1", companyID: "co", subject: "Weekly", markdown: "Hello", html: nil, scheduledAt: nil, status: .draft)

        let decodedNewsletter = try JSONDecoder().decode(CompanyNewsletter.self, from: JSONEncoder().encode(newsletter))
        let decodedIssue = try JSONDecoder().decode(NewsletterIssue.self, from: JSONEncoder().encode(issue))

        #expect(decodedNewsletter == newsletter)
        #expect(decodedIssue == issue)
    }

    @Test
    func missingCANSPAMFooterBlocksDraft() {
        let newsletter = fixtureNewsletter()
        let issue = NewsletterIssue(id: "issue-1", companyID: "co", subject: "Weekly", markdown: "No footer here", html: nil, scheduledAt: nil, status: .draft)

        let decision = CompanyNewsletterPipeline.complianceDecision(issue: issue, newsletter: newsletter)

        #expect(decision.status == .blocked)
        #expect(decision.findings.first?.id == "can-spam-footer-missing")
    }

    @Test
    func renderAddsFooterAndESPFixturesIngestMetrics() throws {
        let newsletter = fixtureNewsletter()
        let issue = NewsletterIssue(id: "issue-1", companyID: "co", subject: "Weekly", markdown: "Hello", html: nil, scheduledAt: nil, status: .draft)
        let rendered = CompanyNewsletterPipeline.renderHTML(issue: issue, newsletter: newsletter)
        let decision = CompanyNewsletterPipeline.complianceDecision(issue: rendered, newsletter: newsletter)
        let metrics = try CompanyNewsletterPipeline.metrics(
            provider: .beehiiv,
            payload: Data(#"{"opens":100,"clicks":15,"unsubscribes":1}"#.utf8),
            companyID: "co",
            campaignID: "issue-1"
        )

        #expect(decision.status == .approved)
        #expect(metrics.impressions == 100)
        #expect(metrics.clicks == 15)
    }

    @Test
    func espProviderCatalogIncludesCoreProviders() {
        #expect(ESPProviderCatalog.providers[.beehiiv]?.docs.scheme == "https")
        #expect(ESPProviderCatalog.providers[.convertKit]?.docs.scheme == "https")
        #expect(ESPProviderCatalog.providers[.mailchimp]?.docs.scheme == "https")
    }

    private func fixtureNewsletter() -> CompanyNewsletter {
        CompanyNewsletter(
            companyID: "co",
            provider: .beehiiv,
            publicationID: "pub",
            archiveURL: URL(string: "https://example.com/archive")!,
            audienceSegments: [.init(id: "all", name: "All")],
            sendCadence: "0 9 * * 1",
            unsubscribeURL: URL(string: "https://example.com/unsubscribe")!,
            physicalAddress: "123 Main St, Toronto, ON"
        )
    }
}
