import Foundation

struct CompanyFactoryAsset: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case landingPage
        case pricingPage
        case paymentLink
        case crmTable
        case suppressionList
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
        worktreePath: String,
        offer customOffer: String? = nil,
        icp customICP: String? = nil,
        channel customChannel: String? = nil
    ) -> CompanyFactoryManifest {
        let offer = template?.mission ?? normalized(customOffer) ?? "Validate and sell the smallest paid offer."
        let icp =
            template.map { CompanyIdeaEngine.candidates(from: [$0], limit: 1).first?.icp ?? "Target customer" }
            ?? normalized(customICP)
            ?? inferredICP(from: offer)
        let channel = template?.channel ?? normalized(customChannel) ?? inferredChannel(from: offer)
        let files: [(CompanyFactoryAsset.Kind, String, Bool, Bool)] = [
            (.landingPage, "landing-page.md", true, true),
            (.pricingPage, "pricing-page.md", true, true),
            (.paymentLink, "payments-sandbox.md", true, true),
            (.crmTable, "crm.csv", true, false),
            (.suppressionList, "suppression-list.csv", true, false),
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
            (.browserPolicy, "BROWSER_POLICY.json", true, false),
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
                .init(
                    id: "compliance", kind: .compliance, title: "Compliance review passed", passed: false, evidence: ""),
                .init(id: "legal", kind: .legal, title: "Legal readiness approved", passed: false, evidence: ""),
                .init(
                    id: "security", kind: .security, title: "Security and credential scope reviewed", passed: false,
                    evidence: ""),
                .init(
                    id: "budget", kind: .budget, title: "Budget and spend approval passed", passed: false, evidence: ""),
                .init(
                    id: "support", kind: .support, title: "Support contact and escalation policy configured",
                    passed: false, evidence: ""),
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
        let context = contentContext(for: manifest)
        switch asset.kind {
        case .landingPage:
            return """
                # \(manifest.offer)

                ICP: \(manifest.icp)
                Primary channel: \(context.channel)
                Category: \(context.category)

                ## Proof required before launch
                \(bulletList(context.validationSignals, fallback: ["first-party signup or reply intent", "willingness-to-pay evidence", "channel-specific demand signal"]))

                CTA: Join the validation list for this \(context.category.lowercased()) offer.
                """
        case .pricingPage:
            return """
                # Pricing

                Offer: \(context.offer)
                Target buyer: \(context.icp)
                Channel: \(context.channel)
                Model: \(context.category)

                ## Sandbox price tests
                \(bulletList(pricingTests(for: context), fallback: ["Test one low-friction paid commitment before building at scale."]))

                Do not publish live prices or charge cards until willingness-to-pay evidence is collected and approval is granted.
                """
        case .paymentLink:
            return """
                # Payments sandbox

                Offer: \(context.offer)
                Channel: \(context.channel)

                Use Stripe test mode only. No live charges without approval.

                ## Checkout draft
                - Product label: \(context.title)
                - Buyer segment: \(context.icp)
                - Fulfillment asset: \(context.launchAssets.first ?? "smallest paid deliverable")
                - Approval gate: budget, legal, refund, and support policy must pass before live mode.
                """
        case .crmTable:
            return "name,email,source,status,consent,account_id,owner,segment,interest_signal,notes\n# default_source=\(context.channel) default_segment=\(context.icp)\n"
        case .suppressionList:
            return "email,reason,source_company_id,channel,recorded_at\n# channel defaults to \(context.channel)\n"
        case .supportInbox:
            return """
                # Support inbox

                Company: \(context.title)
                Buyer: \(context.icp)
                Channel: \(context.channel)

                Track requests tied to:
                \(bulletList(context.launchAssets, fallback: ["the initial paid offer", "refunds", "setup help"]))

                Escalate any refund, legal, safety, account-access, or platform-policy concern before replying.
                """
        case .supportEscalationPolicy:
            return """
                # Support escalation policy

                - Support contact:
                - SLA hours:
                - Escalate complaints involving \(context.offer)
                - Escalate platform/channel risk on \(context.channel)
                - Escalate these known risks: \(inlineList(context.riskNotes, fallback: "payment disputes, legal requests, and unsafe claims"))
                - Refunds, legal claims, and account actions require approval before sending.
                """
        case .supportTickets:
            return "[]\n"
        case .analyticsPlan:
            return """
                # Analytics

                Offer: \(context.offer)
                ICP: \(context.icp)
                Primary channel: \(context.channel)

                ## Validation signals
                \(bulletList(context.validationSignals, fallback: ["qualified visits", "signup intent", "reply rate", "paid conversion"]))

                ## Funnel metrics
                \(bulletList(analyticsMetrics(for: context), fallback: ["visits", "signups", "reply rate", "paid conversions"]))

                ## Decision rule
                Keep the company in validation until real buyer intent or willingness-to-pay evidence beats the template threshold.
                """
        case .deploymentChecklist:
            return checklistMarkdown(manifest)
        case .brandGuide:
            return """
                # Brand

                Company: \(context.title)
                Category: \(context.category)
                Positioning: \(context.offer)
                Audience: \(context.icp)
                Primary channel: \(context.channel)

                ## Proof points to collect
                \(bulletList(context.validationSignals, fallback: ["buyer pain", "willingness to pay", "delivery proof"]))

                ## Guardrails
                \(bulletList(context.riskNotes, fallback: ["No unsupported claims", "No live launch without approval"]))
                """
        case .onboardingFlow:
            return """
                # Onboarding

                First value promise: \(context.offer)
                Target buyer: \(context.icp)

                ## Flow
                \(numberedList(onboardingSteps(for: context), fallback: ["Confirm the buyer problem", "Deliver the smallest useful asset", "Ask for outcome feedback"]))
                """
        case .refundPolicy:
            return """
                # Cancellation and refund policy

                Draft only. Review before publishing.

                Offer under review: \(context.offer)
                Fulfillment assets: \(inlineList(context.launchAssets, fallback: "initial deliverable"))
                Channel-specific risks: \(inlineList(context.riskNotes, fallback: "refund disputes and platform policy constraints"))
                """
        case .termsOfService:
            return """
                # Terms of service

                Draft from docs/legal/terms-of-service-template.md before publishing.

                Offer scope: \(context.offer)
                Audience: \(context.icp)
                Channel: \(context.channel)

                Category constraints:
                \(bulletList(context.riskNotes, fallback: ["No unsupported claims", "No live launch without approval"]))
                """
        case .privacyPolicy:
            return """
                # Privacy policy

                Draft from docs/legal/privacy-policy-template.md before publishing.

                Expected data for \(context.icp): contact details, consent source, campaign/source attribution from \(context.channel), support notes, and purchase metadata.
                """
        case .acceptableUsePolicy:
            return """
                # Acceptable use policy

                Draft from docs/legal/acceptable-use-policy-template.md.

                This company may only use \(context.offer) for compliant \(context.channel) experiments. Disallow spam, fabricated proof, platform-term violations, and claims outside the validated offer.
                """
        case .legalMetadata:
            return legalMetadataStarter(manifest)
        case .taxChecklist:
            return """
                # Tax checklist

                - [ ] Sales tax/VAT exposure reviewed for \(context.category)
                - [ ] Invoicing template linked for \(context.offer)
                - [ ] Bookkeeping categories mapped for \(context.channel)
                - [ ] Vendor/1099 posture documented
                """
        case .salesScript:
            return """
                # First sales script

                Draft only. Do not send without approval.

                Hi {{first_name}},

                I am validating \(context.offer) for \(context.icp). I found you through \(context.channel) and I am looking for a small number of buyers who will give blunt feedback before this becomes a full product.

                The first deliverable is \(context.launchAssets.first ?? "a focused starter version"). If this is relevant, would you pay for an early version or point me to the blocker that would make it a no?

                Known constraints: \(inlineList(context.riskNotes, fallback: "no live charges or external sends without approval")).
                """
        case .compliancePolicy:
            return """
                {
                  "legalBasis": "",
                  "unsubscribePath": "",
                  "disclosureText": "",
                  "targetAudience": "\(manifest.icp)",
                  "contactSource": "",
                  "primaryChannel": "\(context.channel)",
                  "templateCategory": "\(context.category)",
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
                  "preferredIntegrations": {},
                  "primaryChannel": "\(context.channel)"
                }

                """
        }
    }

    private struct StarterContentContext {
        var title: String
        var category: String
        var offer: String
        var icp: String
        var channel: String
        var validationSignals: [String]
        var launchAssets: [String]
        var riskNotes: [String]
    }

    private static func contentContext(for manifest: CompanyFactoryManifest) -> StarterContentContext {
        let template = manifest.templateID.flatMap(CompanyTemplateCatalog.template(id:))
        return StarterContentContext(
            title: template?.title ?? "Company \(manifest.companyID)",
            category: template?.category.rawValue ?? "Custom company",
            offer: manifest.offer,
            icp: manifest.icp,
            channel: manifest.channel,
            validationSignals: template?.validationSignals ?? [],
            launchAssets: template?.launchAssets ?? [],
            riskNotes: template?.riskNotes ?? []
        )
    }

    private static func normalized(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private static func inferredICP(from offer: String) -> String {
        let lower = offer.lowercased()
        if lower.contains("etsy") { return "Etsy sellers" }
        if lower.contains("youtube") { return "YouTube creators and viewers in the niche" }
        if lower.contains("newsletter") { return "Newsletter readers or sponsors in the niche" }
        if lower.contains("realtor") || lower.contains("real estate") { return "Real estate operators" }
        if lower.contains("shopify") { return "Shopify merchants" }
        if lower.contains("local") { return "Local business owners" }
        return "Target customer described by the operator mission"
    }

    private static func inferredChannel(from offer: String) -> String {
        let lower = offer.lowercased()
        if lower.contains("etsy") { return "Etsy" }
        if lower.contains("youtube") { return "YouTube" }
        if lower.contains("newsletter") { return "Newsletter" }
        if lower.contains("seo") { return "SEO" }
        if lower.contains("outreach") { return "Outbound outreach" }
        if lower.contains("gumroad") { return "Gumroad/own site" }
        return "Manual validation"
    }

    private static func bulletList(_ values: [String], fallback: [String]) -> String {
        let items = values.isEmpty ? fallback : values
        return items.map { "- \($0)" }.joined(separator: "\n")
    }

    private static func numberedList(_ values: [String], fallback: [String]) -> String {
        let items = values.isEmpty ? fallback : values
        return items.enumerated().map { index, value in "\(index + 1). \(value)" }.joined(separator: "\n")
    }

    private static func inlineList(_ values: [String], fallback: String) -> String {
        values.isEmpty ? fallback : values.joined(separator: "; ")
    }

    private static func pricingTests(for context: StarterContentContext) -> [String] {
        let base = "Anchor the offer on \(context.launchAssets.first ?? context.offer)"
        switch context.category {
        case CompanyTemplate.Category.digitalProducts.rawValue:
            return [
                "\(base) with a low, mid, and bundle price test.",
                "Compare against channel-specific marketplace listings on \(context.channel).",
                "Require saved carts, checkout attempts, or paid preorders before expanding the bundle.",
            ]
        case CompanyTemplate.Category.newsletter.rawValue:
            return [
                "\(base) with sponsor, paid subscriber, and research brief price points.",
                "Measure qualified subscriber intent before selling inventory.",
                "Do not promise audience size until analytics prove it.",
            ]
        case CompanyTemplate.Category.microSaaS.rawValue:
            return [
                "\(base) with trial-to-paid and setup-fee variants.",
                "Test whether \(context.icp) will pay before custom engineering.",
                "Keep cancellation simple until support load is known.",
            ]
        case CompanyTemplate.Category.leadGeneration.rawValue, CompanyTemplate.Category.realEstate.rawValue:
            return [
                "\(base) with pay-per-lead and monthly retainer variants.",
                "Confirm lead quality criteria before charging.",
                "Track refunds for unqualified or duplicate leads.",
            ]
        case CompanyTemplate.Category.automationService.rawValue, CompanyTemplate.Category.productizedService.rawValue:
            return [
                "\(base) with setup, monthly maintenance, and one-off audit prices.",
                "Charge only after scope and access requirements are approved.",
                "Separate human delivery from automation claims.",
            ]
        case CompanyTemplate.Category.affiliate.rawValue:
            return [
                "\(base) with affiliate conversion and direct sponsorship tests.",
                "Separate tracked clicks from paid conversions.",
                "Disclose commercial relationships before publishing.",
            ]
        default:
            return [
                "\(base) with one entry price and one premium price.",
                "Collect willingness-to-pay evidence before live launch.",
                "Record failed objections in the CRM notes column.",
            ]
        }
    }

    private static func analyticsMetrics(for context: StarterContentContext) -> [String] {
        switch context.category {
        case CompanyTemplate.Category.digitalProducts.rawValue:
            return [
                "search impressions", "listing clicks", "favorites or saves", "checkout attempts", "paid downloads",
            ]
        case CompanyTemplate.Category.newsletter.rawValue:
            return ["landing-page visits", "email signups", "reply rate", "sponsor interest", "paid subscriptions"]
        case CompanyTemplate.Category.microSaaS.rawValue:
            return ["activation visits", "demo requests", "trial starts", "setup completions", "paid conversions"]
        case CompanyTemplate.Category.leadGeneration.rawValue, CompanyTemplate.Category.realEstate.rawValue:
            return [
                "qualified leads sourced", "deliverable lead rate", "buyer reply rate", "accepted leads", "refund rate",
            ]
        case CompanyTemplate.Category.creatorMedia.rawValue:
            return ["views", "watch or save rate", "profile clicks", "email captures", "affiliate or product revenue"]
        default:
            return ["qualified visits", "signups", "reply rate", "CAC estimate", "paid conversions"]
        }
    }

    private static func onboardingSteps(for context: StarterContentContext) -> [String] {
        let assets =
            context.launchAssets.isEmpty
            ? ["Confirm buyer goal", "Deliver starter asset", "Collect outcome feedback"] : context.launchAssets
        return [
            "Confirm the buyer is in \(context.icp).",
            "Set expectations for \(context.offer).",
        ] + assets.map { "Deliver or configure: \($0)." } + [
            "Ask for proof of first value and record it in analytics-plan.md.",
            "Escalate before refunds, external sends, live charges, or platform-sensitive actions.",
        ]
    }

    private static func title(for kind: CompanyFactoryAsset.Kind) -> String {
        switch kind {
        case .landingPage: return "Landing page"
        case .pricingPage: return "Pricing page"
        case .paymentLink: return "Sandbox payment link"
        case .crmTable: return "CRM table"
        case .suppressionList: return "Global suppression list"
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
        let context = contentContext(for: manifest)
        return """
        {
          "companyID": "\(manifest.companyID)",
          "offer": "\(context.offer)",
          "templateCategory": "\(context.category)",
          "primaryChannel": "\(context.channel)",
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
