import AppKit
import Foundation
import SwiftUI

/// Drives the Providers tab. Each row in the UI is one
/// `ProviderCatalogEntry`; this view-model carries the per-provider
/// state (credential, install, model list) plus the modal state for
/// the connect sheet.
///
/// We deliberately keep all per-provider state flat rather than nesting
/// into a `[String: ProviderRow]` dictionary — SwiftUI struct-based
/// views cope better with `[Display]` arrays than dict updates, and
/// the UI iterates the catalog in a fixed order anyway.
@MainActor
final class ProvidersViewModel: ObservableObject {

    // MARK: - State machine pieces

    enum CredentialState: Equatable {
        case disconnected
        case connected
    }

    enum VMInstallState: Equatable {
        case unknown
        case checking
        case notInstalled
        case installing
        case installed
        case failed(message: String)
    }

    enum ModelListState: Equatable {
        case idle
        case loading
        case loaded
        case failed(message: String)
    }

    enum ConnectFlowState: Equatable {
        case idle
        case validating
        case validated
        case saving
        case failed(message: String)
    }

    /// One row in the providers grid. Pure value type — recomputed
    /// from the underlying maps every time.
    struct ProviderDisplay: Identifiable, Equatable {
        let entry: ProviderCatalogEntry
        let credential: CredentialState
        let vmInstall: VMInstallState
        let modelList: ModelListState
        let activeModel: String?
        let isProfileScoped: Bool

        var id: String { entry.slug }
        var hasKey: Bool { credential == .connected }
    }

    // MARK: - Published state

    @Published private(set) var providers: [ProviderDisplay] = []
    @Published var selectedProvider: ProviderCatalogEntry?
    @Published var apiKeyDraft: String = ""
    @Published var connectFlowState: ConnectFlowState = .idle
    @Published var connectFlowError: String?
    @Published var topLevelError: String?
    @Published private(set) var inFlightSlug: String?
    @Published private(set) var oauthInProgress: Bool = false

    // Model catalogs cached after a successful validate or refresh.
    // Keyed by provider slug.
    @Published private(set) var modelsBySlug: [String: [ProviderModelSummary]] = [:]

    // MARK: - Dependencies

    private let credentialStore: ProviderCredentialStore
    private let healthStore: ProviderCallHealthStore
    private let validationClient: ProviderValidationClient
    private let installer: ProviderVMInstaller
    private let oauthService: OpenRouterOAuthService
    private let urlOpener: @Sendable (URL) -> Void

    private var currentProfileId: String?
    private var refreshTasks: [String: Task<Void, Never>] = [:]

    init(
        credentialStore: ProviderCredentialStore = ProviderCredentialStore(),
        healthStore: ProviderCallHealthStore = ProviderCallHealthStore(),
        validationClient: ProviderValidationClient = ProviderValidationClient(),
        installer: ProviderVMInstaller,
        oauthService: OpenRouterOAuthService,
        urlOpener: @escaping @Sendable (URL) -> Void = { _ in }
    ) {
        self.credentialStore = credentialStore
        self.healthStore = healthStore
        self.validationClient = validationClient
        self.installer = installer
        self.oauthService = oauthService
        self.urlOpener = urlOpener
        rebuildDisplays()
    }

    /// Pushed by the view layer whenever the active connection changes.
    /// Re-derives credential state for the new host.
    func setActiveProfile(_ profileId: String?) {
        if currentProfileId == profileId { return }
        currentProfileId = profileId
        // Cancel any per-provider tasks; they were tied to the previous host.
        refreshTasks.values.forEach { $0.cancel() }
        refreshTasks = [:]
        rebuildDisplays()
    }

    func refreshFromStorage() {
        rebuildDisplays()
    }

    // MARK: - Sheet lifecycle

    func openConnectSheet(for entry: ProviderCatalogEntry) {
        selectedProvider = entry
        apiKeyDraft = ""
        connectFlowState = .idle
        connectFlowError = nil
    }

    func closeConnectSheet() {
        selectedProvider = nil
        apiKeyDraft = ""
        connectFlowState = .idle
        connectFlowError = nil
        if oauthService.isInProgress {
            oauthService.cancel()
        }
    }

    // MARK: - Save key (paste path)

    /// Validates the pasted key against the provider's `/models`
    /// endpoint, writes to Keychain on success. Pushing to the host is
    /// a separate step driven by the row's "Install on host" button so
    /// the user can decide *which* host to push to (you might enter
    /// your OpenAI key while looking at Host A but want to push to
    /// Host B later).
    func saveAPIKey() async {
        guard let entry = selectedProvider else { return }
        let trimmed = apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            connectFlowState = .failed(message: "Paste your API key first.")
            return
        }

        connectFlowState = .validating
        connectFlowError = nil

        do {
            let validation = try await validationClient.validate(apiKey: trimmed, against: entry)
            if !validation.wasSkipped {
                healthStore.recordSuccessfulCall(slug: entry.slug, forProfileId: currentProfileId)
            }
            connectFlowState = .saving
            try saveToKeychain(slug: entry.slug, apiKey: trimmed)
            modelsBySlug[entry.slug] = validation.models
            connectFlowState = .validated
            apiKeyDraft = ""
            selectedProvider = nil
            rebuildDisplays()
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            connectFlowState = .failed(message: message)
            connectFlowError = message
        }
    }

    // MARK: - OpenRouter OAuth

    /// Kicks off the PKCE dance for OpenRouter from inside the connect
    /// sheet. On success, stores the returned key and closes the sheet
    /// (model picker reveals next, just like the paste path).
    func signInWithOpenRouter() async {
        guard let entry = selectedProvider, entry.slug == "openrouter" else { return }
        oauthInProgress = true
        connectFlowState = .validating
        connectFlowError = nil
        defer { oauthInProgress = false }

        do {
            let result = try await oauthService.beginAuth()
            connectFlowState = .saving
            try saveToKeychain(slug: entry.slug, apiKey: result.apiKey)
            // Best-effort populate the model list right away; the user
            // hasn't paid the round-trip cost manually.
            if let validation = try? await validationClient.validate(apiKey: result.apiKey, against: entry) {
                modelsBySlug[entry.slug] = validation.models
                if !validation.wasSkipped {
                    healthStore.recordSuccessfulCall(slug: entry.slug, forProfileId: currentProfileId)
                }
            }
            connectFlowState = .validated
            selectedProvider = nil
            rebuildDisplays()
        } catch OpenRouterOAuthError.cancelled {
            connectFlowState = .idle
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            connectFlowState = .failed(message: message)
            connectFlowError = message
        }
    }

    /// Forwarded by `OS1App.onOpenURL` for `os1://oauth/...` URLs.
    /// Consumed silently if no auth is in flight.
    func handleOAuthCallback(_ url: URL) {
        oauthService.handleCallback(url)
    }

    // MARK: - Disconnect

    func disconnect(slug: String) {
        do {
            try clearFromKeychain(slug: slug)
            modelsBySlug.removeValue(forKey: slug)
            rebuildDisplays()
        } catch {
            topLevelError = error.localizedDescription
        }
    }

    // MARK: - Host install / activate

    func installOnHost(slug: String, connection: ConnectionProfile, activateModel: String?) async {
        guard let entry = ProviderCatalog.entry(for: slug) else { return }
        guard let apiKey = credentialStore.loadAPIKey(slug: slug, forProfileId: currentProfileId) else {
            topLevelError = "Add an API key for \(entry.displayName) first."
            return
        }
        inFlightSlug = slug
        defer { inFlightSlug = nil }

        setVMState(slug: slug, .installing)
        do {
            let result = try await installer.run(
                action: .install(apiKey: apiKey, activateModel: activateModel),
                provider: entry,
                on: connection
            )
            if result.success {
                setVMState(slug: slug, .installed, activeModel: result.active_model)
            } else {
                let message = result.errors.joined(separator: "\n")
                setVMState(slug: slug, .failed(message: message))
            }
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            setVMState(slug: slug, .failed(message: message))
        }
    }

    func activateModel(slug: String, model: String, connection: ConnectionProfile) async {
        guard let entry = ProviderCatalog.entry(for: slug) else { return }
        inFlightSlug = slug
        defer { inFlightSlug = nil }
        do {
            let result = try await installer.run(
                action: .activate(model: model),
                provider: entry,
                on: connection
            )
            if result.success {
                setVMState(slug: slug, .installed, activeModel: result.active_model ?? model)
            } else {
                topLevelError = result.errors.joined(separator: "\n")
            }
        } catch {
            topLevelError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func uninstallFromHost(slug: String, connection: ConnectionProfile) async {
        guard let entry = ProviderCatalog.entry(for: slug) else { return }
        inFlightSlug = slug
        defer { inFlightSlug = nil }
        do {
            _ = try await installer.run(action: .uninstall, provider: entry, on: connection)
            setVMState(slug: slug, .notInstalled, activeModel: nil)
        } catch {
            topLevelError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// Per-provider read-only check — returns whether the env var is
    /// currently set on the host. Cheap; the install panel uses it to
    /// render the "installed/not installed" pill.
    func checkVMStatus(slug: String, connection: ConnectionProfile) async {
        guard let entry = ProviderCatalog.entry(for: slug) else { return }
        setVMState(slug: slug, .checking)
        do {
            let result = try await installer.run(action: .status, provider: entry, on: connection)
            let installed = result.steps_done.contains("env_present")
            setVMState(
                slug: slug,
                installed ? .installed : .notInstalled,
                activeModel: result.active_model
            )
        } catch {
            // Status failures are silent — fall back to "not installed"
            // so the install button is offered.
            setVMState(slug: slug, .notInstalled)
        }
    }

    // MARK: - Model catalog

    func refreshModels(slug: String) async {
        guard let entry = ProviderCatalog.entry(for: slug) else { return }
        guard let apiKey = credentialStore.loadAPIKey(slug: slug, forProfileId: currentProfileId) else {
            topLevelError = "Add an API key for \(entry.displayName) first."
            return
        }
        setModelListState(slug: slug, .loading)
        do {
            let validation = try await validationClient.validate(apiKey: apiKey, against: entry)
            modelsBySlug[slug] = validation.models
            if !validation.wasSkipped {
                healthStore.recordSuccessfulCall(slug: slug, forProfileId: currentProfileId)
            }
            setModelListState(slug: slug, .loaded)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            setModelListState(slug: slug, .failed(message: message))
        }
    }

    func clearTopLevelError() {
        topLevelError = nil
    }

    // MARK: - URL opener

    /// Used by row "Open dashboard" buttons to bounce out to the
    /// provider's web console (where users go to grab their key).
    func openInBrowser(_ url: URL) {
        urlOpener(url)
    }

    // MARK: - Internals

    private func saveToKeychain(slug: String, apiKey: String) throws {
        if let profileId = currentProfileId {
            try credentialStore.saveAPIKey(apiKey, slug: slug, forProfileId: profileId)
        } else {
            try credentialStore.saveAsDefault(apiKey, slug: slug)
        }
    }

    private func clearFromKeychain(slug: String) throws {
        if let profileId = currentProfileId,
           credentialStore.hasProfileScopedKey(slug: slug, profileId: profileId) {
            try credentialStore.deleteKey(slug: slug, forProfileId: profileId)
        } else {
            try credentialStore.deleteDefaultKey(slug: slug)
        }
    }

    /// Per-provider mutable state lives in the `providers` array. To
    /// update a single provider, find-and-replace by slug. Cheap (6
    /// providers) and side-effect-free.
    private func setVMState(slug: String, _ state: VMInstallState, activeModel: String? = nil) {
        guard let index = providers.firstIndex(where: { $0.entry.slug == slug }) else { return }
        let prior = providers[index]
        providers[index] = ProviderDisplay(
            entry: prior.entry,
            credential: prior.credential,
            vmInstall: state,
            modelList: prior.modelList,
            activeModel: activeModel ?? prior.activeModel,
            isProfileScoped: prior.isProfileScoped
        )
    }

    private func setModelListState(slug: String, _ state: ModelListState) {
        guard let index = providers.firstIndex(where: { $0.entry.slug == slug }) else { return }
        let prior = providers[index]
        providers[index] = ProviderDisplay(
            entry: prior.entry,
            credential: prior.credential,
            vmInstall: prior.vmInstall,
            modelList: state,
            activeModel: prior.activeModel,
            isProfileScoped: prior.isProfileScoped
        )
    }

    /// Recomputes the entire displays array from Keychain + cached
    /// per-provider state. Called on profile switches and after any
    /// credential mutation.
    private func rebuildDisplays() {
        let priorBySlug = Dictionary(uniqueKeysWithValues: providers.map { ($0.entry.slug, $0) })
        providers = ProviderCatalog.entries.map { entry in
            let hasKey = credentialStore.hasAPIKey(slug: entry.slug, forProfileId: currentProfileId)
            let isProfileScoped: Bool = {
                guard let profileId = currentProfileId else { return false }
                return credentialStore.hasProfileScopedKey(slug: entry.slug, profileId: profileId)
            }()
            let prior = priorBySlug[entry.slug]
            return ProviderDisplay(
                entry: entry,
                credential: hasKey ? .connected : .disconnected,
                vmInstall: prior?.vmInstall ?? .unknown,
                modelList: prior?.modelList ?? .idle,
                activeModel: prior?.activeModel,
                isProfileScoped: isProfileScoped
            )
        }
    }
}
