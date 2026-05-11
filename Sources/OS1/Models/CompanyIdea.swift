import Foundation

struct CompanyIdea: Identifiable, Codable, Hashable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case backlog
        case validating
        case rejected
        case launched
    }

    enum RiskTier: String, Codable, CaseIterable, Hashable {
        case low
        case medium
        case high
        case critical
    }

    struct Scorecard: Codable, Hashable {
        var customerPain: Int
        var willingnessToPay: Int
        var distributionChannel: Int
        var legalComplianceRisk: Int
        var buildComplexity: Int
        var timeToFirstDollar: Int
        var credentialReadiness: Int

        var total: Int {
            customerPain + willingnessToPay + distributionChannel + legalComplianceRisk + buildComplexity + timeToFirstDollar + credentialReadiness
        }
    }

    let id: String
    var title: String
    var sourceTemplateID: String?
    var status: Status
    var icp: String
    var offer: String
    var channel: String
    var riskTier: RiskTier
    var expectedFirstExperiment: String
    var requiredCredentials: [String]
    var evidenceLinks: [String]
    var rationale: String
    var rejectionReason: String?
    var nextAction: String
    var scorecard: Scorecard

    var score: Int { scorecard.total }

    var canAdvanceToValidation: Bool {
        !icp.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !offer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !channel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !expectedFirstExperiment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !evidenceLinks.isEmpty
    }
}

enum CompanyIdeaEngine {
    static func candidates(
        from templates: [CompanyTemplate] = CompanyTemplateCatalog.all,
        limit: Int = 50
    ) -> [CompanyIdea] {
        var seen = Set<String>()
        let ideas = templates.compactMap { template -> CompanyIdea? in
            let key = dedupeKey(template.title)
            guard seen.insert(key).inserted else { return nil }
            return idea(from: template)
        }
        return Array(rank(ideas).prefix(max(0, limit)))
    }

    static func topIdeas(count: Int = 10, from ideas: [CompanyIdea]? = nil) -> [CompanyIdea] {
        Array(rank(ideas ?? candidates(limit: 50)).prefix(max(0, count)))
    }

    static func advanceToValidation(_ idea: CompanyIdea) -> CompanyIdea? {
        guard idea.canAdvanceToValidation else { return nil }
        var advanced = idea
        advanced.status = .validating
        advanced.nextAction = idea.expectedFirstExperiment
        return advanced
    }

    static func rank(_ ideas: [CompanyIdea]) -> [CompanyIdea] {
        ideas.sorted {
            if $0.score == $1.score { return $0.title < $1.title }
            return $0.score > $1.score
        }
    }

    private static func idea(from template: CompanyTemplate) -> CompanyIdea {
        let riskTier = riskTier(for: template)
        let scorecard = scorecard(for: template, riskTier: riskTier)
        let evidence = template.validationSignals.enumerated().map { index, signal in
            "template://\(template.id)/validation/\(index + 1)-\(slug(signal))"
        }
        return CompanyIdea(
            id: "idea-\(template.id)",
            title: template.title,
            sourceTemplateID: template.id,
            status: .backlog,
            icp: icp(for: template),
            offer: offer(for: template),
            channel: template.channel,
            riskTier: riskTier,
            expectedFirstExperiment: template.validationSignals.first ?? "Interview 5 target buyers and record willingness to pay.",
            requiredCredentials: credentials(for: template),
            evidenceLinks: evidence,
            rationale: "Scores well on \(template.validationSignals.prefix(2).joined(separator: " and ")). \(template.mission)",
            rejectionReason: nil,
            nextAction: template.validationSignals.first ?? "Collect demand evidence",
            scorecard: scorecard
        )
    }

    private static func scorecard(for template: CompanyTemplate, riskTier: CompanyIdea.RiskTier) -> CompanyIdea.Scorecard {
        CompanyIdea.Scorecard(
            customerPain: scorePain(template),
            willingnessToPay: scoreWillingness(template),
            distributionChannel: scoreDistribution(template),
            legalComplianceRisk: riskScore(riskTier),
            buildComplexity: buildComplexityScore(template),
            timeToFirstDollar: timeToFirstDollarScore(template),
            credentialReadiness: credentialReadinessScore(template)
        )
    }

    private static func scorePain(_ template: CompanyTemplate) -> Int {
        let text = template.searchText
        if text.contains("lead") || text.contains("missed") || text.contains("intake") || text.contains("follow-up") { return 9 }
        if text.contains("tracker") || text.contains("checklist") || text.contains("workflow") { return 8 }
        return 7
    }

    private static func scoreWillingness(_ template: CompanyTemplate) -> Int {
        switch template.category {
        case .leadGeneration, .automationService, .microSaaS, .productizedService: return 9
        case .realEstate, .kdp, .digitalProducts: return 7
        case .newsletter, .affiliate, .creatorMedia: return 6
        }
    }

    private static func scoreDistribution(_ template: CompanyTemplate) -> Int {
        let channel = template.channel.lowercased()
        if channel.contains("seo") || channel.contains("etsy") || channel.contains("amazon") { return 8 }
        if channel.contains("outreach") || channel.contains("newsletter") { return 7 }
        return 6
    }

    private static func riskScore(_ tier: CompanyIdea.RiskTier) -> Int {
        switch tier {
        case .low: return 9
        case .medium: return 7
        case .high: return 4
        case .critical: return 1
        }
    }

    private static func buildComplexityScore(_ template: CompanyTemplate) -> Int {
        switch template.category {
        case .digitalProducts, .kdp, .newsletter, .affiliate: return 8
        case .creatorMedia, .productizedService: return 7
        case .leadGeneration, .automationService, .realEstate: return 6
        case .microSaaS: return 4
        }
    }

    private static func timeToFirstDollarScore(_ template: CompanyTemplate) -> Int {
        switch template.category {
        case .digitalProducts, .productizedService, .automationService: return 8
        case .kdp, .leadGeneration, .realEstate: return 6
        case .newsletter, .affiliate, .creatorMedia, .microSaaS: return 5
        }
    }

    private static func credentialReadinessScore(_ template: CompanyTemplate) -> Int {
        let count = credentials(for: template).count
        if count == 0 { return 9 }
        if count <= 2 { return 7 }
        return 5
    }

    private static func riskTier(for template: CompanyTemplate) -> CompanyIdea.RiskTier {
        let text = template.searchText
        if text.contains("medical") || text.contains("legal") || text.contains("financial") || text.contains("tax") || text.contains("hipaa") {
            return .high
        }
        if text.contains("privacy") || text.contains("claims") || text.contains("messaging consent") || text.contains("fair-housing") {
            return .medium
        }
        return .low
    }

    private static func credentials(for template: CompanyTemplate) -> [String] {
        let text = template.searchText
        var names: [String] = []
        if text.contains("stripe") || text.contains("checkout") { names.append("STRIPE_API_KEY") }
        if text.contains("email") || text.contains("newsletter") { names.append("RESEND_API_KEY") }
        if text.contains("youtube") { names.append("YOUTUBE_API_KEY") }
        if text.contains("etsy") { names.append("ETSY_API_KEY") }
        if text.contains("shopify") { names.append("SHOPIFY_API_KEY") }
        return names
    }

    private static func icp(for template: CompanyTemplate) -> String {
        switch template.category {
        case .digitalProducts: return "Marketplace buyer searching for a ready-to-use \(template.title.lowercased())."
        case .kdp: return "Amazon buyer looking for a focused workbook, guide, or activity book."
        case .creatorMedia: return "Viewer with repeated search intent around \(template.channel)."
        case .newsletter: return "Subscriber with recurring information need and sponsor-fit audience."
        case .leadGeneration: return "Local service provider willing to buy qualified customer inquiries."
        case .realEstate: return "Investor, agent, landlord, or relocation buyer needing sourced local data."
        case .automationService: return "Small business operator with a repetitive workflow and clear ROI pain."
        case .microSaaS: return "Niche operator who needs a lightweight self-serve tool."
        case .affiliate: return "Buyer-intent searcher comparing tools or products before purchase."
        case .productizedService: return "Business owner or creator willing to pay for a done-for-you deliverable."
        }
    }

    private static func offer(for template: CompanyTemplate) -> String {
        "Validate and sell: \(template.mission)"
    }

    private static func dedupeKey(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(6)
            .joined(separator: "-")
    }

    private static func slug(_ value: String) -> String {
        value.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }
            .prefix(8)
            .joined(separator: "-")
    }
}
