import Foundation
import Testing
@testable import OS1

struct DoctorCheckTimeoutTests {
    @Test
    func hungCheckResolvesToTimeoutWithRetry() async {
        let timeoutSeconds: TimeInterval = 0.05
        let started = Date()
        let definition = DoctorViewModel.CheckDefinition(
            id: "hung",
            title: "Hung check",
            timeoutSeconds: timeoutSeconds
        ) {
            try await Task.sleep(nanoseconds: 5_000_000_000)
            return DoctorViewModel.Check(
                id: "hung",
                title: "Hung check",
                severity: .ok,
                summary: "Should not complete first.",
                detail: nil,
                actions: []
            )
        }

        let resolved = await DoctorViewModel.executeCheckDefinition(definition)

        #expect(resolved.check.state == .timeout)
        #expect(resolved.check.actions == [.retryCheck("hung")])
        #expect(resolved.errorMessage?.contains("timed out") == true)
        #expect(Date().timeIntervalSince(started) < timeoutSeconds + 5)
    }

    @Test
    func thrownCheckDisplaysErrorAndOffersLogsAndRetry() async {
        let definition = DoctorViewModel.CheckDefinition(
            id: "boom",
            title: "Exploding check",
            timeoutSeconds: 1,
            logPath: "/tmp/doctor.log"
        ) {
            throw DoctorTestError.exploded
        }

        let resolved = await DoctorViewModel.executeCheckDefinition(definition)

        #expect(resolved.check.state == .fail)
        #expect(resolved.check.detail?.contains("synthetic failure") == true)
        #expect(resolved.check.actions == [.openLogs("/tmp/doctor.log"), .retryCheck("boom")])
    }

    @Test
    func doctorEventMetadataCapturesNameStartEndOutcomeLatencyAndError() {
        let startedAt = Date(timeIntervalSince1970: 1_800_000_000)
        let endedAt = startedAt.addingTimeInterval(1.25)

        let metadata = CodexSessionManager.doctorCheckMetadata(
            checkName: "Host reachability",
            checkID: "host",
            startedAt: startedAt,
            endedAt: endedAt,
            outcome: "timeout",
            latencyMS: 1_250,
            error: "No response."
        )

        #expect(metadata["checkName"] == "Host reachability")
        #expect(metadata["checkID"] == "host")
        #expect(metadata["outcome"] == "timeout")
        #expect(metadata["latencyMS"] == "1250")
        #expect(metadata["error"] == "No response.")
        #expect(metadata["startedAt"] != nil)
        #expect(metadata["endedAt"] != nil)
    }

    @Test
    func checkStatesAreExhaustiveAndTerminalStatesResolveRows() {
        #expect(DoctorViewModel.CheckState.allCases.map(\.rawValue) == [
            "pending",
            "running",
            "pass",
            "warn",
            "fail",
            "timeout",
            "skipped"
        ])
        #expect(!DoctorViewModel.CheckState.pending.isTerminal)
        #expect(!DoctorViewModel.CheckState.running.isTerminal)
        #expect(DoctorViewModel.CheckState.pass.isTerminal)
        #expect(DoctorViewModel.CheckState.warn.isTerminal)
        #expect(DoctorViewModel.CheckState.fail.isTerminal)
        #expect(DoctorViewModel.CheckState.timeout.isTerminal)
        #expect(DoctorViewModel.CheckState.skipped.isTerminal)
    }
}

private enum DoctorTestError: LocalizedError {
    case exploded

    var errorDescription: String? {
        "synthetic failure"
    }
}
