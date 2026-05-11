import Foundation
import Testing
@testable import OS1

struct CompanyBusinessModelPlaybookTests {
    @Test
    func eachTemplateHasCompleteValidationToRevenuePlaybook() {
        #expect(CompanyBusinessModelPlaybookCatalog.all.count == 5)
        for playbook in CompanyBusinessModelPlaybookCatalog.all {
            #expect(playbook.isComplete)
            #expect(playbook.validationSteps.count >= 3)
            #expect(playbook.buildSteps.count >= 3)
            #expect(playbook.launchChecklist.count >= 4)
            #expect(playbook.metrics.count >= 4)
            #expect(playbook.killCriteria.count >= 3)
        }
    }

    @Test
    func samanthaCanChooseTemplateForIdeaAndExplainWhy() {
        let idea = idea(
            title: "Etsy landing page setup service",
            channel: "Etsy marketplace",
            offer: "Productized marketplace setup service"
        )

        let match = CompanyBusinessModelPlaybookCatalog.choose(for: idea)

        #expect(match.playbookID == "marketplace-productized-service")
        #expect(match.score > 80)
        #expect(match.rationale.contains("matches"))
    }

    @Test
    func lifecycleGatesAreTemplateAware() {
        let gates = CompanyBusinessModelPlaybookCatalog.lifecycleGates(for: "micro-saas")
        let validating = gates.first { $0.stage == .validating }
        let evidence: Set<String> = ["buyer-pain", "willingness-to-pay", "channel-proof"]

        #expect(gates.allSatisfy { $0.playbookID == "micro-saas" })
        #expect(validating?.isSatisfied(by: evidence) == true)
        #expect(validating?.isSatisfied(by: ["buyer-pain"]) == false)
    }

    @Test
    func templatePerformanceCanBeComparedAcrossCompanies() {
        let ranked = CompanyBusinessModelPlaybookCatalog.comparePerformance([
            performance(playbookID: "newsletter", revenue: 10, conversion: 0.2),
            performance(playbookID: "micro-saas", revenue: 200, conversion: 0.05)
        ])

        #expect(ranked.map(\.playbookID) == ["micro-saas", "newsletter"])
    }

    @Test
    func broadReplicationRequiresAtLeastOneVerifiedRevenueTemplate() {
        #expect(!CompanyBusinessModelPlaybookCatalog.canReplicateBroadly([
            performance(playbookID: "micro-saas", revenue: 0, conversion: 0.2)
        ]))
        #expect(CompanyBusinessModelPlaybookCatalog.canReplicateBroadly([
            performance(playbookID: "micro-saas", revenue: 1, conversion: 0.2)
        ]))
    }

    private func idea(title: String, channel: String, offer: String) -> CompanyIdea {
        CompanyIdea(
            id: "idea",
            title: title,
            sourceTemplateID: nil,
            status: .backlog,
            icp: "operator",
            offer: offer,
            channel: channel,
            riskTier: .low,
            expectedFirstExperiment: "test demand",
            requiredCredentials: [],
            evidenceLinks: ["source"],
            rationale: "test",
            rejectionReason: nil,
            nextAction: "validate",
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

    private func performance(
        playbookID: String,
        revenue: Double,
        conversion: Double
    ) -> CompanyTemplatePerformance {
        CompanyTemplatePerformance(
            playbookID: playbookID,
            companyCount: 1,
            verifiedRevenueUSD: revenue,
            conversionRate: conversion,
            killedCount: 0
        )
    }
}
