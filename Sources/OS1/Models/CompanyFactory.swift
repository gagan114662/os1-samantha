import Foundation

struct CompanyFactoryAsset: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case landingPage
        case pricingPage
        case paymentLink
        case crmTable
        case supportInbox
        case supportEscalationPolicy
        case supportTickets
        case analyticsPlan
        case deploymentChecklist
        case brandGuide
        case onboardingFlow
        case refundPolicy
        case termsOfService
        case privacyPolicy
        case acceptableUsePolicy
        case legalMetadata
        case taxChecklist
        case salesScript
        case compliancePolicy
        case browserPolicy
    }

    let id: String
    var kind: Kind
    var title: String
    var path: String
    var sandboxTestable: Bool
    var requiresApprovalBeforePublish: Bool
}

struct CompanyFactoryGate: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case compliance
        case legal
        case security
        case budget
        case support
    }

    let id: String
    var kind: Kind
    var title: String
    var passed: Bool
    var evidence: String
}

struct CompanyFactoryManifest: Codable, Hashable {
    let companyID: String
    var templateID: String?
    var offer: String
    var icp: String
    var channel: String
    var assets: [CompanyFactoryAsset]
    var gates: [CompanyFactoryGate]

    var canLaunch: Bool {
        gates.allSatisfy(\.passed)
    }
}

enum CompanyFactory {
    static func manifest(
        companyID: String,
        template: CompanyTemplate?,
        worktreePath: String
    ) -> CompanyFactoryManifest {
        let offer = template?.mission ?? "Validate and sell the smallest paid offer."
        let icp = template.map { CompanyIdeaEngine.candidates(from: [$0], limit: 1).first?.icp ?? "Target customer" } ?? "Target customer"
        let channel = template?.channel ?? "Manual validation"
        let files: [(CompanyFactoryAsset.Kind, String, Bool, Bool)] = [
            (.landingPage, "landing-page.md", true, true),
            (.pricingPage, "pricing-page.md", true, true),
            (.paymentLink, "payments-sandbox.md", true, true),
            (.crmTable, "crm.csv", true, false),
            (.supportInbox, "support-inbox.md", true, false),
            (.supportEscalationPolicy, "support-escalation-policy.md", true, true),
            (.supportTickets, "support-tickets.json", true, false),
            (.analyticsPlan, "analytics-plan.md", true, false),
            (.deploymentChecklist, "launch-checklist.md", true, false),
            (.brandGuide, "brand-guide.md", true, false),
            (.onboardingFlow, "onboarding-flow.md", true, false),
            (.refundPolicy, "refund-policy.md", true, true),
            (.termsOfService, "terms-of-service.md", true, true),
            (.privacyPolicy, "privacy-policy.md", true, true),
            (.acceptableUsePolicy, "acceptable-use-policy.md", true, true),
            (.legalMetadata, "legal-metadata.json", true, true),
            (.taxChecklist, "tax-checklist.md", true, true),
            (.salesScript, "first-sales-script.md", true, true),
            (.compliancePolicy, "COMPLIANCE_POLICY.json", true, false),
            (.browserPolicy, "BROWSER_POLICY.json", true, false)
        ]
        return CompanyFactoryManifest(
            companyID: companyID,
            templateID: template?.id,
            offer: offer,
            icp: icp,
            channel: channel,
            assets: files.map { kind, filename, testable, approval in
                CompanyFactoryAsset(
                    id: kind.rawValue,
                    kind: kind,
                    title: title(for: kind),
                    path: "\(worktreePath)/\(filename)",
                    sandboxTestable: testable,
                    requiresApprovalBeforePublish: approval
                )
            },
            gates: [
                .init(id: "compliance", kind: .compliance, title: "Compliance review passed", passed: false, evidence: ""),
                .init(id: "legal", kind: .legal, title: "Legal readiness approved", passed: false, evidence: ""),
                .init(id: "security", kind: .security, title: "Security and credential scope reviewed", passed: false, evidence: ""),
                .init(id: "budget", kind: .budget, title: "Budget and spend approval passed", passed: false, evidence: ""),
                .init(id: "support", kind: .support, title: "Support contact and escalation policy configured", passed: false, evidence: "")
            ]
        )
    }

    static func checklistMarkdown(_ manifest: CompanyFactoryManifest) -> String {
        """
        # Launch checklist

        Offer: \(manifest.offer)
        ICP: \(manifest.icp)
        Channel: \(manifest.channel)

        ## Assets
        \(manifest.assets.map { "- [ ] \($0.title): \($0.path)\($0.requiresApprovalBeforePublish ? " (approval before publish)" : "")" }.joined(separator: "\n"))

        ## Gates
        \(manifest.gates.map { "- [ ] \($0.title)" }.joined(separator: "\n"))

        Launch is blocked until compliance, legal, security, budget, and support gates pass.
        """
    }

    static func starterContent(for asset: CompanyFactoryAsset, manifest: CompanyFactoryManifest) -> String {
        switch asset.kind {
        case .landingPage:
            return "# \(manifest.offer)\n\nICP: \(manifest.icp)\n\nCTA: Join the validation list.\n"
        case .pricingPage:
            return "# Pricing\n\nSandbox price tests only until willingness-to-pay evidence is collected.\n"
        case .paymentLink:
            return "# Payments sandbox\n\nUse Stripe test mode only. No live charges without approval.\n"
        case .crmTable:
            return "name,email,source,status,consent,notes\n"
        case .supportInbox:
            return "# Support inbox\n\nTrack customer requests, refunds, and escalation notes here.\n"
        case .supportEscalationPolicy:
            return "# Support escalation policy\n\n- Support contact:\n- SLA hours:\n- Escalate angry customers, safety reports, payment disputes, and legal requests to the user.\n- Refunds, legal claims, and account actions require approval before sending.\n"
        case .supportTickets:
            return "[]\n"
        case .analyticsPlan:
            return "# Analytics\n\nTrack visits, signups, reply rate, CAC estimate, and paid conversions.\n"
        case .deploymentChecklist:
            return checklistMarkdown(manifest)
        case .brandGuide:
            return "# Brand\n\nPositioning, voice, colors, and proof points.\n"
        case .onboardingFlow:
            return "# Onboarding\n\nSteps from signup to first value.\n"
        case .refundPolicy:
            return "# Cancellation and refund policy\n\nDraft only. Review before publishing.\n"
        case .termsOfService:
            return "# Terms of service\n\nDraft from docs/legal/terms-of-service-template.md before publishing.\n"
        case .privacyPolicy:
            return "# Privacy policy\n\nDraft from docs/legal/privacy-policy-template.md before publishing.\n"
        case .acceptableUsePolicy:
            return "# Acceptable use policy\n\nDraft from docs/legal/acceptable-use-policy-template.md.\n"
        case .legalMetadata:
            return legalMetadataStarter(manifest)
        case .taxChecklist:
            return "# Tax checklist\n\n- [ ] Sales tax/VAT exposure reviewed\n- [ ] Invoicing template linked\n- [ ] Bookkeeping categories mapped\n- [ ] Vendor/1099 posture documented\n"
        case .salesScript:
            return "# First sales script\n\nDraft only. Do not send without approval.\n"
        case .compliancePolicy:
            return """
            {
              "legalBasis": "",
              "unsubscribePath": "",
              "disclosureText": "",
              "targetAudience": "\(manifest.icp)",
              "contactSource": "",
              "dataRetentionPolicy": "",
              "browserAutomationPolicy": {
                "allowedDomains": [],
                "allowedActions": []
              }
            }

            """
        case .browserPolicy:
            return """
            {
              "companyID": "\(manifest.companyID)",
              "approvedDomains": [],
              "allowedActions": [],
              "preferredIntegrations": {}
            }

            """
        }
    }

    private static func title(for kind: CompanyFactoryAsset.Kind) -> String {
        switch kind {
        case .landingPage: return "Landing page"
        case .pricingPage: return "Pricing page"
        case .paymentLink: return "Sandbox payment link"
        case .crmTable: return "CRM table"
        case .supportInbox: return "Support inbox"
        case .supportEscalationPolicy: return "Support escalation policy"
        case .supportTickets: return "Support tickets"
        case .analyticsPlan: return "Analytics plan"
        case .deploymentChecklist: return "Deployment checklist"
        case .brandGuide: return "Brand guide"
        case .onboardingFlow: return "Onboarding flow"
        case .refundPolicy: return "Cancellation/refund policy"
        case .termsOfService: return "Terms of service"
        case .privacyPolicy: return "Privacy policy"
        case .acceptableUsePolicy: return "Acceptable use policy"
        case .legalMetadata: return "Legal metadata"
        case .taxChecklist: return "Tax checklist"
        case .salesScript: return "First sales script"
        case .compliancePolicy: return "Compliance and browser policy"
        case .browserPolicy: return "Browser automation policy"
        }
    }

    private static func legalMetadataStarter(_ manifest: CompanyFactoryManifest) -> String {
        """
        {
          "companyID": "\(manifest.companyID)",
          "legalOwner": "",
          "entityName": "",
          "jurisdiction": "",
          "termsOfServiceURL": null,
          "privacyPolicyURL": null,
          "refundPolicyURL": null,
          "acceptableUsePolicyURL": null,
          "dataProcessingAddendumURL": null,
          "refundTerms": "",
          "taxPosture": {
            "salesTaxNexus": [],
            "vatGSTExposure": [],
            "requires1099Collection": false,
            "invoiceTemplateURL": null,
            "bookkeepingCategories": []
          },
          "executedContractLinks": [],
          "reviewedAt": null,
          "approvalRequestID": null
        }
        """
    }
}
