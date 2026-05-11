import Foundation
import Testing
@testable import OS1

struct CompanyPortfolioStrategyTests {
    @Test
    func dashboardFlagsConcentrationRiskAndAllocatesCapital() {
        let profiles = [
            profile(id: "winner", channel: "SEO", expectedValue: 900, evidence: 80, margin: 0.6),
            profile(id: "learner-a", channel: "SEO", expectedValue: 25, evidence: 20, margin: nil),
            profile(id: "learner-b", channel: "SEO", expectedValue: 10, evidence: 10, margin: nil)
        ]

        let dashboard = CompanyPortfolioStrategyEngine.dashboard(
            profiles: profiles,
            rules: CompanyPortfolioRules(
                maxCompaniesPerChannel: 2,
                maxCompaniesPerNiche: 10,
                maxCompaniesPerBrand: 10,
                maxCompaniesPerAccount: 10,
                maxCompaniesPerProvider: 10,
                defaultBudgetUSD: 20,
                maxBudgetUSD: 200,
                maxComputeSlotsPerCompany: 2
            )
        )

        #expect(dashboard.totalCompanies == 3)
        #expect(dashboard.allocations.first?.companyID == "winner")
        #expect(dashboard.allocations.first?.recommendedBudgetUSD ?? 0 > 20)
        #expect(dashboard.concentrationRisks.contains { $0.dimension == .channel && $0.value == "seo" })
    }

    @Test
    func schedulerUsesPortfolioAllocationBeforeOnlyOldestHeartbeat() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let oldWeak = session(id: "old-weak", nextHeartbeatAt: now.addingTimeInterval(-500))
        let newStrong = session(id: "new-strong", nextHeartbeatAt: now.addingTimeInterval(-5))
        let profiles = [
            "old-weak": profile(id: "old-weak", expectedValue: 0, evidence: 5, margin: nil),
            "new-strong": profile(id: "new-strong", expectedValue: 1_000, evidence: 90, margin: 0.7)
        ]

        let plan = CompanyScaleScheduler.plan(
            sessions: [oldWeak, newStrong],
            now: now,
            limits: CompanySchedulerLimits(
                maxGlobalConcurrentHeartbeats: 1,
                maxQueuedCompaniesBeforeBackpressure: 100,
                maxFailedCompaniesBeforeBackpressure: 100
            ),
            portfolioProfiles: profiles
        )

        #expect(plan.startNowIDs == ["new-strong"])
        #expect(plan.queuedIDs == ["old-weak"])
    }

    @Test
    func schedulerBlocksAccountConcentrationWhenPortfolioRulesAreBreached() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let first = session(id: "first", nextHeartbeatAt: now.addingTimeInterval(-5))
        let second = session(id: "second", nextHeartbeatAt: now.addingTimeInterval(-5))
        let profiles = [
            "first": profile(id: "first", account: "shared-ad-account", expectedValue: 500, evidence: 50),
            "second": profile(id: "second", account: "shared-ad-account", expectedValue: 400, evidence: 45)
        ]

        let plan = CompanyScaleScheduler.plan(
            sessions: [first, second],
            now: now,
            limits: CompanySchedulerLimits(
                maxGlobalConcurrentHeartbeats: 2,
                maxQueuedCompaniesBeforeBackpressure: 100,
                maxFailedCompaniesBeforeBackpressure: 100
            ),
            portfolioProfiles: profiles,
            portfolioRules: CompanyPortfolioRules(
                maxCompaniesPerChannel: 10,
                maxCompaniesPerNiche: 10,
                maxCompaniesPerBrand: 10,
                maxCompaniesPerAccount: 1,
                maxCompaniesPerProvider: 10,
                defaultBudgetUSD: 20,
                maxBudgetUSD: 200,
                maxComputeSlotsPerCompany: 2
            )
        )

        #expect(plan.startNowIDs.isEmpty)
        #expect(Set(plan.blockedIDs) == ["first", "second"])
    }

    @Test
    func killedAndPivotedCompanyLearningsFeedIdeaRanking() {
        let etsy = idea(id: "etsy", title: "Etsy planner", channel: "Etsy")
        let seo = idea(id: "seo", title: "SEO guide", channel: "SEO")

        let ranked = CompanyPortfolioStrategyEngine.rankIdeas(
            [etsy, seo],
            preservedLearnings: ["dead": "Lesson: avoid Etsy planner niche because refunds were high."]
        )

        #expect(ranked.first?.id == "seo")
    }

    @Test
    func dashboardPreservesKilledAndPivotedLearnings() {
        let dashboard = CompanyPortfolioStrategyEngine.dashboard(profiles: [
            profile(
                id: "killed",
                lifecycleStage: .killed,
                learningSummary: "Avoid duplicated buyer lists in this niche."
            ),
            profile(id: "active")
        ])

        #expect(dashboard.preservedLearnings["killed"] == "Avoid duplicated buyer lists in this niche.")
        #expect(dashboard.preservedLearnings["active"] == nil)
    }

    private func profile(
        id: String,
        channel: String = "SEO",
        niche: String = "templates",
        brand: String? = nil,
        account: String = "account-a",
        provider: String = "local-mac",
        status: CodexSession.Status = .idle,
        lifecycleStage: CodexSession.LifecycleStage = .validating,
        expectedValue: Double = 0,
        evidence: Int = 0,
        margin: Double? = nil,
        risk: CompanyIdea.RiskTier = .low,
        learningSummary: String? = nil
    ) -> CompanyPortfolioProfile {
        CompanyPortfolioProfile(
            companyID: id,
            title: id,
            channel: channel,
            niche: niche,
            brand: brand ?? id,
            account: account,
            provider: provider,
            status: status,
            lifecycleStage: lifecycleStage,
            expectedValueUSD: expectedValue,
            evidenceScore: evidence,
            contributionMargin: margin,
            risk: risk,
            learningSummary: learningSummary
        )
    }

    private func session(id: String, nextHeartbeatAt: Date?) -> CodexSession {
        var session = CodexSession(
            id: id,
            title: id,
            task: "run \(id)",
            worktreePath: "/tmp/\(id)",
            branch: "company/\(id)",
            status: .idle,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        session.nextHeartbeatAt = nextHeartbeatAt
        session.budget = .defaultState(now: Date(timeIntervalSince1970: 1_700_000_000))
        return session
    }

    private func idea(id: String, title: String, channel: String) -> CompanyIdea {
        CompanyIdea(
            id: id,
            title: title,
            sourceTemplateID: nil,
            status: .backlog,
            icp: "buyer",
            offer: "offer",
            channel: channel,
            riskTier: .low,
            expectedFirstExperiment: "test",
            requiredCredentials: [],
            evidenceLinks: ["source"],
            rationale: "same score",
            rejectionReason: nil,
            nextAction: "test",
            scorecard: CompanyIdea.Scorecard(
                customerPain: 7,
                willingnessToPay: 7,
                distributionChannel: 7,
                legalComplianceRisk: 7,
                buildComplexity: 7,
                timeToFirstDollar: 7,
                credentialReadiness: 7
            )
        )
    }
}
