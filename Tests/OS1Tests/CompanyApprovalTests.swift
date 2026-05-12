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

    @Test
    func approvalQueueBatchesRoutesExpiresAndAutoApprovesAtScale() throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = (0..<99).map { index in
            approvalRequest(
                id: "req-\(index)",
                companyID: index % 2 == 0 ? "validated-\(index)" : "experimental-\(index)",
                riskTier: index % 3 == 0 ? .high : (index % 3 == 1 ? .medium : .low),
                proposedAction: index % 3 == 0 ? "post_tweet launch update" : "Send customer email",
                requestedAt: now.addingTimeInterval(-300)
            )
        }
        let expired = approvalRequest(
            id: "expired",
            companyID: "validated-expired",
            riskTier: .high,
            proposedAction: "post_tweet stale launch update",
            requestedAt: now.addingTimeInterval(-90_000)
        )
        let policy = CompanyApprovalQueueEngine.appendOnlyPolicy(
            id: "policy-1",
            createdBy: "owner",
            companyPattern: "validated-*",
            actionType: "post_tweet",
            riskTier: .high,
            createdAt: now
        )

        let plan = CompanyApprovalQueueEngine.plan(
            requests: fresh + [expired],
            policies: [policy],
            now: now
        )
        let expiredItem = try #require(plan.items.first { $0.requestID == "expired" })
        let autoItem = try #require(plan.items.first { $0.requestID == "req-0" })

        #expect(plan.items.count == 100)
        #expect(plan.estimatedClearSeconds <= 300)
        #expect(plan.batches.keys.contains("outbound_message|medium"))
        #expect(plan.items.contains { $0.route == "immediate" })
        #expect(plan.items.contains { $0.route == "hourly_digest" })
        #expect(plan.items.contains { $0.route == "daily_digest" })
        #expect(expiredItem.status == .expired)
        #expect(expiredItem.releasesLeaseBy == now.addingTimeInterval(60))
        #expect(expiredItem.companyState == "paused_awaiting_review")
        #expect(autoItem.status == .approved)
        #expect(autoItem.event?.metadata["approval_mode"] == "auto")
    }

    @Test
    func autoApprovePoliciesAreAppendOnlyRevocableAndEligibilityRequiresCleanHistory() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = approvalRequest(
            id: "candidate",
            companyID: "validated-1",
            riskTier: .low,
            proposedAction: "Send customer email",
            requestedAt: now
        )
        let prior = (0..<3).map { index in
            var approved = approvalRequest(
                id: "prior-\(index)",
                companyID: "validated-1",
                riskTier: .low,
                proposedAction: "Send customer email",
                requestedAt: now.addingTimeInterval(Double(-index) * 86_400)
            )
            approved.status = .approved
            return approved
        }
        let policy = CompanyApprovalQueueEngine.appendOnlyPolicy(
            id: "policy-2",
            createdBy: "owner",
            companyPattern: "validated-*",
            actionType: "outbound_message",
            riskTier: .low,
            createdAt: now
        )
        let revoked = CompanyApprovalQueueEngine.revoke(
            policy,
            at: now.addingTimeInterval(1),
            reason: "Operator saw one bad send and stopped automation"
        )
        let activePlan = CompanyApprovalQueueEngine.plan(requests: [request], policies: [policy], now: now)
        let revokedPlan = CompanyApprovalQueueEngine.plan(requests: [request], policies: [revoked], now: now.addingTimeInterval(2))

        #expect(
            CompanyApprovalQueueEngine.autoPolicyEligible(
                request: request,
                priorApprovals: prior,
                revocationCount: 0,
                threshold: 3,
                since: now.addingTimeInterval(-14 * 86_400)
            )
        )
        #expect(policy.createdBy == "owner")
        #expect(policy.createdAt == now)
        #expect(!policy.isRevoked)
        #expect(revoked.isRevoked)
        #expect(activePlan.items.first?.approvalMode == "auto")
        #expect(revokedPlan.items.first?.approvalMode == "manual")
        #expect(revokedPlan.items.first?.route == "daily_digest")
        #expect(
            !CompanyApprovalQueueEngine.autoPolicyEligible(
                request: request,
                priorApprovals: prior,
                revocationCount: 1,
                threshold: 3,
                since: now.addingTimeInterval(-14 * 86_400)
            )
        )
    }

    private func approvalRequest(
        id: String? = nil,
        companyID: String = "company-1",
        riskTier: CompanyApprovalRequest.RiskTier = .high,
        proposedAction: String,
        estimatedCostUSD: Double? = nil,
        destinationAccount: String? = nil,
        requestedAt: Date = Date(timeIntervalSince1970: 1_800_000_000)
    ) -> CompanyApprovalRequest {
        CompanyApprovalRequest(
            id: id ?? "approval-\(CompanyApprovalPolicy.fingerprint(proposedAction).hashValue)",
            companyID: companyID,
            requestedAt: requestedAt,
            actor: "codex",
            riskTier: riskTier,
            proposedAction: proposedAction,
            expectedEffect: "Expected external effect",
            estimatedCostUSD: estimatedCostUSD,
            destinationAccount: destinationAccount,
            rollbackPlan: "Undo the action"
        )
    }
}
