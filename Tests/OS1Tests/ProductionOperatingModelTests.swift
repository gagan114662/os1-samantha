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

    @Test
    func doctorReportsCodexHeartbeatSandboxRuntimeFromLaunchPlan() {
        let sandboxed = CodexSession(
            id: "sandboxed",
            title: "sandboxed company",
            task: "test",
            worktreePath: "/tmp/sandboxed",
            branch: "company/sandboxed",
            status: .idle,
            startedAt: Date(timeIntervalSince1970: 1),
            sandboxMode: .sandbox
        )
        let sandboxedPlan = CodexSessionManager.heartbeatLaunchPlan(
            session: sandboxed,
            sandboxProfileURL: URL(fileURLWithPath: "/tmp/sandboxed.sb"),
            promptFile: "/tmp/sandboxed.prompt"
        )
        let onRuntime = DoctorViewModel.codexHeartbeatSandboxRuntime(
            sandboxExecIsExecutable: true,
            launchPlan: sandboxedPlan
        )

        #expect(onRuntime.isOn)
        #expect(onRuntime.title == "Codex heartbeat sandbox: ON")
        #expect(onRuntime.detail.contains("/usr/bin/sandbox-exec"))

        var localDev = sandboxed
        localDev.sandboxMode = .localDevelopment
        let localDevPlan = CodexSessionManager.heartbeatLaunchPlan(
            session: localDev,
            sandboxProfileURL: URL(fileURLWithPath: "/tmp/localdev.sb"),
            promptFile: "/tmp/localdev.prompt"
        )
        let offRuntime = DoctorViewModel.codexHeartbeatSandboxRuntime(
            sandboxExecIsExecutable: true,
            launchPlan: localDevPlan
        )

        #expect(!offRuntime.isOn)
        #expect(offRuntime.title == "Codex heartbeat sandbox: OFF")
        #expect(offRuntime.detail.contains("Do not run revenue companies"))
    }

    @Test
    func doctorParsesEvaluationReportSummary() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-eval-report-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let reportURL = root.appendingPathComponent("non-live-report.json")
        try """
        {
          "suite": "company-agent-non-live",
          "passed": true,
          "passedCount": 8,
          "totalCount": 8,
          "averageScore": 100.0
        }
        """.write(to: reportURL, atomically: true, encoding: .utf8)

        let summary = try #require(DoctorViewModel.evaluationReportSummary(at: reportURL))

        #expect(summary.suite == "company-agent-non-live")
        #expect(summary.passed)
        #expect(summary.passedCount == 8)
        #expect(summary.totalCount == 8)
        #expect(summary.averageScore == 100)
    }
}
