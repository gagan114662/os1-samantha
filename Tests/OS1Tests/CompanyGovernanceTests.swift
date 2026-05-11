import Foundation
import Testing
@testable import OS1

struct CompanyGovernanceTests {
    @Test
    func majorLifecycleDecisionsCreateDurableDecisionRecords() throws {
        let decision = CompanyLifecycleDecision(
            action: .promote,
            from: .building,
            to: .launched,
            rationale: "Launch QA and distribution gates passed.",
            requiresOverride: false,
            evidence: snapshot(stage: .building)
        )

        let record = try #require(CompanyGovernanceEngine.record(
            lifecycleDecision: decision,
            decidedBy: "samantha",
            approver: "owner",
            evidenceLinks: ["COMPANY_ASSETS.json", "QA_REPORT.json"],
            alternativesConsidered: ["Hold launch for another test"],
            expectedFollowUp: "Review first 10 customers within 48 hours"
        ))

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(record)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CompanyDecisionRecord.self, from: data)

        #expect(decoded.kind == .launch)
        #expect(decoded.lifecycleFrom == .building)
        #expect(decoded.lifecycleTo == .launched)
        #expect(decoded.evidenceLinks.contains("QA_REPORT.json"))
        #expect(decoded.auditEvent().kind == .governanceDecisionRecorded)
    }

    @Test
    func overridesExpireOrRequireRenewal() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let override = CompanyGovernanceOverride(
            reason: "Temporary compliance exception",
            approvedBy: "owner",
            createdAt: now,
            expiresAt: now.addingTimeInterval(86_400),
            reviewDueAt: now.addingTimeInterval(3_600)
        )

        #expect(override.status(at: now) == .active)
        #expect(override.status(at: now.addingTimeInterval(7_200)) == .renewalRequired)
        #expect(override.status(at: now.addingTimeInterval(90_000)) == .expired)
    }

    @Test
    func explanationsShowWhyCompanyWasLaunchedScaledPausedKilledOrGrantedBudget() {
        let records = [
            record(kind: .launch, rationale: "QA passed"),
            record(kind: .scale, rationale: "Profit threshold passed"),
            record(kind: .pause, rationale: "Hard budget limit reached"),
            record(kind: .kill, rationale: "Critical compliance risk"),
            record(kind: .budgetIncrease, rationale: "Approved capped ad test")
        ]

        for kind in [CompanyDecisionKind.launch, .scale, .pause, .kill, .budgetIncrease] {
            let explanation = CompanyGovernanceEngine.explanation(companyID: "co", kind: kind, records: records)
            #expect(explanation?.contains(kind.rawValue) == true)
        }
    }

    @Test
    func productionImpactingChangesAreLinkedToIssuesPRsAndReleases() {
        let incomplete = CompanyProductionChangeChecklist(
            issueURL: "https://github.com/gagan114662/os1-samantha/issues/43",
            pullRequestURL: nil,
            releaseURL: "",
            verificationArtifacts: [],
            riskSummary: "production workflow change",
            rollbackPlan: "revert PR"
        )

        #expect(CompanyGovernanceEngine.validateProductionChange(incomplete) == [
            "pullRequestURL",
            "releaseURL",
            "verificationArtifacts"
        ])

        let complete = CompanyProductionChangeChecklist(
            issueURL: "https://github.com/gagan114662/os1-samantha/issues/43",
            pullRequestURL: "https://github.com/gagan114662/os1-samantha/pull/78",
            releaseURL: "https://github.com/gagan114662/os1-samantha/releases/tag/v1",
            verificationArtifacts: ["swift-test.log"],
            riskSummary: "production workflow change",
            rollbackPlan: "revert PR"
        )

        #expect(CompanyGovernanceEngine.validateProductionChange(complete).isEmpty)
    }

    @Test
    func credentialProviderAndComplianceDecisionsCanBeRecorded() {
        let override = CompanyGovernanceOverride(
            reason: "temporary support tool access",
            approvedBy: "owner",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            expiresAt: Date(timeIntervalSince1970: 1_700_086_400),
            reviewDueAt: Date(timeIntervalSince1970: 1_700_043_200)
        )
        let kinds: [CompanyDecisionKind] = [.credentialGrant, .providerChange, .complianceOverride]

        for kind in kinds {
            let record = CompanyGovernanceEngine.decisionRecord(
                companyID: "co",
                kind: kind,
                decidedBy: "samantha",
                approver: "owner",
                rationale: "operator approved \(kind.rawValue)",
                evidenceLinks: ["APPROVAL_DECISION.json"],
                evidenceSummary: "approval exists",
                alternativesConsidered: ["keep existing access"],
                expectedFollowUp: "review access",
                override: kind == .complianceOverride ? override : nil
            )

            #expect(record.kind == kind)
            #expect(record.auditEvent().metadata["approver"] == "owner")
        }
    }

    private func record(kind: CompanyDecisionKind, rationale: String) -> CompanyDecisionRecord {
        CompanyDecisionRecord(
            companyID: "co",
            kind: kind,
            decidedBy: "samantha",
            approver: "owner",
            rationale: rationale,
            evidenceLinks: ["evidence.json"],
            evidenceSummary: "evidence summary",
            alternativesConsidered: ["do nothing"],
            expectedFollowUp: "review"
        )
    }

    private func snapshot(stage: CodexSession.LifecycleStage) -> CompanyEvidenceSnapshot {
        CompanyEvidenceSnapshot(
            companyID: "co",
            stage: stage,
            validationDecision: .readyToBuild,
            ledger: .empty,
            budgetReport: nil,
            distribution: nil,
            failureCount: 0,
            complianceRisk: .low,
            overrideReason: nil,
            artifactPaths: []
        )
    }
}
