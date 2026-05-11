import Foundation
import Testing
@testable import OS1

struct CompanyValidationEngineTests {
    @Test
    func everyIdeaHasValidationPlanAndMeasurableThresholds() {
        let idea = CompanyIdeaEngine.candidates(limit: 1)[0]
        let plan = CompanyValidationEngine.plan(for: idea)

        #expect(plan.ideaID == idea.id)
        #expect(plan.experiments.map(\.kind).contains(.customerInterviews))
        #expect(plan.experiments.map(\.kind).contains(.landingPage))
        #expect(plan.experiments.map(\.kind).contains(.coldOutreach))
        #expect(plan.experiments.map(\.kind).contains(.marketplaceResearch))
        #expect(plan.experiments.map(\.kind).contains(.pricingTest))
        #expect(plan.hasMeasurableThreshold)
        #expect(plan.successThreshold.interviewsCompleted == 5)
        #expect(plan.successThreshold.willingnessToPayCount == 2)
    }

    @Test
    func outboundValidationIsDraftOnlyWhenApprovalPolicyRequiresIt() {
        let idea = CompanyIdeaEngine.candidates(limit: 1)[0]
        let plan = CompanyValidationEngine.plan(for: idea)
        let outreach = plan.experiments.first { $0.kind == .coldOutreach }

        #expect(outreach?.approvalRequired == true)
        #expect(outreach?.draftOnly == true)
        #expect(outreach?.artifactRequirements.contains("approval-request.json") == true)
    }

    @Test
    func validationDecisionCanRejectNeedMoreEvidenceOrMarkReadyToBuild() {
        let idea = CompanyIdeaEngine.candidates(limit: 1)[0]
        let plan = CompanyValidationEngine.plan(for: idea)
        let rejected = CompanyValidationEngine.decide(
            idea: idea,
            plan: plan,
            result: CompanyValidationResult(
                ideaID: idea.id,
                metrics: .init(interviewsCompleted: 0, replyRate: 0.0, signupRate: 0.0, willingnessToPayCount: 0, competitorDensity: 1, cacEstimateUSD: 100, timeToFirstDollarDays: 45),
                sourceLinks: [],
                screenshots: [],
                rawResearchArtifacts: [],
                rationale: "No demand"
            )
        )
        let more = CompanyValidationEngine.decide(
            idea: idea,
            plan: plan,
            result: CompanyValidationResult(
                ideaID: idea.id,
                metrics: .init(interviewsCompleted: 5, replyRate: 0.04, signupRate: 0.03, willingnessToPayCount: 1, competitorDensity: 3, cacEstimateUSD: 60, timeToFirstDollarDays: 20),
                sourceLinks: ["https://example.com/research"],
                screenshots: [],
                rawResearchArtifacts: ["notes.md"],
                rationale: "Mixed signal"
            )
        )
        let ready = CompanyValidationEngine.decide(
            idea: idea,
            plan: plan,
            result: CompanyValidationResult(
                ideaID: idea.id,
                metrics: .init(interviewsCompleted: 5, replyRate: 0.12, signupRate: 0.10, willingnessToPayCount: 3, competitorDensity: 5, cacEstimateUSD: 25, timeToFirstDollarDays: 7),
                sourceLinks: ["https://example.com/research"],
                screenshots: ["landing.png"],
                rawResearchArtifacts: ["reply-log.csv"],
                rationale: "Strong signal"
            )
        )

        #expect(rejected.decision == .rejected)
        #expect(more.decision == .needsMoreEvidence)
        #expect(ready.decision == .readyToBuild)
        #expect(ready.adjustedScorecard.total > idea.scorecard.total)
    }

    @Test
    func validationResultsFeedLaunchDecisionThroughScorecard() {
        let idea = CompanyIdeaEngine.candidates(limit: 1)[0]
        let plan = CompanyValidationEngine.plan(for: idea)
        let ready = CompanyValidationEngine.decide(
            idea: idea,
            plan: plan,
            result: CompanyValidationResult(
                ideaID: idea.id,
                metrics: .init(interviewsCompleted: 8, replyRate: 0.20, signupRate: 0.12, willingnessToPayCount: 4, competitorDensity: 8, cacEstimateUSD: 10, timeToFirstDollarDays: 3),
                sourceLinks: ["https://example.com/research"],
                screenshots: ["proof.png"],
                rawResearchArtifacts: ["research.json"],
                rationale: "Evidence met threshold"
            )
        )

        #expect(ready.decision == .readyToBuild)
        #expect(ready.adjustedScorecard.customerPain >= idea.scorecard.customerPain)
        #expect(ready.adjustedScorecard.willingnessToPay >= idea.scorecard.willingnessToPay)
        #expect(ready.adjustedScorecard.distributionChannel >= idea.scorecard.distributionChannel)
    }
}
