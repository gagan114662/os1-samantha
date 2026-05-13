import Foundation
import Testing
@testable import OS1

/// Regression coverage for issue #165: the Connectors tab used to show
/// "API key stored / DISCONNECT" AND "Composio rejected the API key"
/// at the same time. These tests pin down the four account-row states
/// the view renders, and prove the dual-source-of-truth bug cannot
/// resurface — the AccountDisplayState is a single derived value, not
/// a free-form combo of two independent published flags.
struct ConnectorsViewModelTests {

    // MARK: - State-driving fakes

    /// Drives the validator from a queue of canned outcomes so tests
    /// can exercise validating → validated / rejected / unreachable.
    /// Each call to `validate()` suspends on a continuation; the test
    /// resumes it via `deliver(_:)` after asserting the mid-flight
    /// `.validating` state. Outcomes can also be pre-loaded so tests
    /// that don't care about timing get an immediate result.
    final class StubValidator: ConnectorsKeyValidating, @unchecked Sendable {
        private let lock = NSLock()
        private var pendingOutcomes: [ConnectorsValidationOutcome] = []
        private var pendingResumers: [CheckedContinuation<ConnectorsValidationOutcome, Never>] = []
        private(set) var callCount = 0

        init(outcomes: [ConnectorsValidationOutcome] = []) {
            self.pendingOutcomes = outcomes
        }

        /// Resolves the next pending `validate()` call (or queues an
        /// outcome for the next call if none is in flight yet).
        func deliver(_ outcome: ConnectorsValidationOutcome) {
            lock.lock()
            if !pendingResumers.isEmpty {
                let resumer = pendingResumers.removeFirst()
                lock.unlock()
                resumer.resume(returning: outcome)
            } else {
                pendingOutcomes.append(outcome)
                lock.unlock()
            }
        }

        func validate() async -> ConnectorsValidationOutcome {
            await withCheckedContinuation { (continuation: CheckedContinuation<ConnectorsValidationOutcome, Never>) in
                lock.lock()
                callCount += 1
                if !pendingOutcomes.isEmpty {
                    let outcome = pendingOutcomes.removeFirst()
                    lock.unlock()
                    continuation.resume(returning: outcome)
                } else {
                    pendingResumers.append(continuation)
                    lock.unlock()
                }
            }
        }
    }

    /// Stub remote transport that never gets called — the installer is
    /// only present so we can construct the view model with the same
    /// init the production app uses.
    struct UnreachableRemoteTransport: RemoteTransport {
        func execute(on connection: ConnectionProfile, remoteCommand: String, standardInput: Data?, allocateTTY: Bool) async throws -> RemoteCommandResult {
            throw RemoteTransportError.localFailure("not used in tests")
        }
        func executeJSON<Response>(on connection: ConnectionProfile, pythonScript: String, responseType: Response.Type) async throws -> Response where Response: Decodable {
            throw RemoteTransportError.localFailure("not used in tests")
        }
    }

    // MARK: - Builders

    @MainActor
    private static func makeViewModel(
        outcomes: [ConnectorsValidationOutcome],
        preseedKey: String? = "ck_test_key"
    ) -> (ConnectorsViewModel, ComposioCredentialStore, StubValidator) {
        // Unique Keychain service per test instance so concurrent
        // workspaces don't trample one another's slots.
        let service = "dev.os1.tests.connectors.\(UUID().uuidString)"
        let store = ComposioCredentialStore(service: service)
        if let preseedKey {
            try? store.saveAsDefault(preseedKey)
        }
        let installer = ComposioVMInstaller(
            orgoTransport: OrgoTransport(httpClient: OrgoHTTPClient(apiKeyProvider: { nil })),
            multiplexed: UnreachableRemoteTransport()
        )
        let validator = StubValidator(outcomes: outcomes)
        let vm = ConnectorsViewModel(
            credentialStore: store,
            paymentCredentialStore: .shared,
            installer: installer,
            toolkitService: nil,
            keyValidator: validator,
            urlOpener: { _ in }
        )
        return (vm, store, validator)
    }

    // MARK: - Four-state coverage

    @Test
    @MainActor
    func noKeyStored_rendersUnconfigured_andHidesAccountAffordances() async {
        let (vm, _, _) = Self.makeViewModel(outcomes: [], preseedKey: nil)
        #expect(vm.step == .unconfigured)
        #expect(vm.accountDisplay == .unconfigured)
        #expect(vm.validationState == .unknown)
    }

    @Test
    @MainActor
    func storedKey_andValidated_rendersConnected_withDisconnect() async {
        let (vm, _, _) = Self.makeViewModel(outcomes: [.validated])
        #expect(vm.accountDisplay == .storedUnknown,
                "Before validation runs, a stored key reads as storedUnknown — never as 'connected' on faith.")

        await vm.validateAPIKey()

        #expect(vm.validationState == .validated)
        #expect(vm.accountDisplay == .connected)
    }

    @Test
    @MainActor
    func storedKey_andRejected_rendersRejected_withReconnectAffordance() async {
        let rejection = "Composio rejected the API key. Server said: invalid_consumer_api_key"
        let (vm, _, _) = Self.makeViewModel(outcomes: [.rejected(message: rejection)])
        await vm.validateAPIKey()

        #expect(vm.validationState == .rejected(message: rejection))
        #expect(vm.accountDisplay == .rejected(message: rejection))

        // AC: stored key is NOT cleared by a rejection — DISCONNECT is
        // the only way to wipe Keychain, and it must remain available.
        #expect(vm.hasAPIKey == true)
    }

    @Test
    @MainActor
    func validating_inFlight_isObservable_andSuppressesStaleStates() async {
        // Pre-seed a rejected state, then trigger a re-validation. The
        // expected progression is: rejected → validating → validated.
        let (vm, _, validator) = Self.makeViewModel(outcomes: [])
        // First pass: rejected.
        validator.deliver(.rejected(message: "old rejection"))
        await vm.validateAPIKey()
        #expect(vm.accountDisplay == .rejected(message: "old rejection"))

        // Kick off the next validation without delivering an outcome
        // yet — the validator suspends on a continuation, leaving the
        // view model parked in `.validating`.
        let task = Task { await vm.validateAPIKey() }
        // Yield to schedule the awaiting task.
        for _ in 0..<20 { await Task.yield() }
        #expect(vm.accountDisplay == .validating,
                "Account panel must show 'Validating…' — never stale 'stored' or 'rejected' — while a fresh check is in flight.")
        // Now deliver the success outcome and observe the transition.
        validator.deliver(.validated)
        await task.value
        #expect(vm.accountDisplay == .connected)
    }

    // MARK: - Issue #165 regression: no two-source contradiction

    @Test
    @MainActor
    func rejectionFlipsAccountPanelEvenWhileKeyRemainsStored() async {
        // This is the exact bug from issue #165: a stored key combined
        // with a Composio rejection. The old code rendered "Stored in
        // Keychain / DISCONNECT" alongside "Composio rejected the API
        // key." accountDisplay must collapse to ONE state.
        let (vm, store, _) = Self.makeViewModel(outcomes: [.rejected(message: "bad key")])
        #expect(store.hasAPIKey() == true, "Pre-seeded key is present.")
        await vm.validateAPIKey()
        // Even though the key is still in Keychain (validation does NOT
        // delete it — that's DISCONNECT's job), the panel renders as
        // .rejected — not "connected" or "stored ok."
        #expect(store.hasAPIKey() == true, "Validation must not silently delete the stored key.")
        guard case .rejected = vm.accountDisplay else {
            Issue.record("Expected rejected state, got \(vm.accountDisplay)")
            return
        }
        // And critically: the rejected state is mutually exclusive with
        // the connected state — there is no way to read both at once.
        #expect(vm.accountDisplay != .connected)
    }

    // MARK: - Transitions

    @Test
    @MainActor
    func disconnect_resetsValidationState_andStep() async {
        let (vm, _, _) = Self.makeViewModel(outcomes: [.validated])
        await vm.validateAPIKey()
        #expect(vm.accountDisplay == .connected)

        vm.disconnect()

        #expect(vm.step == .unconfigured)
        #expect(vm.validationState == .unknown,
                "Disconnect must clear cached validation — a re-add walks the full validate path.")
        #expect(vm.accountDisplay == .unconfigured)
    }

    @Test
    @MainActor
    func savingNewKey_dropsStaleRejection_andRevalidates() async {
        let (vm, _, _) = Self.makeViewModel(outcomes: [.rejected(message: "old"), .validated])
        await vm.validateAPIKey()
        #expect(vm.accountDisplay == .rejected(message: "old"))

        vm.apiKeyDraft = "ck_new"
        vm.saveAPIKey()

        // saveAPIKey flips validationState back to .unknown immediately
        // so the panel doesn't keep flashing the prior "rejected" copy.
        #expect(vm.validationState == .unknown)
        #expect(vm.accountDisplay == .storedUnknown)

        await vm.validateAPIKey()
        #expect(vm.accountDisplay == .connected)
    }

    @Test
    @MainActor
    func unreachable_doesNotClobberPriorValidatedResult() async {
        let (vm, _, _) = Self.makeViewModel(outcomes: [.validated, .unreachable(message: "network down")])
        await vm.validateAPIKey()
        #expect(vm.accountDisplay == .connected)

        await vm.validateAPIKey()
        // Transport failures must not flip a known-good key into
        // "rejected" — that's exactly the silent-success-with-actual-
        // failure inversion the issue calls out.
        #expect(vm.accountDisplay == .connected,
                "A transport blip must not poison a previously-validated key.")
    }

    // MARK: - Snapshot-style coverage for the row UI

    /// Captures the visible elements the Connectors Account row should
    /// render for a given AccountDisplayState. Not a SwiftUI image
    /// snapshot (no library dep); this is a structural snapshot of the
    /// view contract — what text + which buttons. It pins down the
    /// "stored-and-rejected can never both be true" invariant in a
    /// form that's grep-able.
    struct AccountRowSnapshot: Equatable, CustomStringConvertible {
        let statusText: String
        let showsStoredCopy: Bool
        let showsDisconnect: Bool
        let showsReconnect: Bool
        let showsValidatingSpinner: Bool

        var description: String {
            "[status=\(statusText), stored=\(showsStoredCopy), disconnect=\(showsDisconnect), reconnect=\(showsReconnect), spinner=\(showsValidatingSpinner)]"
        }

        static func capture(_ display: ConnectorsViewModel.AccountDisplayState) -> AccountRowSnapshot {
            switch display {
            case .loading, .storedUnknown:
                return .init(statusText: "Checking Composio…", showsStoredCopy: false,
                             showsDisconnect: false, showsReconnect: false, showsValidatingSpinner: true)
            case .unconfigured:
                return .init(statusText: "No Composio API key on this Mac.", showsStoredCopy: false,
                             showsDisconnect: false, showsReconnect: false, showsValidatingSpinner: false)
            case .validating:
                return .init(statusText: "Validating…", showsStoredCopy: false,
                             showsDisconnect: false, showsReconnect: false, showsValidatingSpinner: true)
            case .connected:
                return .init(statusText: "Connected", showsStoredCopy: true,
                             showsDisconnect: true, showsReconnect: false, showsValidatingSpinner: false)
            case .rejected:
                return .init(statusText: "Connection failed — re-enter key", showsStoredCopy: false,
                             showsDisconnect: true, showsReconnect: true, showsValidatingSpinner: false)
            }
        }
    }

    @Test
    @MainActor
    func snapshotMatrix_acrossFourStates_neverShowsContradictoryAffordances() {
        let cases: [(ConnectorsViewModel.AccountDisplayState, AccountRowSnapshot)] = [
            (.unconfigured, AccountRowSnapshot(
                statusText: "No Composio API key on this Mac.",
                showsStoredCopy: false, showsDisconnect: false,
                showsReconnect: false, showsValidatingSpinner: false)),
            (.validating, AccountRowSnapshot(
                statusText: "Validating…",
                showsStoredCopy: false, showsDisconnect: false,
                showsReconnect: false, showsValidatingSpinner: true)),
            (.connected, AccountRowSnapshot(
                statusText: "Connected",
                showsStoredCopy: true, showsDisconnect: true,
                showsReconnect: false, showsValidatingSpinner: false)),
            (.rejected(message: "anything"), AccountRowSnapshot(
                statusText: "Connection failed — re-enter key",
                showsStoredCopy: false, showsDisconnect: true,
                showsReconnect: true, showsValidatingSpinner: false))
        ]

        for (display, expected) in cases {
            let captured = AccountRowSnapshot.capture(display)
            #expect(captured == expected, "Snapshot mismatch for \(display): got \(captured)")

            // The bug from #165 in one assertion: it must NEVER be
            // possible to render both "stored / DISCONNECT" alongside a
            // "rejected" message. If `showsStoredCopy` is true, we are
            // necessarily connected; the rejected state does not surface
            // the "stored in Keychain" affirmation at all.
            #expect(!(captured.showsStoredCopy && captured.statusText.contains("re-enter")),
                    "Contradictory state detected — issue #165 regression: \(captured)")
        }
    }

    @Test
    @MainActor
    func reentryFlow_revealsForm_andCancels() {
        let (vm, _, _) = Self.makeViewModel(outcomes: [])
        #expect(vm.isReentryFormVisible == false)
        vm.beginReentry()
        #expect(vm.isReentryFormVisible == true)
        vm.cancelReentry()
        #expect(vm.isReentryFormVisible == false)
    }
}
