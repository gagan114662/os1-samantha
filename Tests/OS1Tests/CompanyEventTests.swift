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
            metadata: [
                "githubToken": "ghp_abcdefghijklmnopqrstuvwxyz123456",
                "publicURL": "https://example.com/launch"
            ]
        )

        #expect(event.summary == "Use [redacted] for GitHub")
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
}
