import Foundation
import Testing
@testable import OS1

struct CompanyProcurementTests {
    @Test
    func paidProvisioningWithoutPolicyCoverageIsBlocked() {
        let request = procurementRequest(category: .cloudResource, amount: 20)
        let policy = CompanyProcurementPolicy(
            coveredCategories: [.domain],
            autoApprovalLimitUSD: 0,
            highRiskApprovalLimitUSD: 0,
            renewalWarningDays: 14,
            unusedSubscriptionWarningDays: 30
        )

        let decision = CompanyProcurementEngine.evaluate(request, policy: policy)

        #expect(decision.status == .blocked)
        #expect(!decision.canProvision)
        #expect(decision.reasons.contains("category has no approval policy coverage"))
    }

    @Test
    func amountRenewalAndRiskRequireApprovalBeforeProvisioning() {
        let request = procurementRequest(
            category: .apiPlan,
            amount: 49,
            renewalTerm: .monthly,
            riskTier: .high
        )
        let decision = CompanyProcurementEngine.evaluate(request)

        #expect(decision.status == .approvalRequired)
        #expect(decision.requiresApprover)
        #expect(decision.reasons.contains("amount requires approval"))
        #expect(decision.reasons.contains("recurring renewal requires approval"))
        #expect(decision.reasons.contains("high-risk vendor/resource requires approval"))
    }

    @Test
    func approvedProcurementIsTraceableToCompanyApproverAndROI() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = procurementRequest(amount: 10, expectedROI: "Expected 3 qualified leads per month.")
        let approval = CompanyProcurementEngine.approve(
            request,
            approverID: "ceo",
            now: now,
            note: "approved"
        )
        let decision = CompanyProcurementEngine.evaluate(request, approval: approval)
        let audit = CompanyProcurementEngine.auditLog(
            request: request,
            decision: decision,
            actor: approval.approverID,
            now: now
        )

        #expect(decision.canProvision)
        #expect(audit.companyID == request.companyID)
        #expect(audit.approverID == "ceo")
        #expect(audit.expectedROI == "Expected 3 qualified leads per month.")
        #expect(audit.metadata["vendor"] == request.vendor)
    }

    @Test
    func recurringSubscriptionsCreateCompanyAndPortfolioLedgerCosts() {
        let renewal = Date(timeIntervalSince1970: 1_800_000_000)
        let request = procurementRequest(
            category: .saasTool,
            amount: 29,
            renewalTerm: .monthly,
            nextRenewalAt: renewal
        )
        let entries = CompanyProcurementEngine.recurringLedgerEntries(
            subscriptions: [
                CompanyProcurementSubscriptionState(request: request, approved: true, lastUsedAt: renewal)
            ],
            now: renewal.addingTimeInterval(60)
        )
        let summary = CompanyLedgerSummary(entries: entries)

        #expect(entries.count == 1)
        #expect(entries[0].companyID == request.companyID)
        #expect(entries[0].category == .tools)
        #expect(summary.costUSD == 29)
    }

    @Test
    func renewalAndUnusedToolWarningsAreEmitted() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let request = procurementRequest(
            renewalTerm: .monthly,
            nextRenewalAt: now.addingTimeInterval(3 * 86_400)
        )
        let warnings = CompanyProcurementEngine.warnings(
            subscriptions: [
                CompanyProcurementSubscriptionState(
                    request: request,
                    approved: true,
                    lastUsedAt: now.addingTimeInterval(-45 * 86_400)
                )
            ],
            now: now
        )

        #expect(warnings.map(\.action).contains(.renewalWarning))
        #expect(warnings.map(\.action).contains(.unusedWarning))
    }

    private func procurementRequest(
        category: CompanyProcurementRequest.Category = .domain,
        amount: Double = 12,
        renewalTerm: CompanyProcurementRequest.RenewalTerm = .annual,
        nextRenewalAt: Date? = Date(timeIntervalSince1970: 1_900_000_000),
        riskTier: CompanyIdea.RiskTier = .low,
        expectedROI: String = "Expected to support revenue growth."
    ) -> CompanyProcurementRequest {
        CompanyProcurementRequest(
            id: "request-\(category.rawValue)",
            companyID: "company",
            requestedAt: Date(timeIntervalSince1970: 1_700_000_000),
            category: category,
            vendor: "Vendor",
            vendorOwner: "operator",
            amountUSD: amount,
            renewalTerm: renewalTerm,
            nextRenewalAt: nextRenewalAt,
            cancellationDeadline: nextRenewalAt?.addingTimeInterval(-7 * 86_400),
            riskTier: riskTier,
            expectedROI: expectedROI,
            sourceEventID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")
        )
    }
}
