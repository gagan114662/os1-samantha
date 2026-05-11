import Foundation
import Testing
@testable import OS1

struct CompanyBrowserAutomationTests {
    @Test
    func browserActionsProduceReplayableTraces() {
        let action = browserAction()
        let trace = CompanyBrowserAutomationEngine.trace(
            action: action,
            sessionID: "browser-session-1",
            outcome: .succeeded,
            screenshotPath: "browser-traces/action.png",
            domSnapshotPath: "browser-traces/action.html",
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(trace.isReplayable)
        #expect(trace.selector == "#pricing")
        #expect(trace.semanticTarget == "Pricing CTA")
        #expect(trace.screenshotPath == "browser-traces/action.png")
        #expect(trace.domSnapshotPath == "browser-traces/action.html")
    }

    @Test
    func browserAutomationIsBlockedOutsideApprovedDomainOrAction() {
        let policy = CompanyBrowserSafetyPolicy(
            companyID: "company",
            approvedDomains: ["example.com"],
            allowedActions: ["read-public-page"],
            preferredIntegrations: [:]
        )

        let deniedDomain = CompanyBrowserAutomationEngine.plan(
            action: browserAction(domain: "evil.example", actionName: "read-public-page"),
            policy: policy
        )
        let deniedAction = CompanyBrowserAutomationEngine.plan(
            action: browserAction(domain: "example.com", actionName: "submit-owned-form"),
            policy: policy
        )
        let allowed = CompanyBrowserAutomationEngine.plan(
            action: browserAction(domain: "https://example.com/pricing", actionName: "read-public-page"),
            policy: policy
        )

        #expect(deniedDomain.status == .blocked)
        #expect(deniedDomain.blockers.contains { $0.contains("not approved") })
        #expect(deniedAction.status == .blocked)
        #expect(deniedAction.blockers.contains { $0.contains("not allowed") })
        #expect(allowed.canExecuteWithBrowser)
    }

    @Test
    func apiFirstDomainsPreferStableAPIsOrConnectors() {
        let policy = CompanyBrowserSafetyPolicy(
            companyID: "company",
            approvedDomains: ["stripe.com"],
            allowedActions: ["download-report"],
            preferredIntegrations: [:]
        )

        let plan = CompanyBrowserAutomationEngine.plan(
            action: browserAction(domain: "stripe.com", actionName: "download-report"),
            policy: policy
        )

        #expect(plan.status == .preferAPI)
        #expect(plan.preferredIntegration == .api)
        #expect(!plan.canExecuteWithBrowser)
    }

    @Test
    func failuresEscalateWithScreenshotContextInsteadOfContinuingBlindly() {
        let action = browserAction()
        let trace = CompanyBrowserAutomationEngine.trace(
            action: action,
            sessionID: "browser-session-1",
            outcome: .failed,
            screenshotPath: "browser-traces/captcha.png",
            domSnapshotPath: "browser-traces/captcha.html",
            failureKind: .captcha
        )

        #expect(trace.outcome == .failed)
        #expect(trace.recovery.decision == .blockedNeedsHuman)
        #expect(trace.recovery.requiresHuman)
        #expect(trace.isReplayable)
    }

    @Test
    func commonUIFailuresHaveDeterministicRecoveryPaths() {
        #expect(CompanyBrowserAutomationEngine.recovery(for: .loginExpired).decision == .blockedNeedsHuman)
        #expect(CompanyBrowserAutomationEngine.recovery(for: .captcha).decision == .blockedNeedsHuman)
        #expect(CompanyBrowserAutomationEngine.recovery(for: .rateLimit).decision == .retry)
        #expect(CompanyBrowserAutomationEngine.recovery(for: .popup).decision == .closePopupAndRetry)
        #expect(CompanyBrowserAutomationEngine.recovery(for: .layoutChanged).decision == .refreshAndRetry)
        #expect(CompanyBrowserAutomationEngine.recovery(for: .selectorMissing).decision == .refreshAndRetry)
        #expect(CompanyBrowserAutomationEngine.recovery(for: .domainDenied).decision == .blockedPolicy)
    }

    @Test
    func blindCoordinateActionsAreBlockedByMissingSelectorAndSemanticTarget() {
        let policy = CompanyBrowserSafetyPolicy(
            companyID: "company",
            approvedDomains: ["example.com"],
            allowedActions: ["read-public-page"],
            preferredIntegrations: [:]
        )
        let action = CompanyBrowserAction(
            id: "blind-click",
            companyID: "company",
            domain: "example.com",
            kind: .readPublicPage,
            actionName: "read-public-page",
            semanticTarget: "",
            selector: nil,
            expectedResult: "read page"
        )

        let plan = CompanyBrowserAutomationEngine.plan(action: action, policy: policy)

        #expect(plan.status == .blocked)
        #expect(plan.blockers.contains { $0.contains("selector or semantic") })
    }

    private func browserAction(
        domain: String = "example.com",
        actionName: String = "read-public-page"
    ) -> CompanyBrowserAction {
        CompanyBrowserAction(
            id: "action-1",
            companyID: "company",
            domain: domain,
            kind: .readPublicPage,
            actionName: actionName,
            semanticTarget: "Pricing CTA",
            selector: "#pricing",
            expectedResult: "pricing text captured"
        )
    }
}
