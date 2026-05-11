import Foundation

struct CompanyFactoryAsset: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case landingPage
        case pricingPage
        case paymentLink
        case crmTable
        case suppressionList
        case supportInbox
        case analyticsPlan
        case deploymentChecklist
        case brandGuide
        case onboardingFlow
        case refundPolicy
        case salesScript
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
        case security
        case budget
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
            (.suppressionList, "suppression-list.csv", true, false),
            (.supportInbox, "support-inbox.md", true, false),
            (.analyticsPlan, "analytics-plan.md", true, false),
            (.deploymentChecklist, "launch-checklist.md", true, false),
            (.brandGuide, "brand-guide.md", true, false),
            (.onboardingFlow, "onboarding-flow.md", true, false),
            (.refundPolicy, "refund-policy.md", true, true),
            (.salesScript, "first-sales-script.md", true, true)
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
                .init(id: "security", kind: .security, title: "Security and credential scope reviewed", passed: false, evidence: ""),
                .init(id: "budget", kind: .budget, title: "Budget and spend approval passed", passed: false, evidence: "")
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

        Launch is blocked until compliance, security, and budget gates pass.
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
            return "name,email,source,status,consent,account_id,owner,notes\n"
        case .suppressionList:
            return "email,reason,source_company_id,recorded_at\n"
        case .supportInbox:
            return "# Support inbox\n\nTrack customer requests, refunds, and escalation notes here.\n"
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
        case .salesScript:
            return "# First sales script\n\nDraft only. Do not send without approval.\n"
        }
    }

    private static func title(for kind: CompanyFactoryAsset.Kind) -> String {
        switch kind {
        case .landingPage: return "Landing page"
        case .pricingPage: return "Pricing page"
        case .paymentLink: return "Sandbox payment link"
        case .crmTable: return "CRM table"
        case .suppressionList: return "Global suppression list"
        case .supportInbox: return "Support inbox"
        case .analyticsPlan: return "Analytics plan"
        case .deploymentChecklist: return "Deployment checklist"
        case .brandGuide: return "Brand guide"
        case .onboardingFlow: return "Onboarding flow"
        case .refundPolicy: return "Cancellation/refund policy"
        case .salesScript: return "First sales script"
        }
    }
}
