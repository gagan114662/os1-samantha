import Foundation
import Testing
@testable import OS1

struct CompanyComplianceEngineTests {
    @Test
    func obviousSpamIsBlockedWithConcreteFix() {
        let decision = CompanyComplianceEngine.evaluate(action: action(
            channel: .email,
            proposedAction: "Send a bulk DM blast to a bought list",
            content: "Use scraped contacts and no unsubscribe link",
            metadata: CompanyComplianceMetadata(
                legalBasis: nil,
                unsubscribePath: nil,
                disclosureText: nil,
                targetAudience: "Local businesses",
                contactSource: "bought list",
                dataRetentionPolicy: nil
            )
        ))

        #expect(decision.status == .blocked)
        #expect(decision.findings.contains { $0.id == "spam-risk" })
        #expect(decision.fixes.contains { $0.contains("opt-in") })
    }

    @Test
    func credentialMisuseAndUnallowlistedCredentialAreBlocked() {
        let decision = CompanyComplianceEngine.evaluate(
            action: action(
                channel: .payments,
                proposedAction: "Use the customer private token to create checkout",
                content: "Paste the API key into the public deploy log",
                metadata: compliantMetadata(),
                requestedCredential: "STRIPE_API_KEY"
            ),
            allowedCredentialNames: ["RESEND_API_KEY"]
        )

        #expect(decision.status == .blocked)
        #expect(decision.findings.contains { $0.id == "credential-misuse" })
        #expect(decision.findings.contains { $0.id == "credential-not-allowed" })
    }

    @Test
    func privacyLeakWithoutLegalBasisIsBlocked() {
        let decision = CompanyComplianceEngine.evaluate(action: action(
            channel: .dataCollection,
            proposedAction: "Upload customer list with phone numbers",
            content: "Store personal data for later retargeting",
            metadata: CompanyComplianceMetadata(
                legalBasis: nil,
                unsubscribePath: nil,
                disclosureText: "Commercial use",
                targetAudience: "Customers",
                contactSource: "support inbox",
                dataRetentionPolicy: nil
            )
        ))

        #expect(decision.status == .blocked)
        #expect(decision.findings.contains { $0.id == "privacy-leak-risk" })
        #expect(decision.fixes.contains { $0.contains("retention/deletion") })
    }

    @Test
    func deceptiveOfferIsBlocked() {
        let decision = CompanyComplianceEngine.evaluate(action: action(
            channel: .marketplace,
            proposedAction: "Publish fake reviews with guaranteed income claims",
            content: "Pretend to be a customer and post five-star proof",
            metadata: compliantMetadata()
        ))

        #expect(decision.status == .blocked)
        #expect(decision.findings.contains { $0.id == "deceptive-flow" })
        #expect(decision.findings.contains { $0.id == "risky-claim" })
    }

    @Test
    func browserAutomationRequiresExplicitAllowedDomainAndAction() {
        let missingPolicy = CompanyComplianceEngine.evaluate(action: action(
            channel: .browserAutomation,
            proposedAction: "Click through a third-party dashboard",
            content: "Use browser automation",
            targetDomain: "stripe.com",
            browserAction: "read-public-page"
        ))

        let deniedDomain = CompanyComplianceEngine.evaluate(action: action(
            channel: .browserAutomation,
            proposedAction: "Read dashboard",
            content: "Use browser automation",
            browserPolicy: CompanyBrowserAutomationPolicy(
                allowedDomains: ["example.com"],
                allowedActions: ["read-public-page"]
            ),
            targetDomain: "stripe.com",
            browserAction: "read-public-page"
        ))

        let allowed = CompanyComplianceEngine.evaluate(action: action(
            channel: .browserAutomation,
            proposedAction: "Read owned page",
            content: "Use browser automation",
            browserPolicy: CompanyBrowserAutomationPolicy(
                allowedDomains: ["example.com"],
                allowedActions: ["read-public-page"]
            ),
            targetDomain: "https://example.com/pricing",
            browserAction: "read-public-page"
        ))

        #expect(missingPolicy.status == .blocked)
        #expect(missingPolicy.findings.contains { $0.id == "missing-browser-policy" })
        #expect(deniedDomain.status == .blocked)
        #expect(deniedDomain.findings.contains { $0.id == "browser-policy-denied" })
        #expect(allowed.status == .approved)
    }

    @Test
    func regulatedIndustryRequiresHumanReviewEvenWithMetadata() {
        let decision = CompanyComplianceEngine.evaluate(action: action(
            channel: .email,
            proposedAction: "Email law firm leads about intake automation",
            content: "Draft only with attorney-client confidentiality notes",
            metadata: compliantMetadata()
        ))

        #expect(decision.status == .humanReviewRequired)
        #expect(decision.findings.contains { $0.id == "regulated-industry-review" })
    }

    private func action(
        channel: CompanyComplianceChannel,
        proposedAction: String,
        content: String,
        metadata: CompanyComplianceMetadata? = nil,
        browserPolicy: CompanyBrowserAutomationPolicy? = nil,
        targetDomain: String? = nil,
        browserAction: String? = nil,
        requestedCredential: String? = nil
    ) -> CompanyComplianceAction {
        CompanyComplianceAction(
            companyID: "company",
            channel: channel,
            proposedAction: proposedAction,
            content: content,
            metadata: metadata,
            browserPolicy: browserPolicy,
            targetDomain: targetDomain,
            browserAction: browserAction,
            requestedCredential: requestedCredential
        )
    }

    private func compliantMetadata() -> CompanyComplianceMetadata {
        CompanyComplianceMetadata(
            legalBasis: "legitimate-interest",
            unsubscribePath: "Reply unsubscribe",
            disclosureText: "Commercial message from the company",
            targetAudience: "Small business owners",
            contactSource: "manually sourced public business pages",
            dataRetentionPolicy: "Delete non-responders after 30 days"
        )
    }
}
