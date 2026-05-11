import Foundation

struct CompanyBusinessModelPlaybook: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case microSaaS
        case leadGenAsset
        case paidAutomationService
        case nicheResearchNewsletter
        case marketplaceProductizedService
    }

    var id: String
    var kind: Kind
    var title: String
    var requiredIntegrations: [String]
    var legalRisk: CompanyIdea.RiskTier
    var validationSteps: [String]
    var buildSteps: [String]
    var launchChecklist: [String]
    var metrics: [String]
    var killCriteria: [String]
    var prompt: String
    var dashboardSections: [String]
    var evals: [String]

    var isComplete: Bool {
        !requiredIntegrations.isEmpty &&
        !validationSteps.isEmpty &&
        !buildSteps.isEmpty &&
        !launchChecklist.isEmpty &&
        !metrics.isEmpty &&
        !killCriteria.isEmpty &&
        !prompt.isEmpty &&
        !dashboardSections.isEmpty &&
        !evals.isEmpty
    }
}

struct CompanyTemplateMatch: Codable, Hashable {
    var playbookID: String
    var score: Int
    var rationale: String
}

struct CompanyTemplateLifecycleGate: Codable, Hashable {
    var playbookID: String
    var stage: CodexSession.LifecycleStage
    var requiredEvidence: [String]

    func isSatisfied(by evidence: Set<String>) -> Bool {
        Set(requiredEvidence).isSubset(of: evidence)
    }
}

struct CompanyTemplatePerformance: Codable, Hashable, Identifiable {
    var id: String { playbookID }
    var playbookID: String
    var companyCount: Int
    var verifiedRevenueUSD: Double
    var conversionRate: Double
    var killedCount: Int
}

enum CompanyBusinessModelPlaybookCatalog {
    static let all: [CompanyBusinessModelPlaybook] = [
        playbook(
            id: "micro-saas",
            kind: .microSaaS,
            title: "Micro-SaaS",
            integrations: ["Stripe", "analytics", "email"],
            risk: .medium,
            validation: ["interview 5 niche operators", "collect 3 paid-intent signups", "test one pricing page"],
            build: ["ship single workflow", "add onboarding", "instrument activation"],
            launch: ["terms/privacy", "checkout test", "support inbox", "activation dashboard"],
            metrics: ["activation rate", "trial-to-paid", "MRR", "churn intent"],
            kill: ["no paid-intent signups", "CAC above first-month revenue", "critical compliance blocker"]
        ),
        playbook(
            id: "lead-gen-asset",
            kind: .leadGenAsset,
            title: "Lead-gen asset",
            integrations: ["forms", "CRM", "email"],
            risk: .medium,
            validation: ["verify buyer demand", "source 10 sample leads", "pre-sell one lead package"],
            build: ["create landing page", "build qualification form", "create lead delivery workflow"],
            launch: ["consent policy", "buyer contract", "lead QA checklist", "refund policy"],
            metrics: ["qualified leads", "lead acceptance", "refund rate", "buyer repeat intent"],
            kill: ["unqualified lead rate above 30%", "no buyer reply", "privacy or consent failure"]
        ),
        playbook(
            id: "paid-automation-service",
            kind: .paidAutomationService,
            title: "Paid automation service",
            integrations: ["calendar", "email", "Zapier or APIs"],
            risk: .low,
            validation: ["find repetitive workflow", "quote fixed-price pilot", "get written scope"],
            build: ["manual-first delivery", "automation checklist", "handoff recording"],
            launch: ["SOW", "acceptance checklist", "support SLA", "renewal offer"],
            metrics: ["hours saved", "gross margin", "delivery time", "renewal likelihood"],
            kill: ["scope cannot be bounded", "gross margin below 50%", "no repeatable workflow"]
        ),
        playbook(
            id: "niche-research-newsletter",
            kind: .nicheResearchNewsletter,
            title: "Niche research newsletter",
            integrations: ["email platform", "analytics", "sponsor CRM"],
            risk: .low,
            validation: ["collect 50 waitlist subscribers", "interview 3 sponsors", "publish sample issue"],
            build: ["research pipeline", "issue template", "sponsor inventory"],
            launch: ["unsubscribe flow", "claim review", "sponsor disclosure", "archive page"],
            metrics: ["subscriber growth", "open rate", "sponsor replies", "paid conversions"],
            kill: ["open rate below 25%", "no sponsor interest", "research cost exceeds revenue path"]
        ),
        playbook(
            id: "marketplace-productized-service",
            kind: .marketplaceProductizedService,
            title: "Marketplace productized service",
            integrations: ["marketplace account", "payments", "support inbox"],
            risk: .medium,
            validation: ["competitor review analysis", "price test", "draft fulfillment sample"],
            build: ["listing assets", "delivery SOP", "revision policy"],
            launch: ["platform policy review", "refund policy", "delivery QA", "review request policy"],
            metrics: ["listing views", "conversion rate", "delivery margin", "review quality"],
            kill: ["policy risk too high", "delivery margin below 40%", "no orders after test traffic"]
        )
    ]

    static func choose(for idea: CompanyIdea) -> CompanyTemplateMatch {
        let matches = all.map { playbook -> CompanyTemplateMatch in
            let score = matchScore(playbook: playbook, idea: idea)
            return CompanyTemplateMatch(
                playbookID: playbook.id,
                score: score,
                rationale: "\(playbook.title) matches \(idea.channel) and \(idea.offer)"
            )
        }
        return matches.sorted {
            if $0.score == $1.score { return $0.playbookID < $1.playbookID }
            return $0.score > $1.score
        }[0]
    }

    static func lifecycleGates(for playbookID: String) -> [CompanyTemplateLifecycleGate] {
        [
            CompanyTemplateLifecycleGate(
                playbookID: playbookID,
                stage: .validating,
                requiredEvidence: ["buyer-pain", "willingness-to-pay", "channel-proof"]
            ),
            CompanyTemplateLifecycleGate(
                playbookID: playbookID,
                stage: .building,
                requiredEvidence: ["smallest-sellable-asset", "checkout-or-lead-capture", "analytics"]
            ),
            CompanyTemplateLifecycleGate(
                playbookID: playbookID,
                stage: .launched,
                requiredEvidence: ["launch-checklist", "support-path", "risk-review"]
            ),
            CompanyTemplateLifecycleGate(
                playbookID: playbookID,
                stage: .revenuePositive,
                requiredEvidence: ["verified-revenue", "unit-economics"]
            )
        ]
    }

    static func comparePerformance(_ performance: [CompanyTemplatePerformance]) -> [CompanyTemplatePerformance] {
        performance.sorted {
            if $0.verifiedRevenueUSD == $1.verifiedRevenueUSD {
                return $0.conversionRate > $1.conversionRate
            }
            return $0.verifiedRevenueUSD > $1.verifiedRevenueUSD
        }
    }

    static func canReplicateBroadly(_ performance: [CompanyTemplatePerformance]) -> Bool {
        performance.contains { $0.verifiedRevenueUSD > 0 }
    }

    private static func playbook(
        id: String,
        kind: CompanyBusinessModelPlaybook.Kind,
        title: String,
        integrations: [String],
        risk: CompanyIdea.RiskTier,
        validation: [String],
        build: [String],
        launch: [String],
        metrics: [String],
        kill: [String]
    ) -> CompanyBusinessModelPlaybook {
        CompanyBusinessModelPlaybook(
            id: id,
            kind: kind,
            title: title,
            requiredIntegrations: integrations,
            legalRisk: risk,
            validationSteps: validation,
            buildSteps: build,
            launchChecklist: launch,
            metrics: metrics,
            killCriteria: kill,
            prompt: "Run the \(title) playbook from validation to verified revenue before scaling.",
            dashboardSections: ["validation", "build", "launch", "revenue", "kill/scale"],
            evals: ["playbook completeness", "gate evidence", "revenue traceability"]
        )
    }

    private static func matchScore(
        playbook: CompanyBusinessModelPlaybook,
        idea: CompanyIdea
    ) -> Int {
        let text = [idea.title, idea.channel, idea.offer, idea.icp].joined(separator: " ").lowercased()
        switch playbook.kind {
        case .microSaaS:
            return text.contains("saas") || text.contains("tool") ? 90 : 30
        case .leadGenAsset:
            return text.contains("lead") || text.contains("real estate") ? 88 : 35
        case .paidAutomationService:
            return text.contains("automation") || text.contains("workflow") ? 92 : 40
        case .nicheResearchNewsletter:
            return text.contains("newsletter") || text.contains("research") ? 86 : 28
        case .marketplaceProductizedService:
            return text.contains("etsy") || text.contains("marketplace") || text.contains("service") ? 89 : 34
        }
    }
}
