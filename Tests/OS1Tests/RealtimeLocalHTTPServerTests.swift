import Foundation
import Testing
@testable import OS1

struct RealtimeLocalHTTPServerTests {
    @Test
    func localHTTPServerServesStripeStatusWithoutElevenLabsCredentials() async throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-local-http-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        let server = RealtimeVoiceSessionServer(
            elevenLabsAPIKeyProvider: { nil },
            agentIDProvider: { nil },
            runtimeDirectoryProvider: { runtimeDirectory }
        )
        server.start()
        defer { server.stop() }

        let endpoint = try await Self.waitForEndpoint(server)
        let statusURL = endpoint.appendingPathComponent("api/stripe/status")
        let (data, response) = try await URLSession.shared.data(from: statusURL)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 200)

        let json = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(json["ok"] as? Bool == true)
        #expect(json["provider"] as? String == "stripe")
        #expect(json["endpoint"] as? String == "/webhooks/stripe")

        let port = try #require(endpoint.port)
        let localPort = try String(
            contentsOf: runtimeDirectory.appendingPathComponent(RealtimeVoiceSessionServer.localServerPortFileName),
            encoding: .utf8
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(localPort == String(port))
        #expect(FileManager.default.fileExists(
            atPath: runtimeDirectory.appendingPathComponent(RealtimeVoiceSessionServer.legacyVoicePortFileName).path
        ))
    }

    @Test
    func voiceSignedURLRouteFailsClearlyWithoutElevenLabsCredentials() async throws {
        let runtimeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-local-http-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }

        let server = RealtimeVoiceSessionServer(
            elevenLabsAPIKeyProvider: { "" },
            agentIDProvider: { "" },
            runtimeDirectoryProvider: { runtimeDirectory }
        )
        server.start()
        defer { server.stop() }

        let endpoint = try await Self.waitForEndpoint(server)
        let signedURL = endpoint.appendingPathComponent("signed-url")
        let (data, response) = try await URLSession.shared.data(from: signedURL)
        let httpResponse = try #require(response as? HTTPURLResponse)
        #expect(httpResponse.statusCode == 500)
        #expect(String(data: data, encoding: .utf8)?.contains("ElevenLabs credentials not configured") == true)
    }

    private static func waitForEndpoint(
        _ server: RealtimeVoiceSessionServer,
        timeout: TimeInterval = 4
    ) async throws -> URL {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let endpointURL = server.endpointURL {
                return endpointURL
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw WaitError.timedOut
    }

    private enum WaitError: Error {
        case timedOut
    }
}
