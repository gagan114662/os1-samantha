import Foundation
import SwiftUI

/// Drives the Connectors tab. Three responsibilities:
///   1. Manage the user's Composio API key (Keychain-backed, BYOK only).
///   2. Manage the Composio MCP entry on the active VM's Hermes config.
///   3. Show a curated list of available toolkits with the user's
///      current connection status for each (Gmail, Slack, AgentMail,
///      etc.). Connect/disconnect actions land in C″.3.
///
/// Composio doesn't have a programmatic agent sign-up, so the "I don't
/// have a key yet" flow just sends the user to dashboard.composio.dev to
/// generate one (the consumer/`ck_...` key, not a project key).
@MainActor
final class ConnectorsViewModel: ObservableObject {
    enum SetupStep: Equatable {
        case loading                  // initial keychain check
        case unconfigured             // no key stored — show paste form
        case configured               // key present
    }

    enum VMInstallState: Equatable {
        case unknown
        case checking
        case notInstalled
        case installing
        case installed
        case failed(message: String)
    }

    /// Per-row connection state. Derived from MANAGE_CONNECTIONS list
    /// results every time we refresh. Wraps Composio's wire shape so
    /// the view can pattern-match without `Optional` gymnastics.
    enum ToolkitConnectionStatus: Equatable {
        case unknown
        case notConnected
        case connected(accountCount: Int)
    }

    /// One row in the Connectors → Toolkits list. Curated metadata is
    /// shipped statically; status comes from MANAGE_CONNECTIONS.
    struct ToolkitDisplay: Identifiable, Equatable {
        let slug: String
        let name: String
        let description: String?
        let tag: ComposioToolkitMeta.Tag
        let riskTier: ComposioToolkitMeta.RiskTier
        let requiredScopes: [String]
        let status: ToolkitConnectionStatus
        let accounts: [ComposioConnectedAccountSummary]

        var id: String { slug }
    }

    enum ToolkitListState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    @Published private(set) var step: SetupStep = .loading
    @Published var apiKeyDraft: String = ""
    @Published var formError: String?
    @Published var isBusy = false

    @Published var vmInstallState: VMInstallState = .unknown
    @Published var vmInstallError: String?

    @Published private(set) var toolkits: [ToolkitDisplay] = []
    @Published private(set) var toolkitListState: ToolkitListState = .idle

    /// When the unconfigured-state view detects an existing Composio
    /// key on the active VM's `~/.hermes/config.yaml`, we cache it here
    /// so the UI can offer one-click import.
    @Published private(set) var discoveredVMKey: DiscoveredKey?
    @Published private(set) var isScanningForVMKey = false
    @Published private(set) var lastScanResult: ScanResult = .notRun

    struct DiscoveredKey: Equatable {
        let key: String
        let connectionLabel: String
    }

    /// Tracks whether a scan has completed so the UI can distinguish
    /// "haven't checked yet" from "checked, nothing on this host."
    enum ScanResult: Equatable {
        case notRun
        case found(DiscoveredKey)
        case notFound(connectionLabel: String)
        case failed(message: String)
    }

    /// Per-toolkit connect/disconnect state. Keyed by slug. Only one
    /// toolkit can be in flight at a time (the OAuth browser flow
    /// shouldn't be parallelized — Composio's session model assumes a
    /// single active auth at a time per user).
    @Published private(set) var inFlightToolkitSlug: String?
    @Published private(set) var connectError: String?
    @Published var stripeSecretKeyDraft = ""
    @Published var stripeWebhookSecretDraft = ""
    @Published var gumroadApplicationSecretDraft = ""
    @Published private(set) var paymentCredentialStatus: [PaymentCredentialStore.SecretKind: Bool] = [:]
    @Published private(set) var paymentCredentialMessage: String?

    private let credentialStore: ComposioCredentialStore
    private let paymentCredentialStore: PaymentCredentialStore
    private let installer: ComposioVMInstaller
    private let toolkitService: ComposioToolkitService?
    private let urlOpener: @Sendable (URL) -> Void
    private var refreshTask: Task<Void, Never>?
    private var authTask: Task<Void, Never>?
    private var currentProfileId: String?

    init(
        credentialStore: ComposioCredentialStore = ComposioCredentialStore(),
        paymentCredentialStore: PaymentCredentialStore = .shared,
        installer: ComposioVMInstaller,
        toolkitService: ComposioToolkitService? = nil,
        urlOpener: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.credentialStore = credentialStore
        self.paymentCredentialStore = paymentCredentialStore
        self.installer = installer
        self.toolkitService = toolkitService
        self.urlOpener = urlOpener
        self.refreshFromStorage()
        self.refreshPaymentCredentials()
    }

    /// Pushed by the view layer whenever the active connection changes.
    /// Triggers a full state re-derive: the credential store is checked
    /// for the new profile id (or falls back to the Mac-level default),
    /// the toolkit list refreshes, and any in-flight tasks are cancelled.
    func setActiveProfile(_ profileId: String?) {
        if currentProfileId == profileId { return }
        currentProfileId = profileId
        // Reset transient state so we don't show stale data while
        // the new profile's data loads in.
        toolkits = []
        toolkitListState = .idle
        vmInstallState = .unknown
        vmInstallError = nil
        discoveredVMKey = nil
        lastScanResult = .notRun
        formError = nil
        paymentCredentialMessage = nil
        refreshFromStorage()
        refreshPaymentCredentials()
        if step == .configured {
            refreshToolkits()
        }
    }

    func refreshFromStorage() {
        step = credentialStore.hasAPIKey(forProfileId: currentProfileId) ? .configured : .unconfigured
    }

    // MARK: - Auth

    func saveAPIKey() {
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            formError = "Paste your Composio API key first."
            return
        }
        do {
            try saveTrimmedKey(trimmed)
            apiKeyDraft = ""
            formError = nil
            step = .configured
            // Force a fresh status check so the VM-install card reflects
            // the new key right away.
            vmInstallState = .unknown
            // Hydrate the toolkit list so it appears immediately.
            refreshToolkits()
        } catch {
            formError = error.localizedDescription
        }
    }

    func disconnect() {
        do { try deleteCurrentKey() } catch { }
        apiKeyDraft = ""
        formError = nil
        vmInstallState = .unknown
        vmInstallError = nil
        refreshTask?.cancel()
        toolkits = []
        toolkitListState = .idle
        step = .unconfigured
    }

    /// Writes the key to the active profile's slot if a connection is
    /// active; otherwise to the Mac-level default. This keeps one
    /// connection's key from ever ending up in another connection's slot.
    private func saveTrimmedKey(_ key: String) throws {
        if let profileId = currentProfileId {
            try credentialStore.saveAPIKey(key, forProfileId: profileId)
        } else {
            try credentialStore.saveAsDefault(key)
        }
    }

    /// Deletes only the *currently relevant* slot — never both. If the
    /// key we're showing came from the Mac-level default (no per-profile
    /// override), Disconnect clears the default. If it came from a
    /// profile-scoped slot, it clears just that slot.
    private func deleteCurrentKey() throws {
        if let profileId = currentProfileId,
           credentialStore.hasProfileScopedKey(profileId: profileId) {
            try credentialStore.deleteKey(forProfileId: profileId)
        } else {
            try credentialStore.deleteDefaultKey()
        }
    }

    // MARK: - VM install

    /// Returns true if a Composio API key is currently stored — used by
    /// the view to decide whether to show the install panel.
    var hasAPIKey: Bool { credentialStore.hasAPIKey(forProfileId: currentProfileId) }

    /// Read-only check used to populate the install pill. Doesn't write
    /// anything to the VM.
    func checkVMStatus(on connection: ConnectionProfile) async {
        vmInstallState = .checking
        vmInstallError = nil
        do {
            let result = try await installer.checkStatus(on: connection)
            vmInstallState = result.isInstalled ? .installed : .notInstalled
        } catch {
            // A failed status check just means we don't know — fall back
            // to "not installed" so the install button is offered.
            vmInstallState = .notInstalled
        }
    }

    // MARK: - Toolkits

    /// Fetches the curated toolkit list and hydrates each row's
    /// connection status. Called automatically when entering the
    /// `.configured` step and on user-initiated refresh. Cancels any
    /// in-flight refresh before starting a new one.
    func refreshToolkits() {
        guard let toolkitService else { return }
        guard step == .configured else { return }

        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            guard let self else { return }
            self.toolkitListState = .loading
            do {
                let payload = try await toolkitService.listConnections()
                try Task.checkCancellation()

                let displays: [ToolkitDisplay] = ComposioToolkitService.curatedToolkits.map { kit in
                    let slugKey = kit.slug
                    let result = payload.results?[slugKey]
                    let accounts = result?.accounts ?? []
                    let status: ToolkitConnectionStatus
                    if accounts.contains(where: { $0.status?.lowercased() == "active" }) {
                        let count = accounts.filter { $0.status?.lowercased() == "active" }.count
                        status = .connected(accountCount: count)
                    } else if result == nil {
                        status = .unknown
                    } else {
                        status = .notConnected
                    }
                    return ToolkitDisplay(
                        slug: kit.slug,
                        name: kit.name,
                        description: kit.description,
                        tag: kit.tag,
                        riskTier: kit.riskTier,
                        requiredScopes: kit.requiredScopes,
                        status: status,
                        accounts: accounts
                    )
                }

                self.toolkits = displays
                self.toolkitListState = .loaded
            } catch is CancellationError {
                return
            } catch {
                self.toolkitListState = .failed(message: (error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                // Keep prior toolkits visible so a transient error
                // doesn't blank the panel out.
            }
        }
    }

    var groupedToolkits: [(tag: ComposioToolkitMeta.Tag, toolkits: [ToolkitDisplay])] {
        ComposioToolkitMeta.Tag.allCases.compactMap { tag in
            let kits = toolkits.filter { $0.tag == tag }
            return kits.isEmpty ? nil : (tag, kits)
        }
    }

    // MARK: - VM key auto-detection

    /// Scans the active host for an existing Composio MCP entry. When
    /// found, the discovered key is parked in `discoveredVMKey` so the
    /// UI can render an import banner. No-op when:
    ///   - we already have a key in Keychain
    ///   - there's no active connection
    ///   - we're already configured
    /// Cancellable; safe to call repeatedly.
    func scanForVMKey(connection: ConnectionProfile) async {
        guard step == .unconfigured else { return }
        guard !credentialStore.hasAPIKey(forProfileId: currentProfileId) else { return }
        guard !isScanningForVMKey else { return }

        let label = connection.label.isEmpty ? "this host" : connection.label
        isScanningForVMKey = true
        defer { isScanningForVMKey = false }

        do {
            let result = try await installer.discoverKey(on: connection)
            guard step == .unconfigured else { return }   // user moved on
            guard !credentialStore.hasAPIKey(forProfileId: currentProfileId) else { return }
            if result.hasDiscoveredKey, let key = result.discovered_key {
                let discovered = DiscoveredKey(key: key, connectionLabel: label)
                discoveredVMKey = discovered
                lastScanResult = .found(discovered)
            } else {
                discoveredVMKey = nil
                lastScanResult = .notFound(connectionLabel: label)
            }
        } catch {
            // Surface failure on manual scans so the user can see why
            // it didn't work; silent on auto-scans was fine but the
            // user explicitly clicked this time.
            discoveredVMKey = nil
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            lastScanResult = .failed(message: message)
        }
    }


    /// One-click adopt: copies the discovered key into the **active
    /// profile's** Keychain slot (never the default) so importing
    /// a discovered key while connected to one host doesn't overwrite
    /// the user's own Mac-level default key.
    func importDiscoveredKey() {
        guard let discovered = discoveredVMKey else { return }
        do {
            try saveTrimmedKey(discovered.key)
            apiKeyDraft = ""
            formError = nil
            step = .configured
            vmInstallState = .unknown
            discoveredVMKey = nil
            refreshToolkits()
        } catch {
            formError = error.localizedDescription
        }
    }

    /// User clicked "Paste my own instead" — drop the banner so it
    /// doesn't reappear on every refresh.
    func dismissDiscoveredKey() {
        discoveredVMKey = nil
    }

    func installOnVM(connection: ConnectionProfile) async {
        // Use the active profile's resolved key (profile-scoped first,
        // default fallback) so we never push the wrong default key into
        // another host when no per-profile key exists for it.
        guard let apiKey = credentialStore.loadAPIKey(forProfileId: currentProfileId) else {
            vmInstallError = "Composio API key isn't set up yet — paste one first."
            return
        }
        vmInstallState = .installing
        vmInstallError = nil
        do {
            let result = try await installer.install(on: connection, apiKey: apiKey)
            if result.success {
                vmInstallState = .installed
            } else {
                let message = result.errors.joined(separator: "\n")
                vmInstallState = .failed(message: message)
                vmInstallError = message
            }
        } catch {
            let message = error.localizedDescription
            vmInstallState = .failed(message: message)
            vmInstallError = message
        }
    }

    // MARK: - Per-toolkit connect / disconnect

    /// Opens the Composio OAuth flow for one toolkit in the user's
    /// browser, then polls until the resulting connection becomes
    /// ACTIVE (or the timeout elapses). The work runs in a stored
    /// Task so the user can cancel it via `cancelInFlightAuth()` if
    /// they decide not to authorize after the browser opens.
    func connectToolkit(slug: String) {
        guard let toolkitService else { return }
        guard inFlightToolkitSlug == nil else { return }

        inFlightToolkitSlug = slug
        connectError = nil

        authTask = Task { [weak self] in
            defer {
                Task { @MainActor [weak self] in
                    self?.inFlightToolkitSlug = nil
                    self?.authTask = nil
                }
            }
            do {
                let initiated = try await toolkitService.initiateConnection(slug: slug)
                try Task.checkCancellation()
                if let url = initiated.resolvedRedirectURL {
                    self?.urlOpener(url)
                } else {
                    await MainActor.run { [weak self] in
                        self?.connectError = "Composio didn't return an authorization URL for \(slug)."
                    }
                    return
                }
                _ = try await toolkitService.waitForActiveConnection(
                    slug: slug,
                    accountId: initiated.connected_account_id
                )
                await MainActor.run { [weak self] in
                    self?.refreshToolkits()
                }
            } catch is CancellationError {
                // User clicked Cancel — silent.
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                await MainActor.run { [weak self] in
                    self?.connectError = message
                }
            }
        }
    }

    /// Cancels an in-flight OAuth flow. Safe to call when nothing is
    /// running (no-op). Triggered by the "Cancel" button that replaces
    /// the row's "Authorizing…" pill while the browser is open.
    func cancelInFlightAuth() {
        authTask?.cancel()
    }

    /// Removes every active connection for a toolkit. (Composio
    /// supports multiple accounts per toolkit; this is the bulk
    /// "disconnect all" path. Per-account disconnect is a future
    /// refinement once the UI lists individual accounts.)
    func disconnectToolkit(slug: String) async {
        guard let toolkitService else { return }
        guard inFlightToolkitSlug == nil else { return }

        let display = toolkits.first(where: { $0.slug == slug })
        let activeAccounts = (display?.accounts ?? []).filter { ($0.status?.lowercased() ?? "") == "active" }
        guard !activeAccounts.isEmpty else { return }

        inFlightToolkitSlug = slug
        connectError = nil
        defer { inFlightToolkitSlug = nil }

        do {
            for account in activeAccounts {
                try await toolkitService.removeConnection(slug: slug, accountId: account.id)
            }
            refreshToolkits()
        } catch {
            connectError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func clearConnectError() {
        connectError = nil
    }

    // MARK: - Payment credentials

    func refreshPaymentCredentials() {
        paymentCredentialStatus = Dictionary(
            uniqueKeysWithValues: PaymentCredentialStore.SecretKind.allCases.map { kind in
                (kind, paymentCredentialStore.hasSecret(kind, forProfileId: currentProfileId))
            }
        )
    }

    func savePaymentCredential(_ kind: PaymentCredentialStore.SecretKind) {
        let draft = paymentCredentialDraft(for: kind).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.isEmpty else {
            paymentCredentialMessage = "Paste \(kind.displayName) first."
            return
        }
        do {
            if let profileId = currentProfileId {
                try paymentCredentialStore.saveSecret(draft, kind: kind, forProfileId: profileId)
            } else {
                try paymentCredentialStore.saveDefaultSecret(draft, kind: kind)
            }
            clearPaymentCredentialDraft(kind)
            paymentCredentialMessage = "\(kind.displayName) saved in Keychain."
            refreshPaymentCredentials()
        } catch {
            paymentCredentialMessage = error.localizedDescription
        }
    }

    func deletePaymentCredential(_ kind: PaymentCredentialStore.SecretKind) {
        do {
            if let profileId = currentProfileId,
               paymentCredentialStore.hasProfileScopedSecret(kind, profileId: profileId) {
                try paymentCredentialStore.deleteSecret(kind, forProfileId: profileId)
            } else {
                try paymentCredentialStore.deleteDefaultSecret(kind)
            }
            paymentCredentialMessage = "\(kind.displayName) removed."
            refreshPaymentCredentials()
        } catch {
            paymentCredentialMessage = error.localizedDescription
        }
    }

    func hasPaymentCredential(_ kind: PaymentCredentialStore.SecretKind) -> Bool {
        paymentCredentialStatus[kind] == true
    }

    private func paymentCredentialDraft(for kind: PaymentCredentialStore.SecretKind) -> String {
        switch kind {
        case .stripeSecretKey: stripeSecretKeyDraft
        case .stripeWebhookSecret: stripeWebhookSecretDraft
        case .gumroadApplicationSecret: gumroadApplicationSecretDraft
        }
    }

    private func clearPaymentCredentialDraft(_ kind: PaymentCredentialStore.SecretKind) {
        switch kind {
        case .stripeSecretKey: stripeSecretKeyDraft = ""
        case .stripeWebhookSecret: stripeWebhookSecretDraft = ""
        case .gumroadApplicationSecret: gumroadApplicationSecretDraft = ""
        }
    }
}
