import Foundation
import Testing
@testable import OS1

struct CompanyRoadmapTests {
    @Test
    func roadmapTracksAllProductionIssuesNeededForScale() {
        let numbers = Set(CompanyRoadmapEngine.productionIssues.map(\.number))

        #expect(numbers.isSuperset(of: Set([13, 15, 16, 17, 18])))
        #expect(numbers.isSuperset(of: Set(20...43)))
        #expect(CompanyRoadmapEngine.productionIssues.contains { $0.phase == .companyFactory })
        #expect(CompanyRoadmapEngine.productionIssues.contains { $0.phase == .fleetScale })
        #expect(CompanyRoadmapEngine.productionIssues.allSatisfy { $0.requiredForHundredCompanies })
    }

    @Test
    func firstDollarRequiresTraceSpendCredentialsApprovalAccountingAndKillControls() {
        let readiness = CompanyRoadmapEngine.readiness(
            evidence: .empty,
            issueStatuses: activeStatuses()
        )

        #expect(!readiness.firstDollar.isReady)
        #expect(readiness.firstDollar.missingControls.contains("full event trace"))
        #expect(readiness.firstDollar.missingControls.contains("bounded spend"))
        #expect(readiness.firstDollar.missingControls.contains("scoped credentials"))
        #expect(readiness.firstDollar.missingControls.contains("high-risk approval"))
        #expect(readiness.firstDollar.missingControls.contains("profit/loss attribution"))
        #expect(readiness.firstDollar.missingControls.contains("kill/pause controls"))
        #expect(readiness.firstDollar.missingControls.contains("reproducible run history"))
    }

    @Test
    func hundredCompanyScaleRequiresSchedulerBudgetEventApprovalLifecycleAndCompliance() {
        let readiness = CompanyRoadmapEngine.readiness(
            evidence: .empty,
            issueStatuses: activeStatuses()
        )

        #expect(!readiness.hundredCompanyScale.isReady)
        #expect(readiness.hundredCompanyScale.missingControls.contains("scheduler"))
        #expect(readiness.hundredCompanyScale.missingControls.contains("budget guardian"))
        #expect(readiness.hundredCompanyScale.missingControls.contains("event log"))
        #expect(readiness.hundredCompanyScale.missingControls.contains("approval console"))
        #expect(readiness.hundredCompanyScale.missingControls.contains("lifecycle gates"))
        #expect(readiness.hundredCompanyScale.missingControls.contains("compliance layer"))
    }

    @Test
    func scaleIsBlockedUntilRequiredIssuesAndMilestoneEvidenceAreActive() {
        var statuses = activeStatuses()
        statuses[42] = .inReview
        let blockedByIssue = CompanyRoadmapEngine.readiness(
            evidence: .ready,
            issueStatuses: statuses
        )

        #expect(!blockedByIssue.canScaleToHundreds)
        #expect(blockedByIssue.hundredCompanyScale.missingControls.contains("#42 Role-based permissions"))

        let ready = CompanyRoadmapEngine.readiness(
            evidence: .ready,
            issueStatuses: activeStatuses()
        )

        #expect(ready.firstDollar.isReady)
        #expect(ready.hundredCompanyScale.isReady)
        #expect(ready.canScaleToHundreds)
    }

    private func activeStatuses() -> [Int: CompanyRoadmapIssue.Status] {
        Dictionary(
            uniqueKeysWithValues: CompanyRoadmapEngine.productionIssues.map { ($0.number, .active) }
        )
    }
}

private extension CompanyProductionMilestoneEvidence {
    static let empty = CompanyProductionMilestoneEvidence(
        fullEventTrace: false,
        boundedSpend: false,
        scopedCredentials: false,
        humanApprovalForHighRiskActions: false,
        profitLossAttribution: false,
        killPauseControls: false,
        reproducibleRunHistory: false,
        schedulerActive: false,
        budgetGuardianActive: false,
        eventLogActive: false,
        approvalConsoleActive: false,
        lifecycleGatesActive: false,
        complianceLayerActive: false
    )

    static let ready = CompanyProductionMilestoneEvidence(
        fullEventTrace: true,
        boundedSpend: true,
        scopedCredentials: true,
        humanApprovalForHighRiskActions: true,
        profitLossAttribution: true,
        killPauseControls: true,
        reproducibleRunHistory: true,
        schedulerActive: true,
        budgetGuardianActive: true,
        eventLogActive: true,
        approvalConsoleActive: true,
        lifecycleGatesActive: true,
        complianceLayerActive: true
    )
}
