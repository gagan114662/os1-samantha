import Foundation
import Testing
@testable import OS1

struct CompanyEnvironmentTests {
    @Test
    func eachEnvironmentHasExplicitAllowedSideEffects() {
        #expect(CompanyEnvironmentState(mode: .dev).allowedSideEffects.contains(.ciEvaluation))
        #expect(CompanyEnvironmentState(mode: .sandbox).allowedSideEffects.contains(.sandboxPayment))
        #expect(CompanyEnvironmentState(mode: .staging).allowedSideEffects.contains(.stagingDeployment))
        #expect(CompanyEnvironmentState(mode: .production).allowedSideEffects.contains(.livePayment))
        #expect(!CompanyEnvironmentState(mode: .sandbox).allowedSideEffects.contains(.livePayment))
    }

    @Test
    func productionCredentialsAreBlockedOutsideProductionByDefault() {
        let credentials = [
            "STRIPE_API_KEY": "sk_live_secret",
            "STRIPE_TEST_API_KEY": "sk_test_secret",
            "RESEND_PROD_API_KEY": "re_secret",
            "SANDBOX_TOOL_KEY": "sandbox-secret"
        ]

        let filtered = CompanyEnvironmentGuard.filteredCredentials(
            credentials,
            state: CompanyEnvironmentState(mode: .sandbox)
        )

        #expect(filtered.credentials.keys.sorted() == ["SANDBOX_TOOL_KEY", "STRIPE_TEST_API_KEY"])
        #expect(filtered.blockedNames == ["RESEND_PROD_API_KEY", "STRIPE_API_KEY"])
    }

    @Test
    func productionCredentialExceptionMustBeExplicit() {
        let credentials = ["STRIPE_API_KEY": "sk_live_secret"]
        let state = CompanyEnvironmentState(
            mode: .sandbox,
            allowProductionCredentialsOutsideProduction: true
        )

        let filtered = CompanyEnvironmentGuard.filteredCredentials(credentials, state: state)

        #expect(filtered.credentials.keys.sorted() == ["STRIPE_API_KEY"])
        #expect(filtered.blockedNames.isEmpty)
    }

    @Test
    func liveProductionActionsRequireApprovalAndBanner() {
        let state = CompanyEnvironmentState(mode: .production)
        let decision = CompanyEnvironmentGuard.evaluate(
            state: state,
            requestedSideEffects: [.livePayment, .liveOutboundSend]
        )
        let approved = CompanyEnvironmentGuard.evaluate(
            state: state,
            requestedSideEffects: [.livePayment],
            approvalRecorded: true
        )

        #expect(decision.requiresApproval)
        #expect(!decision.allowed)
        #expect(decision.reasons.contains("liveProductionApprovalRequired"))
        #expect(decision.banner.contains("LIVE PRODUCTION"))
        #expect(approved.allowed)
    }

    @Test
    func ciAndEvalsCanOnlyUseDevOrSandbox() {
        let sandboxDecision = CompanyEnvironmentGuard.evaluate(
            state: CompanyEnvironmentState(mode: .sandbox),
            requestedSideEffects: [.ciEvaluation],
            workflowKind: "ci"
        )
        let stagingDecision = CompanyEnvironmentGuard.evaluate(
            state: CompanyEnvironmentState(mode: .staging),
            requestedSideEffects: [.ciEvaluation],
            workflowKind: "eval"
        )

        #expect(sandboxDecision.allowed)
        #expect(!stagingDecision.allowed)
        #expect(stagingDecision.reasons.contains("ciEvalMustUseDevOrSandbox"))
    }

    @Test
    func sandboxToProductionMigrationCarriesSourceAndProductionResources() {
        let state = CompanyEnvironmentGuard.migrationPlan(
            sandboxCompanyID: "sandbox-co",
            productionCompanyID: "prod-co",
            productionResources: [
                CompanyEnvironmentResource(
                    id: "stripe-live",
                    kind: .paymentProvider,
                    name: "Stripe live account",
                    environment: .production,
                    reference: "stripe://acct_live"
                )
            ]
        )

        #expect(state.mode == .production)
        #expect(state.migrationSourceCompanyID == "sandbox-co")
        #expect(state.resources.first?.environment == .production)
    }
}
