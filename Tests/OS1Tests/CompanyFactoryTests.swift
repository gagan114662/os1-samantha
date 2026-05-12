import Foundation
import Testing

@testable import OS1

struct CompanyFactoryTests {
    @Test
    func factoryManifestCreatesAllRequiredAssets() {
        let template = CompanyTemplateCatalog.all.first { $0.category == .microSaaS }
        let manifest = CompanyFactory.manifest(
            companyID: "company-1",
            template: template,
            worktreePath: "/tmp/company-1"
        )
        let kinds = Set(manifest.assets.map(\.kind))

        #expect(kinds.contains(.landingPage))
        #expect(kinds.contains(.pricingPage))
        #expect(kinds.contains(.paymentLink))
        #expect(kinds.contains(.crmTable))
        #expect(kinds.contains(.suppressionList))
        #expect(kinds.contains(.supportInbox))
        #expect(kinds.contains(.supportEscalationPolicy))
        #expect(kinds.contains(.supportTickets))
        #expect(kinds.contains(.analyticsPlan))
        #expect(kinds.contains(.deploymentChecklist))
        #expect(kinds.contains(.brandGuide))
        #expect(kinds.contains(.onboardingFlow))
        #expect(kinds.contains(.refundPolicy))
        #expect(kinds.contains(.termsOfService))
        #expect(kinds.contains(.privacyPolicy))
        #expect(kinds.contains(.acceptableUsePolicy))
        #expect(kinds.contains(.legalMetadata))
        #expect(kinds.contains(.taxChecklist))
        #expect(kinds.contains(.salesScript))
        #expect(kinds.contains(.compliancePolicy))
        #expect(kinds.contains(.browserPolicy))
    }

    @Test
    func paymentAndAnalyticsAssetsAreSandboxTestable() {
        let manifest = CompanyFactory.manifest(
            companyID: "company-1",
            template: CompanyTemplateCatalog.all[0],
            worktreePath: "/tmp/company-1"
        )
        let payment = manifest.assets.first { $0.kind == .paymentLink }
        let analytics = manifest.assets.first { $0.kind == .analyticsPlan }
        let legalMetadata = manifest.assets.first { $0.kind == .legalMetadata }
        let escalation = manifest.assets.first { $0.kind == .supportEscalationPolicy }

        #expect(payment?.sandboxTestable == true)
        #expect(analytics?.sandboxTestable == true)
        #expect(payment?.requiresApprovalBeforePublish == true)
        #expect(legalMetadata?.requiresApprovalBeforePublish == true)
        #expect(escalation?.requiresApprovalBeforePublish == true)
    }

    @Test
    func launchCannotProceedUntilAllGatesPass() {
        var manifest = CompanyFactory.manifest(
            companyID: "company-1",
            template: CompanyTemplateCatalog.all[0],
            worktreePath: "/tmp/company-1"
        )

        #expect(!manifest.canLaunch)
        manifest.gates = manifest.gates.map {
            CompanyFactoryGate(id: $0.id, kind: $0.kind, title: $0.title, passed: true, evidence: "reviewed")
        }
        #expect(manifest.canLaunch)
    }

    @Test
    func checklistLinksEveryAssetAndGate() {
        let manifest = CompanyFactory.manifest(
            companyID: "company-1",
            template: CompanyTemplateCatalog.all[0],
            worktreePath: "/tmp/company-1"
        )
        let checklist = CompanyFactory.checklistMarkdown(manifest)

        for asset in manifest.assets {
            #expect(checklist.contains(asset.path))
        }
        for gate in manifest.gates {
            #expect(checklist.contains(gate.title))
        }
        #expect(manifest.gates.contains { $0.kind == .legal })
        #expect(manifest.gates.contains { $0.kind == .support })
    }

    @Test
    func customHireMissionBecomesFactoryOfferAndLandingPage() throws {
        let mission = "Research the top 10 vibe-coding tools as of May 2026 and sell a comparison brief."
        let manifest = CompanyFactory.manifest(
            companyID: "custom-1",
            template: nil,
            worktreePath: "/tmp/custom-1",
            offer: mission
        )
        let landingPage = try #require(manifest.assets.first { $0.kind == .landingPage })
        let landingContent = CompanyFactory.starterContent(for: landingPage, manifest: manifest)

        #expect(manifest.offer == mission)
        #expect(landingContent.contains("vibe-coding tools"))
        #expect(!landingContent.contains("Validate and sell the smallest paid offer."))
    }

    @Test
    func templateStarterContentDiffersAcrossTemplateFamilies() throws {
        let digitalTemplate = try #require(CompanyTemplateCatalog.template(id: "etsy-wedding-canva-invitations"))
        let newsletterTemplate = try #require(CompanyTemplateCatalog.all.first { $0.category == .newsletter })
        let digitalManifest = CompanyFactory.manifest(
            companyID: "digital-1",
            template: digitalTemplate,
            worktreePath: "/tmp/digital-1"
        )
        let newsletterManifest = CompanyFactory.manifest(
            companyID: "newsletter-1",
            template: newsletterTemplate,
            worktreePath: "/tmp/newsletter-1"
        )
        let kinds: [CompanyFactoryAsset.Kind] = [
            .pricingPage,
            .paymentLink,
            .supportInbox,
            .analyticsPlan,
            .brandGuide,
            .onboardingFlow,
            .refundPolicy,
            .taxChecklist,
            .salesScript,
        ]

        let differingFiles = try kinds.filter { kind in
            let digitalAsset = try #require(digitalManifest.assets.first { $0.kind == kind })
            let newsletterAsset = try #require(newsletterManifest.assets.first { $0.kind == kind })
            return CompanyFactory.starterContent(for: digitalAsset, manifest: digitalManifest)
                != CompanyFactory.starterContent(for: newsletterAsset, manifest: newsletterManifest)
        }

        #expect(differingFiles.count >= 5)
    }

    @Test
    func complianceAndBrowserPolicyStartersDefineAutomationControls() throws {
        let manifest = CompanyFactory.manifest(
            companyID: "company-1",
            template: nil,
            worktreePath: "/tmp/company-1"
        )
        let compliancePolicy = try #require(manifest.assets.first { $0.kind == .compliancePolicy })
        let complianceStarter = CompanyFactory.starterContent(for: compliancePolicy, manifest: manifest)

        #expect(complianceStarter.contains("\"legalBasis\""))
        #expect(complianceStarter.contains("\"dataRetentionPolicy\""))
        #expect(complianceStarter.contains("\"allowedDomains\""))
        #expect(complianceStarter.contains("\"allowedActions\""))

        let browserPolicy = try #require(manifest.assets.first { $0.kind == .browserPolicy })
        let browserStarter = CompanyFactory.starterContent(for: browserPolicy, manifest: manifest)

        #expect(browserStarter.contains("\"companyID\": \"company-1\""))
        #expect(browserStarter.contains("\"approvedDomains\""))
        #expect(browserStarter.contains("\"allowedActions\""))
        #expect(browserStarter.contains("\"preferredIntegrations\""))
    }
}
