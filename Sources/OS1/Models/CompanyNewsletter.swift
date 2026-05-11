import Foundation

enum ESPProvider: String, Codable, CaseIterable, Hashable {
    case beehiiv
    case convertKit
    case mailchimp
    case substack
}

struct CompanyNewsletter: Codable, Hashable, Identifiable {
    struct Segment: Codable, Hashable, Identifiable {
        var id: String
        var name: String
    }

    var id: String { companyID }
    var companyID: String
    var provider: ESPProvider
    var publicationID: String
    var archiveURL: URL
    var audienceSegments: [Segment]
    var sendCadence: String
    var unsubscribeURL: URL
    var physicalAddress: String
}

struct NewsletterIssue: Codable, Hashable, Identifiable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case draft
        case approvalRequired
        case scheduled
        case sent
        case blocked
    }

    var id: String
    var companyID: String
    var subject: String
    var markdown: String
    var html: String?
    var scheduledAt: Date?
    var status: Status
}

enum CompanyNewsletterPipeline {
    static func renderHTML(issue: NewsletterIssue, newsletter: CompanyNewsletter) -> NewsletterIssue {
        var rendered = issue
        let escaped = issue.markdown
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: "\n", with: "<br>")
        rendered.html = """
        <article><h1>\(issue.subject)</h1><div>\(escaped)</div><footer><a href="\(newsletter.unsubscribeURL.absoluteString)">Unsubscribe</a><p>\(newsletter.physicalAddress)</p></footer></article>
        """
        return rendered
    }

    static func complianceDecision(issue: NewsletterIssue, newsletter: CompanyNewsletter) -> CompanyComplianceDecision {
        let content = "\(issue.markdown) \(issue.html ?? "")"
        guard content.localizedCaseInsensitiveContains(newsletter.unsubscribeURL.absoluteString),
              content.localizedCaseInsensitiveContains(newsletter.physicalAddress)
        else {
            return CompanyComplianceDecision(
                status: .blocked,
                findings: [
                    CompanyComplianceFinding(
                        id: "can-spam-footer-missing",
                        severity: .blocked,
                        message: "Email draft is missing CAN-SPAM footer fields.",
                        fix: "Render unsubscribe URL and physical mailing address before scheduling."
                    )
                ]
            )
        }
        return .approved
    }

    static func metrics(provider: ESPProvider, payload: Data, companyID: String, campaignID: String) throws -> CompanyGrowthResult {
        struct Metrics: Decodable {
            let opens: Int
            let clicks: Int
            let unsubscribes: Int
        }
        let metrics = try JSONDecoder().decode(Metrics.self, from: payload)
        return CompanyGrowthResult(
            companyID: companyID,
            campaignID: campaignID,
            impressions: metrics.opens,
            clicks: metrics.clicks,
            replies: 0,
            conversions: 0,
            revenueUSD: 0,
            costUSD: 0,
            sourceReference: provider.rawValue
        )
    }
}

enum ESPProviderCatalog {
    static let providers: [ESPProvider: (dashboard: URL, docs: URL)] = [
        .beehiiv: (URL(string: "https://app.beehiiv.com")!, URL(string: "https://developers.beehiiv.com")!),
        .convertKit: (URL(string: "https://app.convertkit.com")!, URL(string: "https://developers.kit.com")!),
        .mailchimp: (URL(string: "https://mailchimp.com")!, URL(string: "https://mailchimp.com/developer")!),
        .substack: (URL(string: "https://substack.com")!, URL(string: "https://support.substack.com")!)
    ]
}
