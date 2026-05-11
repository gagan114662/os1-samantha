import Foundation

struct CompanyValidationExperiment: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case customerInterviews
        case landingPage
        case waitlist
        case coldOutreach
        case marketplaceResearch
        case pricingTest
    }

    let id: String
    var kind: Kind
    var hypothesis: String
    var action: String
    var measurableThreshold: String
    var approvalRequired: Bool
    var draftOnly: Bool
    var artifactRequirements: [String]
}

struct CompanyValidationPlan: Codable, Hashable, Identifiable {
    let id: String
    var ideaID: String
    var experiments: [CompanyValidationExperiment]
    var successThreshold: CompanyValidationResult.Metrics
    var policy: CompanyValidationPolicy
    var sourceLinks: [String]
    var rawArtifactPaths: [String]

    var hasMeasurableThreshold: Bool {
        experiments.allSatisfy { !$0.measurableThreshold.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

struct CompanyValidationResult: Codable, Hashable {
    enum Decision: String, Codable, CaseIterable, Hashable {
        case rejected
        case needsMoreEvidence
        case readyToBuild
    }

    struct Metrics: Codable, Hashable {
        var interviewsCompleted: Int
        var replyRate: Double
        var signupRate: Double
        var willingnessToPayCount: Int
        var competitorDensity: Int
        var cacEstimateUSD: Double
        var timeToFirstDollarDays: Int
    }

    var ideaID: String
    var metrics: Metrics
    var sourceLinks: [String]
    var screenshots: [String]
    var rawResearchArtifacts: [String]
    var rationale: String
}

struct CompanyValidationDecision: Codable, Hashable {
    var decision: CompanyValidationResult.Decision
    var rationale: String
    var adjustedScorecard: CompanyIdea.Scorecard
}

struct CompanyValidationPolicy: Codable, Hashable {
    var minimumInterviews: Int
    var minimumReplyRate: Double
    var minimumSignupRate: Double
    var minimumWillingnessToPayCount: Int
    var minimumCompetitorDensity: Int
    var maximumCACEstimateUSD: Double
    var maximumTimeToFirstDollarDays: Int
    var minimumDemandSignalsToBuild: Int
    var rejectionReplyRateCeiling: Double
    var rejectionSignupRateCeiling: Double

    // Conservative defaults for first-pass validation: enough signal to avoid
    // building from one vanity metric, but still small enough for cheap tests.
    static let productionDefault = CompanyValidationPolicy(
        minimumInterviews: 5,
        minimumReplyRate: 0.10,
        minimumSignupRate: 0.08,
        minimumWillingnessToPayCount: 2,
        minimumCompetitorDensity: 3,
        maximumCACEstimateUSD: 50,
        maximumTimeToFirstDollarDays: 14,
        minimumDemandSignalsToBuild: 2,
        rejectionReplyRateCeiling: 0.02,
        rejectionSignupRateCeiling: 0.02
    )

    var successThreshold: CompanyValidationResult.Metrics {
        .init(
            interviewsCompleted: minimumInterviews,
            replyRate: minimumReplyRate,
            signupRate: minimumSignupRate,
            willingnessToPayCount: minimumWillingnessToPayCount,
            competitorDensity: minimumCompetitorDensity,
            cacEstimateUSD: maximumCACEstimateUSD,
            timeToFirstDollarDays: maximumTimeToFirstDollarDays
        )
    }
}

enum CompanyValidationEngine {
    static func plan(
        for idea: CompanyIdea,
        policy: CompanyValidationPolicy = .productionDefault
    ) -> CompanyValidationPlan {
        let experiments = [
            experiment(
                id: "\(idea.id)-interviews",
                kind: .customerInterviews,
                idea: idea,
                hypothesis: "The ICP can describe the pain in their own words.",
                action: "Draft 10 interview prompts and identify 10 target buyers.",
                threshold: "Complete 5 interviews with at least 3 urgent-pain confirmations.",
                artifacts: ["interview-targets.csv", "interview-notes.md"]
            ),
            experiment(
                id: "\(idea.id)-landing",
                kind: .landingPage,
                idea: idea,
                hypothesis: "The offer converts cold intent into signups.",
                action: "Draft landing page copy and a waitlist CTA.",
                threshold: "Reach 8% signup rate from at least 100 qualified visits.",
                artifacts: ["landing-copy.md", "analytics-screenshot.png"]
            ),
            experiment(
                id: "\(idea.id)-outreach",
                kind: .coldOutreach,
                idea: idea,
                hypothesis: "Target buyers will reply to the offer.",
                action: "Draft 25 outbound messages for approval before sending.",
                threshold: "Reach 10% reply rate and 2 willingness-to-pay signals.",
                artifacts: ["outreach-drafts.md", "approval-request.json", "reply-log.csv"]
            ),
            experiment(
                id: "\(idea.id)-market",
                kind: .marketplaceResearch,
                idea: idea,
                hypothesis: "Existing competitors prove demand without making the niche saturated.",
                action: "Collect competitor count, prices, reviews, and weak spots.",
                threshold: "Find 3-20 credible competitors and at least 3 review-backed gaps.",
                artifacts: ["competitor-research.md", "source-links.json"]
            ),
            experiment(
                id: "\(idea.id)-pricing",
                kind: .pricingTest,
                idea: idea,
                hypothesis: "The ICP accepts a price that can cover acquisition cost.",
                action: "Draft 3 price points and test willingness to pay in interviews or checkout intent.",
                threshold: "Get at least 2 explicit willingness-to-pay signals above estimated CAC.",
                artifacts: ["pricing-test.md"]
            )
        ]

        return CompanyValidationPlan(
            id: "validation-\(idea.id)",
            ideaID: idea.id,
            experiments: experiments,
            successThreshold: policy.successThreshold,
            policy: policy,
            sourceLinks: idea.evidenceLinks,
            rawArtifactPaths: experiments.flatMap(\.artifactRequirements)
        )
    }

    static func decide(
        idea: CompanyIdea,
        plan: CompanyValidationPlan,
        result: CompanyValidationResult
    ) -> CompanyValidationDecision {
        let threshold = plan.successThreshold
        let policy = plan.policy
        let metrics = result.metrics
        let demandSignalCount = [
            metrics.interviewsCompleted >= threshold.interviewsCompleted,
            metrics.signupRate >= threshold.signupRate,
            metrics.replyRate >= threshold.replyRate,
            metrics.competitorDensity >= threshold.competitorDensity
        ].filter { $0 }.count
        let hasEnoughEvidence = demandSignalCount >= policy.minimumDemandSignalsToBuild
        let hasWillingnessToPay = metrics.willingnessToPayCount >= threshold.willingnessToPayCount
        let acquisitionWorks = metrics.cacEstimateUSD <= threshold.cacEstimateUSD
        let speedWorks = metrics.timeToFirstDollarDays <= threshold.timeToFirstDollarDays
        let marketplaceWorks = metrics.competitorDensity >= threshold.competitorDensity
        let hasArtifacts = !result.sourceLinks.isEmpty && (!result.screenshots.isEmpty || !result.rawResearchArtifacts.isEmpty)

        var scorecard = idea.scorecard
        if hasEnoughEvidence { scorecard.customerPain = min(10, scorecard.customerPain + 1) }
        if hasWillingnessToPay { scorecard.willingnessToPay = min(10, scorecard.willingnessToPay + 1) }
        if acquisitionWorks { scorecard.distributionChannel = min(10, scorecard.distributionChannel + 1) }
        if !hasArtifacts { scorecard.credentialReadiness = max(1, scorecard.credentialReadiness - 2) }

        if hasEnoughEvidence && hasWillingnessToPay && acquisitionWorks && speedWorks && marketplaceWorks && hasArtifacts {
            return .init(decision: .readyToBuild, rationale: "Validation met multi-signal demand, WTP, CAC, speed, marketplace, and artifact thresholds.", adjustedScorecard: scorecard)
        }
        let hasCompletedWeakTest = metrics.interviewsCompleted >= threshold.interviewsCompleted ||
            metrics.competitorDensity > 0 ||
            hasArtifacts
        if !hasEnoughEvidence &&
            hasCompletedWeakTest &&
            metrics.willingnessToPayCount == 0 &&
            metrics.replyRate < policy.rejectionReplyRateCeiling &&
            metrics.signupRate < policy.rejectionSignupRateCeiling {
            return .init(decision: .rejected, rationale: "Validation failed to produce demand or willingness-to-pay evidence.", adjustedScorecard: scorecard)
        }
        return .init(decision: .needsMoreEvidence, rationale: "Some signals exist, but thresholds are incomplete.", adjustedScorecard: scorecard)
    }

    private static func experiment(
        id: String,
        kind: CompanyValidationExperiment.Kind,
        idea: CompanyIdea,
        hypothesis: String,
        action: String,
        threshold: String,
        artifacts: [String]
    ) -> CompanyValidationExperiment {
        let approvalRequired = kind == .coldOutreach ||
            CompanyApprovalPolicy.requiresApproval(proposedAction: action, estimatedCostUSD: nil)
        return CompanyValidationExperiment(
            id: id,
            kind: kind,
            hypothesis: "\(hypothesis) ICP: \(idea.icp)",
            action: "\(action) Offer: \(idea.offer) Channel: \(idea.channel).",
            measurableThreshold: threshold,
            approvalRequired: approvalRequired,
            draftOnly: approvalRequired,
            artifactRequirements: artifacts
        )
    }
}
