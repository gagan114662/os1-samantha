import Foundation
import Testing
@testable import OS1

struct CompanyApprovalTests {
    @Test
    func approvalRequestRoundTripsThroughJSON() throws {
        let original = CompanyApprovalRequest(
            id: "approval-1",
            companyID: "company-1",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            actor: "codex",
            riskTier: .high,
            proposedAction: "Publish launch post",
            expectedEffect: "Public launch message goes live",
            estimatedCostUSD: 12.5,
            destinationAccount: "@company",
            rollbackPlan: "Delete post and append correction"
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(original)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CompanyApprovalRequest.self, from: data)

        #expect(decoded == original)
    }

    @Test
    func approvalPolicyFlagsSpendAndOutboundActions() {
        #expect(
            CompanyApprovalPolicy.requiresApproval(
                proposedAction: "Send 50 outreach emails",
                estimatedCostUSD: nil
            )
        )
        #expect(
            CompanyApprovalPolicy.requiresApproval(
                proposedAction: "Buy domain for landing page",
                estimatedCostUSD: 14
            )
        )
        #expect(
            CompanyApprovalPolicy.requiresApproval(
                proposedAction: "Create Stripe checkout link",
                estimatedCostUSD: nil
            )
        )
        #expect(
            !CompanyApprovalPolicy.requiresApproval(
                proposedAction: "Draft landing page copy locally",
                estimatedCostUSD: nil
            )
        )
    }

    @Test
    func approvalRequestRedactsSecrets() {
        let request = CompanyApprovalRequest(
            companyID: "company-1",
            riskTier: .critical,
            proposedAction: "Use sk-abcdefghijklmnopqrstuvwxyz123456",
            expectedEffect: "credential test",
            rollbackPlan: "rotate sk-abcdefghijklmnopqrstuvwxyz123456"
        )

        #expect(request.proposedAction == "Use [redacted]")
        #expect(request.rollbackPlan == "rotate [redacted]")
    }

    @Test
    func approvalGateBlocksHighRiskActionsWithoutMatchingGrant() {
        let proposedAction = "Send 50 outreach emails"

        let blocked = CompanyApprovalGate.evaluate(
            companyID: "company-1",
            proposedAction: proposedAction,
            estimatedCostUSD: nil,
            grants: []
        )
        let lowRisk = CompanyApprovalGate.evaluate(
            companyID: "company-1",
            proposedAction: "Draft landing page copy locally",
            estimatedCostUSD: nil,
            grants: []
        )

        #expect(blocked.status == .approvalRequired)
        #expect(blocked.followUpPlan?.contains("APPROVAL_REQUEST.json") == true)
        #expect(lowRisk.status == .allowed)
    }

    @Test
    func approvalGrantMustMatchCompanyActionCostDestinationAndExpiry() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = approvalRequest(
            proposedAction: "Buy domain for landing page",
            estimatedCostUSD: 14,
            destinationAccount: "namecheap"
        )
        let grant = CompanyApprovalGrant(
            request: request,
            grantedAt: now,
            expiresAt: now.addingTimeInterval(3600),
            remainingUses: 1
        )

        let allowed = CompanyApprovalGate.evaluate(
            companyID: "company-1",
            proposedAction: "Buy domain for landing page",
            estimatedCostUSD: 14,
            destinationAccount: "namecheap",
            now: now,
            grants: [grant]
        )
        let tooExpensive = CompanyApprovalGate.evaluate(
            companyID: "company-1",
            proposedAction: "Buy domain for landing page",
            estimatedCostUSD: 20,
            destinationAccount: "namecheap",
            now: now,
            grants: [grant]
        )
        let expired = CompanyApprovalGate.evaluate(
            companyID: "company-1",
            proposedAction: "Buy domain for landing page",
            estimatedCostUSD: 14,
            destinationAccount: "namecheap",
            now: now.addingTimeInterval(7200),
            grants: [grant]
        )

        #expect(allowed.status == .allowed)
        #expect(allowed.matchingGrantID == grant.id)
        #expect(tooExpensive.status == .approvalRequired)
        #expect(expired.status == .approvalRequired)
    }

    @Test
    func deniedAndChangesRequestedActionsProduceFollowUpPlans() {
        var denied = approvalRequest(proposedAction: "Publish public claim")
        denied.status = .denied
        denied.decisionNote = "Claim is not supported by evidence."

        var changes = approvalRequest(proposedAction: "Create Stripe checkout link")
        changes.status = .changesRequested
        changes.decisionNote = "Use test mode first."

        var always = approvalRequest(proposedAction: "Wire contractor payment")
        always.status = .alwaysRequireApproval

        #expect(
            CompanyApprovalGate.evaluate(
                companyID: "company-1",
                proposedAction: denied.proposedAction,
                estimatedCostUSD: nil,
                requests: [denied]
            ).status == .denied
        )
        #expect(
            CompanyApprovalGate.evaluate(
                companyID: "company-1",
                proposedAction: changes.proposedAction,
                estimatedCostUSD: nil,
                requests: [changes]
            ).followUpPlan?.contains("Revise") == true
        )
        #expect(
            CompanyApprovalGate.evaluate(
                companyID: "company-1",
                proposedAction: always.proposedAction,
                estimatedCostUSD: 100,
                requests: [always]
            ).status == .alwaysRequiresApproval
        )
    }

    private func approvalRequest(
        proposedAction: String,
        estimatedCostUSD: Double? = nil,
        destinationAccount: String? = nil
    ) -> CompanyApprovalRequest {
        CompanyApprovalRequest(
            id: "approval-\(CompanyApprovalPolicy.fingerprint(proposedAction).hashValue)",
            companyID: "company-1",
            requestedAt: Date(timeIntervalSince1970: 1_800_000_000),
            actor: "codex",
            riskTier: .high,
            proposedAction: proposedAction,
            expectedEffect: "Expected external effect",
            estimatedCostUSD: estimatedCostUSD,
            destinationAccount: destinationAccount,
            rollbackPlan: "Undo the action"
        )
    }
}
