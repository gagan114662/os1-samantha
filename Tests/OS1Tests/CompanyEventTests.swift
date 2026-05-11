import Foundation
import Testing
@testable import OS1

struct CompanyEventTests {
    @Test
    func eventRedactsKnownSecretShapesFromSummaryAndMetadata() {
        let event = CompanyEvent(
            companyID: "abc12345",
            kind: .userInstruction,
            summary: "Use ghp_abcdefghijklmnopqrstuvwxyz123456 for GitHub",
            outputSummary: "token sk-abcdefghijklmnopqrstuvwxyz123456 worked",
            metadata: [
                "githubToken": "ghp_abcdefghijklmnopqrstuvwxyz123456",
                "publicURL": "https://example.com/launch"
            ]
        )

        #expect(event.summary == "Use [redacted] for GitHub")
        #expect(event.outputSummary == "token [redacted] worked")
        #expect(event.metadata["githubToken"] == "[redacted]")
        #expect(event.metadata["publicURL"] == "https://example.com/launch")
    }

    @Test
    func eventRoundTripsThroughJSONLineEncoding() throws {
        let original = CompanyEvent(
            id: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!,
            occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
            companyID: "company-1",
            actor: "os1",
            kind: .heartbeatQueued,
            summary: "Queued by concurrency limit",
            runID: "run-1",
            tool: "codex exec",
            inputHash: CompanyEvent.inputHash(for: "prompt"),
            outputSummary: "queued",
            costUSD: 0.01,
            latencyMS: 42,
            riskTier: "sandbox",
            approvalState: "file-gated",
            metadata: ["maxConcurrentHeartbeats": "3"]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let line = String(data: try encoder.encode(original), encoding: .utf8)! + "\n"

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(CompanyEvent.self, from: Data(line.utf8))

        #expect(decoded == original)
    }

    @Test
    func inputHashIsStableSHA256() {
        #expect(CompanyEvent.inputHash(for: "prompt") == "cf07194ee232eb531e15f690000d19846dea69cf05504782658afcfacb9228a2")
    }

    @Test
    func metricsSummarizePersistedEvents() {
        let events = [
            CompanyEvent(kind: .heartbeatStarted, summary: "started", runID: "run-1"),
            CompanyEvent(
                kind: .heartbeatFinished,
                summary: "finished",
                runID: "run-1",
                costUSD: 0.10,
                latencyMS: 1_500,
                metadata: ["exitCode": "0", "status": "idle"]
            ),
            CompanyEvent(
                kind: .heartbeatFinished,
                summary: "failed",
                runID: "run-2",
                costUSD: 0.20,
                latencyMS: 500,
                metadata: ["exitCode": "1", "status": "failed"]
            ),
            CompanyEvent(kind: .userInstruction, summary: "manual intervention")
        ]

        let metrics = CompanyMetricsSnapshot.summarize(events: events, revenueUSD: 10, costUSD: 3)

        #expect(metrics.eventCount == 4)
        #expect(metrics.heartbeatStartedCount == 1)
        #expect(metrics.heartbeatSucceededCount == 1)
        #expect(metrics.heartbeatFailedCount == 1)
        #expect(metrics.successRate == 0.5)
        #expect(metrics.errorRate == 0.5)
        #expect(metrics.averageLatencyMS == 1_000)
        #expect(metrics.manualInterventionCount == 1)
        #expect(abs(metrics.totalObservedCostUSD - 0.30) < 0.0001)
        #expect(abs(metrics.profitUSD - 6.70) < 0.0001)
    }
}
