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
        #expect(CompanyApprovalPolicy.requiresApproval(proposedAction: "Send 50 outreach emails", estimatedCostUSD: nil))
        #expect(CompanyApprovalPolicy.requiresApproval(proposedAction: "Buy domain for landing page", estimatedCostUSD: 14))
        #expect(CompanyApprovalPolicy.requiresApproval(proposedAction: "Create Stripe checkout link", estimatedCostUSD: nil))
        #expect(!CompanyApprovalPolicy.requiresApproval(proposedAction: "Draft landing page copy locally", estimatedCostUSD: nil))
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
}
