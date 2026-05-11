import Foundation
import Testing
@testable import OS1

struct CompanyPaymentsRiskTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func liveBillingIsBlockedUntilSandboxKYCAndPayoutsAreClean() {
        let account = CompanyPaymentAccount(
            companyID: "company-1",
            provider: .stripe,
            mode: .sandbox,
            chargesEnabled: true,
            payoutsEnabled: false,
            kycStatus: .actionRequired,
            requirementsDue: ["business_profile.url"],
            payoutHoldReasons: ["risk_review"],
            liveBillingRequested: true,
            sandboxTests: [.init(id: "checkout", kind: .checkout, passed: true, evidence: "cs_test_1")]
        )

        let report = CompanyPaymentsRiskEngine.evaluate(
            account: account,
            transactions: [],
            disputes: [],
            now: now
        )

        #expect(report.companyID == "company-1")
        #expect(report.accountHealth == .kycActionRequired)
        #expect(!report.canEnableLiveBilling)
        #expect(report.blockers.contains("payoutRestricted"))
        #expect(report.blockers.contains("kyc:actionRequired"))
        #expect(report.blockers.contains("requirementsDue:business_profile.url"))
        #expect(report.blockers.contains("missingSandboxTests:dispute,refund,webhook"))
        #expect(report.supportTasks.contains { $0.kind == .payoutHoldReview && $0.priority == .high })
        #expect(report.supportTasks.contains { $0.kind == .kycFollowUp && $0.priority == .high })
        #expect(report.approvalRequests.contains { $0.id == "payments-live-company-1" })
    }

    @Test
    func allSandboxTestsAndHealthyAccountAllowLiveBilling() {
        let report = CompanyPaymentsRiskEngine.evaluate(
            account: healthyAccount(liveBillingRequested: true),
            transactions: [],
            disputes: [],
            now: now
        )

        #expect(report.accountHealth == .healthy)
        #expect(report.canEnableLiveBilling)
        #expect(report.blockers.isEmpty)
        #expect(!report.shouldPauseCompany)
    }

    @Test
    func disputesAndChargebacksCreateUrgentEscalationsAndApprovalRequests() {
        let dispute = CompanyPaymentDispute(
            id: "dp_1",
            companyID: "company-1",
            transactionID: "txn_1",
            amountUSD: 99,
            reason: "fraudulent",
            status: .needsResponse,
            responseDueAt: now.addingTimeInterval(86_400),
            providerReference: "du_123"
        )
        let chargeback = transaction(id: "cb_1", kind: .chargeback, amountUSD: 99)

        let report = CompanyPaymentsRiskEngine.evaluate(
            account: healthyAccount(),
            transactions: [chargeback],
            disputes: [dispute],
            now: now
        )

        #expect(report.supportTasks.contains { $0.kind == .disputeResponse && $0.priority == .urgent })
        #expect(report.supportTasks.contains { $0.kind == .chargebackReview && $0.priority == .urgent })
        #expect(report.approvalRequests.contains { $0.id == "dispute-response-dp_1" })
        #expect(report.approvalRequests.contains { $0.id == "payment-action-cb_1" })
    }

    @Test
    func fraudSignalsCoverVelocityCountryRefundMetadataAndProductRisk() {
        var events = (0..<13).map {
            transaction(id: "txn_\($0)", customerID: "cust-1", amountUSD: 10)
        }
        events.append(transaction(
            id: "country",
            customerID: "cust-2",
            amountUSD: 10,
            country: "US",
            paymentInstrumentCountry: "NG"
        ))
        events.append(transaction(id: "refund-1", kind: .refund, customerID: "cust-3", amountUSD: 10))
        events.append(transaction(id: "refund-2", kind: .refund, customerID: "cust-3", amountUSD: 10))
        events.append(transaction(id: "refund-3", kind: .refund, customerID: "cust-3", amountUSD: 10))
        events.append(transaction(id: "metadata", customerID: "cust-4", amountUSD: 10, metadataFlags: ["proxy_ip"]))
        events.append(transaction(id: "prohibited", customerID: "cust-5", amountUSD: 10, productRisk: .prohibited))

        let report = CompanyPaymentsRiskEngine.evaluate(
            account: healthyAccount(),
            transactions: events,
            disputes: [],
            now: now
        )

        #expect(report.fraudSignals.contains { $0.kind == .velocity })
        #expect(report.fraudSignals.contains { $0.kind == .countryMismatch })
        #expect(report.fraudSignals.contains { $0.kind == .repeatedRefunds })
        #expect(report.fraudSignals.contains { $0.kind == .suspiciousMetadata })
        #expect(report.fraudSignals.contains { $0.kind == .highRiskProduct && $0.severity == .critical })
        #expect(report.shouldPauseCompany)
    }

    @Test
    func paymentOutcomesFeedVerifiedLedgerAdjustments() {
        let charge = transaction(id: "sale_1", kind: .charge, amountUSD: 120)
        let refund = transaction(id: "refund_1", kind: .refund, amountUSD: 20)
        let failed = transaction(id: "failed_1", kind: .failedPayment, amountUSD: 50)
        let lostDispute = CompanyPaymentDispute(
            id: "dp_lost",
            companyID: "company-1",
            transactionID: "sale_2",
            amountUSD: 30,
            reason: "product_not_received",
            status: .lost,
            responseDueAt: nil,
            providerReference: "du_lost"
        )

        let report = CompanyPaymentsRiskEngine.evaluate(
            account: healthyAccount(),
            transactions: [charge, refund, failed],
            disputes: [lostDispute],
            now: now
        )
        let summary = CompanyLedgerSummary(entries: report.ledgerAdjustments)

        #expect(summary.revenueUSD == 120)
        #expect(summary.refundUSD == 50)
        #expect(summary.hasVerifiedRevenue)
        #expect(report.ledgerAdjustments.allSatisfy { $0.confidence == .verified })
        #expect(!report.ledgerAdjustments.contains { $0.id == "payment-failed_1" })
    }

    @Test
    func lifecyclePausesCompanyWithUnresolvedPaymentRisk() {
        let riskyReport = CompanyPaymentsRiskEngine.evaluate(
            account: healthyAccount(),
            transactions: [transaction(id: "prohibited", productRisk: .prohibited)],
            disputes: [],
            now: now
        )
        let evidence = CompanyEvidenceSnapshot(
            companyID: "company-1",
            stage: .launched,
            validationDecision: nil,
            ledger: .empty,
            budgetReport: nil,
            distribution: nil,
            paymentsRisk: riskyReport,
            failureCount: 0,
            complianceRisk: .low,
            overrideReason: nil,
            artifactPaths: []
        )

        let decision = CompanyLifecycleEngine.decide(evidence)

        #expect(decision.action == .pause)
        #expect(decision.to == .paused)
        #expect(decision.rationale.contains("payments risk"))
    }

    private func healthyAccount(liveBillingRequested: Bool = false) -> CompanyPaymentAccount {
        CompanyPaymentAccount(
            companyID: "company-1",
            provider: .stripe,
            mode: .sandbox,
            chargesEnabled: true,
            payoutsEnabled: true,
            kycStatus: .verified,
            requirementsDue: [],
            payoutHoldReasons: [],
            liveBillingRequested: liveBillingRequested,
            sandboxTests: CompanyPaymentsRiskPolicy.productionDefault.requiredSandboxTests.map {
                CompanyPaymentSandboxTest(id: $0.rawValue, kind: $0, passed: true, evidence: "\($0.rawValue)-ok")
            }
        )
    }

    private func transaction(
        id: String,
        kind: CompanyPaymentTransaction.Kind = .charge,
        customerID: String? = "cust-1",
        amountUSD: Double = 10,
        country: String? = "US",
        paymentInstrumentCountry: String? = "US",
        productRisk: CompanyPaymentTransaction.ProductRisk = .low,
        metadataFlags: [String] = []
    ) -> CompanyPaymentTransaction {
        CompanyPaymentTransaction(
            id: id,
            companyID: "company-1",
            customerID: customerID,
            occurredAt: now.addingTimeInterval(-60),
            kind: kind,
            amountUSD: amountUSD,
            currency: "USD",
            country: country,
            paymentInstrumentCountry: paymentInstrumentCountry,
            productRisk: productRisk,
            metadataFlags: metadataFlags,
            providerReference: "pi_\(id)"
        )
    }
}
