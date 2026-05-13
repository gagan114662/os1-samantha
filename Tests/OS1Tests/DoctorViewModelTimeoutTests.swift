import Foundation
import Testing
@testable import OS1

@MainActor
struct DoctorViewModelTimeoutTests {
    @Test
    func hungCheckTimesOutAndRefreshCompletesWithinTimeoutWindow() async {
        let timeoutSeconds: TimeInterval = 0.2
        let viewModel = makeViewModel(checkDefinitions: [
            DoctorViewModel.CheckDefinition(
                id: "hung-check",
                title: "Hung check",
                timeoutSeconds: timeoutSeconds
            ) {
                try await Task.sleep(nanoseconds: 10_000_000_000)
                return DoctorViewModel.Check(
                    id: "hung-check",
                    title: "Hung check",
                    severity: .ok,
                    summary: "Unexpected completion",
                    detail: nil,
                    actions: []
                )
            }
        ])

        let startedAt = Date()
        await viewModel.refresh()
        let elapsed = Date().timeIntervalSince(startedAt)

        #expect(elapsed >= timeoutSeconds)
        #expect(elapsed < timeoutSeconds + 5)
        #expect(viewModel.isRefreshing == false)
        #expect(viewModel.hasUnresolvedChecks == false)
        #expect(viewModel.checks.first?.state == .timeout)
        #expect(viewModel.checks.first?.actions == [.retryCheck("hung-check")])
        #expect(viewModel.checksSummary.contains("Checks complete"))
    }

    private func makeViewModel(checkDefinitions: [DoctorViewModel.CheckDefinition]) -> DoctorViewModel {
        let transport = StubRemoteTransport()
        let orgo = OrgoTransport(apiKeyProvider: { nil })
        return DoctorViewModel(
            credentialStore: TelegramCredentialStore(service: "org.telegram.bot-token.tests"),
            telegramInstaller: TelegramVMInstaller(orgoTransport: orgo, multiplexed: transport),
            hermesUpdater: HermesUpdater(orgoTransport: orgo, multiplexed: transport),
            checkDefinitionsForTesting: checkDefinitions
        )
    }
}

private final class StubRemoteTransport: RemoteTransport, @unchecked Sendable {
    func execute(
        on connection: ConnectionProfile,
        remoteCommand: String,
        standardInput: Data?,
        allocateTTY: Bool
    ) async throws -> RemoteCommandResult {
        RemoteCommandResult(stdout: "", stderr: "", exitCode: 0)
    }

    func executeJSON<Response: Decodable>(
        on connection: ConnectionProfile,
        pythonScript: String,
        responseType: Response.Type
    ) async throws -> Response {
        throw RemoteTransportError.invalidResponse("Stub transport has no JSON fixture.")
    }
}
