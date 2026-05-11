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
        #expect(kinds.contains(.analyticsPlan))
        #expect(kinds.contains(.deploymentChecklist))
        #expect(kinds.contains(.brandGuide))
        #expect(kinds.contains(.onboardingFlow))
        #expect(kinds.contains(.refundPolicy))
        #expect(kinds.contains(.salesScript))
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

        #expect(payment?.sandboxTestable == true)
        #expect(analytics?.sandboxTestable == true)
        #expect(payment?.requiresApprovalBeforePublish == true)
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
    }
}
