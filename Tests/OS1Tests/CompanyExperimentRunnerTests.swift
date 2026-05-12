import Foundation
import Testing
@testable import OS1

struct CompanyExperimentRunnerTests {
    @Test
    func experimentsDefaultOffUntilAllowlistedAndSevenDaysOld() {
        let access = CompanyAccessControl(
            companyID: "co",
            mediaProviderAllowlist: [],
            seoProviderAllowlist: [],
            embeddingProviderAllowlist: [],
            experimentationEnabled: true
        )

        let early = CompanyExperimentRunner.createExperiment(
            companyID: "co",
            baseDraft: "base",
            hypothesis: "hook test",
            transforms: variants(),
            accessControl: access,
            companyRunHistoryDays: 2
        )
        let ready = CompanyExperimentRunner.createExperiment(
            companyID: "co",
            baseDraft: "base",
            hypothesis: "hook test",
            transforms: variants(),
            accessControl: access,
            companyRunHistoryDays: 7
        )

        #expect(early.status == .stopped)
        #expect(ready.status == .running)
    }

    @Test
    func allocationPoliciesProduceExpectedSplits() {
        let experiment = runningExperiment(policy: .fixedSplit)
        let fixed = CompanyExperimentRunner.allocation(experiment: experiment)
        #expect(fixed["a"] == 0.5)
        #expect(fixed["b"] == 0.5)

        var bandit = experiment
        bandit.allocationPolicy = .thompsonSampling
        let allocation = CompanyExperimentRunner.allocation(
            experiment: bandit,
            results: [
                "a": result(variant: "a", impressions: 100, clicks: 5),
                "b": result(variant: "b", impressions: 100, clicks: 20)
            ]
        )
        #expect((allocation["b"] ?? 0) > (allocation["a"] ?? 0))

        var sequential = experiment
        sequential.allocationPolicy = .sequential
        let seq = CompanyExperimentRunner.allocation(experiment: sequential, results: [:])
        #expect(seq["a"] == 1)
        #expect(seq["b"] == 0)
    }

    @Test
    func runnerDecidesWinnerPromotesHookAndPausesLosers() {
        let experiment = runningExperiment(policy: .fixedSplit)
        let campaigns = CompanyExperimentRunner.campaigns(for: experiment, channel: .xPost, audience: "founders")
        let outcome = CompanyExperimentRunner.decide(
            experiment: experiment,
            campaigns: campaigns,
            results: [
                "a": result(variant: "a", impressions: 1_000, clicks: 40),
                "b": result(variant: "b", impressions: 1_000, clicks: 140)
            ],
            confidenceThreshold: 0.5,
            hookLibrary: CompanyHookLibrary(companyID: "co", topHooks: []),
            voiceProfile: CompanyVoiceProfile(companyID: "co", examples: [])
        )

        #expect(outcome.decision.experiment.status == .decided)
        #expect(outcome.decision.experiment.winnerVariantID == "b")
        #expect(outcome.hookLibrary.topHooks.first == "winning hook")
        #expect(outcome.voiceProfile.examples.first == "winning hook")
        #expect(outcome.campaigns.first { $0.id.contains("b") }?.approvalState == .approved)
        #expect(outcome.campaigns.first { $0.id.contains("a") }?.approvalState == .blocked)
        #expect(outcome.decision.event?.kind == .experimentDecided)
    }

    @Test
    func noPromotionHappensBelowConfidenceThreshold() {
        let experiment = runningExperiment(policy: .fixedSplit)
        let outcome = CompanyExperimentRunner.decide(
            experiment: experiment,
            campaigns: CompanyExperimentRunner.campaigns(for: experiment, channel: .linkedinPost, audience: "operators"),
            results: [
                "a": result(variant: "a", impressions: 1_000, clicks: 90),
                "b": result(variant: "b", impressions: 1_000, clicks: 100)
            ],
            confidenceThreshold: 0.5,
            hookLibrary: CompanyHookLibrary(companyID: "co", topHooks: []),
            voiceProfile: CompanyVoiceProfile(companyID: "co", examples: [])
        )

        #expect(outcome.decision.experiment.status == .inconclusive)
        #expect(outcome.hookLibrary.topHooks.isEmpty)
        #expect(outcome.voiceProfile.examples.isEmpty)
    }

    private func runningExperiment(policy: CompanyExperiment.AllocationPolicy) -> CompanyExperiment {
        CompanyExperiment(
            id: "co-exp",
            companyID: "co",
            hypothesis: "hook test",
            metric: .clicksPerImpression,
            variants: [
                .init(id: "a", label: "A", creative: "control hook", allocationWeight: 0.5),
                .init(id: "b", label: "B", creative: "winning hook", allocationWeight: 0.5)
            ],
            allocationPolicy: policy,
            status: .running,
            winnerVariantID: nil,
            confidenceLevel: 0,
            decidedAt: nil
        )
    }

    private func variants() -> [(id: String, label: String, creative: String)] {
        [("a", "A", "control hook"), ("b", "B", "winning hook")]
    }

    private func result(variant: String, impressions: Int, clicks: Int) -> CompanyGrowthResult {
        CompanyGrowthResult(
            companyID: "co",
            campaignID: variant,
            impressions: impressions,
            clicks: clicks,
            replies: 0,
            conversions: 0,
            revenueUSD: 0,
            costUSD: 0,
            sourceReference: "fixture"
        )
    }
}
