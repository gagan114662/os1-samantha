import Foundation
import Testing
@testable import OS1

struct OS1EvalHarnessTests {
    @Test
    func blockingNonLiveSuiteWritesStructuredReport() throws {
        let report = CompanyEvaluationHarness.runNonLive(now: Date(timeIntervalSince1970: 1_800_000_000))
        try writeReportArtifacts(report)

        let scenarioIDs = Set(report.results.map(\.id))
        for required in [
            "heartbeat-1-dynamism",
            "approval-gate-public-publish",
            "validation-evidence-threshold",
            "drift-no-progress-auto-pause",
            "restart-recovery-heartbeat-lease",
        ] {
            #expect(scenarioIDs.contains(required), "missing eval scenario \(required)")
        }
        #expect(report.suite == "os1-agent-non-live-blocking")
        #expect(!report.live)
        #expect(report.blockingPassed)
        #expect(report.passed)
    }

    private func writeReportArtifacts(_ report: CompanyEvaluationReport) throws {
        let environment = ProcessInfo.processInfo.environment
        if let jsonPath = environment["OS1_EVAL_JSON_REPORT"], !jsonPath.isEmpty {
            let jsonURL = URL(fileURLWithPath: jsonPath)
            try FileManager.default.createDirectory(
                at: jsonURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(report).write(to: jsonURL, options: [.atomic])
        }
        if let markdownPath = environment["OS1_EVAL_MARKDOWN_REPORT"], !markdownPath.isEmpty {
            let markdownURL = URL(fileURLWithPath: markdownPath)
            try FileManager.default.createDirectory(
                at: markdownURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try report.markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
        }
    }
}
