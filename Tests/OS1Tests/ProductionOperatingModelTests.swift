import Foundation
import Testing
@testable import OS1

struct ProductionOperatingModelTests {
    @Test
    func productionOperatingModelContainsRequiredGateSections() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/production-operating-model.md")
        let document = try String(contentsOf: url, encoding: .utf8)

        let missing = DoctorViewModel.productionOperatingModelMissingSections(in: document)

        #expect(missing.isEmpty)
    }

    @Test
    func productionOperatingModelCheckReportsMissingSections() {
        let missing = DoctorViewModel.productionOperatingModelMissingSections(in: """
        # OS1 + Samantha Production Operating Model
        Version: 1
        ## Autonomy Levels
        """)

        #expect(missing.contains("## Risk Tiers"))
        #expect(missing.contains("## Tool / Action Approval Matrix"))
        #expect(missing.contains("## Sandbox to Live Revenue Checklist"))
    }

    @Test
    func doctorFlagsSharedProductionCredentialScopes() {
        var localDev = CodexSession(
            id: "local",
            title: "local dev company",
            task: "test",
            worktreePath: "/tmp/local",
            branch: "company/local",
            status: .idle,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        localDev.sandboxMode = .localDevelopment

        var overbroad = CodexSession(
            id: "broad",
            title: "broad company",
            task: "test",
            worktreePath: "/tmp/broad",
            branch: "company/broad",
            status: .idle,
            startedAt: Date(timeIntervalSince1970: 1)
        )
        overbroad.credentialAllowlist = ["RESEND_API_KEY", "STRIPE_API_KEY"]

        let problems = DoctorViewModel.sharedProductionCredentialProblems(
            credentialNames: ["RESEND_API_KEY", "STRIPE_API_KEY"],
            sessions: [localDev, overbroad]
        )

        #expect(problems.count == 2)
        #expect(problems.contains { $0.contains("localDevelopment") })
        #expect(problems.contains { $0.contains("granted every shared credential") })
    }
}
