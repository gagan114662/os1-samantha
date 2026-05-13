import CryptoKit
import Foundation
import AppKit
import SwiftUI

/// Drives the Doctor tab. Phase 1 surfaces two checks per active host:
///
///   1. **Hermes gateway** — runs `hermes gateway status` + reads
///      `~/.hermes/gateway_state.json` for per-platform state. Offers
///      a Restart action that re-runs the supervised install path.
///   2. **Telegram bot** — pings `getMe` against the stored bot token
///      and cross-references against the gateway's view of telegram.
///      Offers a Revalidate action.
///
/// Manual refresh + onAppear only — auto-polling deliberately deferred
/// to Phase 2. The user goes to this tab when something feels wrong;
/// they'll click Refresh.
@MainActor
final class DoctorViewModel: ObservableObject {
    nonisolated static let defaultCheckTimeoutSeconds: TimeInterval = 30
    private nonisolated static let harnessNoCompletionAlertSeconds: TimeInterval = 60

    enum Severity: Equatable, Sendable {
        case unknown   // not yet checked
        case ok        // green — everything healthy
        case warn      // amber — degraded but not fatal
        case error     // red — broken, needs user attention
    }

    enum Action: Equatable, Hashable, Sendable {
        case restartGateway
        case revalidateTelegram
        case updateHermes
        case reinstallLaunchAgents
        case migrateSchema
        case retryCheck(String)
        case openLogs(String)
    }

    enum CheckState: String, CaseIterable, Equatable, Sendable {
        case pending
        case running
        case pass
        case warn
        case fail
        case timeout
        case skipped

        var isTerminal: Bool {
            switch self {
            case .pending, .running: false
            case .pass, .warn, .fail, .timeout, .skipped: true
            }
        }
    }

    struct Check: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let state: CheckState
        let severity: Severity
        let summary: String
        let detail: String?
        let actions: [Action]
        let timeoutSeconds: TimeInterval
        let logPath: String?
        let errorMessage: String?

        init(
            id: String,
            title: String,
            severity: Severity,
            summary: String,
            detail: String?,
            actions: [Action],
            state: CheckState? = nil,
            timeoutSeconds: TimeInterval = DoctorViewModel.defaultCheckTimeoutSeconds,
            logPath: String? = nil,
            errorMessage: String? = nil
        ) {
            self.id = id
            self.title = title
            self.state = state ?? Self.terminalState(for: severity)
            self.severity = severity
            self.summary = summary
            self.detail = detail
            self.actions = actions
            self.timeoutSeconds = timeoutSeconds
            self.logPath = logPath
            self.errorMessage = errorMessage
        }

        static func pending(id: String, title: String, timeoutSeconds: TimeInterval, logPath: String?) -> Check {
            Check(
                id: id,
                title: title,
                severity: .unknown,
                summary: L10n.string("Waiting to run."),
                detail: nil,
                actions: [],
                state: .pending,
                timeoutSeconds: timeoutSeconds,
                logPath: logPath
            )
        }

        func replacing(
            state: CheckState? = nil,
            severity: Severity? = nil,
            summary: String? = nil,
            detail: String?? = nil,
            actions: [Action]? = nil,
            timeoutSeconds: TimeInterval? = nil,
            logPath: String?? = nil,
            errorMessage: String?? = nil
        ) -> Check {
            Check(
                id: id,
                title: title,
                severity: severity ?? self.severity,
                summary: summary ?? self.summary,
                detail: detail ?? self.detail,
                actions: actions ?? self.actions,
                state: state ?? self.state,
                timeoutSeconds: timeoutSeconds ?? self.timeoutSeconds,
                logPath: logPath ?? self.logPath,
                errorMessage: errorMessage ?? self.errorMessage
            )
        }

        static func terminalState(for severity: Severity) -> CheckState {
            switch severity {
            case .ok: return .pass
            case .warn: return .warn
            case .error: return .fail
            case .unknown: return .skipped
            }
        }
    }

    private enum DoctorCheckError: LocalizedError, Sendable {
        case deallocated

        var errorDescription: String? {
            switch self {
            case .deallocated: return L10n.string("Doctor view model was released before the check completed.")
            }
        }
    }

    private struct DoctorCheckTimeoutError: LocalizedError, Sendable {
        let title: String
        let timeoutSeconds: TimeInterval

        var errorDescription: String? {
            L10n.string(
                "%@ timed out after %.0f seconds.",
                title,
                timeoutSeconds
            )
        }
    }

    struct ResolvedCheck: Sendable {
        let check: Check
        let startedAt: Date
        let endedAt: Date
        let latencyMS: Int
        let errorMessage: String?
    }

    private final class CheckResultGate: @unchecked Sendable {
        private let lock = NSLock()
        private var didResume = false

        func resume(
            _ continuation: CheckedContinuation<Result<Check, Error>, Never>,
            returning result: Result<Check, Error>
        ) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !didResume else { return false }
            didResume = true
            continuation.resume(returning: result)
            return true
        }
    }

    private nonisolated static var gatewayLogPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".hermes/logs/gateway.log")
            .path
    }

    private nonisolated static var doctorEventLogPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".os1/codex-tasks/events.jsonl")
            .path
    }

    struct CheckDefinition: Sendable {
        let id: String
        let title: String
        let timeoutSeconds: TimeInterval
        let logPath: String?
        let run: @MainActor @Sendable () async throws -> Check

        init(
            id: String,
            title: String,
            timeoutSeconds: TimeInterval = DoctorViewModel.defaultCheckTimeoutSeconds,
            logPath: String? = nil,
            run: @escaping @MainActor @Sendable () async throws -> Check
        ) {
            self.id = id
            self.title = title
            self.timeoutSeconds = timeoutSeconds
            self.logPath = logPath
            self.run = run
        }
    }

    struct CodexHeartbeatSandboxRuntime: Equatable, Sendable {
        let isOn: Bool
        let title: String
        let summary: String
        let detail: String
    }

    struct ProviderKeyHealthRow: Equatable, Sendable {
        let providerSlug: String
        let displayName: String
        let hasKey: Bool
        let lastSuccessfulCall: Date?

        var summary: String {
            let keyStatus = hasKey ? "key present" : "key missing"
            let last = lastSuccessfulCall
                .map { ISO8601DateFormatter().string(from: $0) }
                ?? "never"
            return "\(displayName): \(keyStatus), last successful call: \(last)"
        }
    }

    struct LaunchAgentDriftReport: Equatable, Sendable {
        let label: String
        let installedPath: String
        let expectedHash: String
        let installedHash: String?
        let problem: String?
    }

    @Published private(set) var checks: [Check] = []
    @Published private(set) var paymentsSnapshot: PaymentsHealthSnapshot = .empty
    @Published private(set) var fleetSnapshot: CompanyFleetHealthSnapshot = .empty
    @Published private(set) var isRefreshing = false
    @Published private(set) var actionInFlight: Action?
    @Published var actionError: String?
    @Published private(set) var lastRefreshedAt: Date?

    var checksSummary: String {
        guard !checks.isEmpty else { return L10n.string("No checks have run yet.") }
        let completed = checks.filter(\.state.isTerminal).count
        let running = checks.filter { $0.state == .running }.count
        let failed = checks.filter { $0.state == .fail || $0.state == .timeout }.count
        let warned = checks.filter { $0.state == .warn }.count
        if completed < checks.count {
            return L10n.string(
                "Running checks: %lld/%lld complete, %lld active.",
                completed,
                checks.count,
                running
            )
        }
        if failed > 0 {
            return L10n.string("Checks complete: %lld need attention, %lld warning(s).", failed, warned)
        }
        if warned > 0 {
            return L10n.string("Checks complete: %lld warning(s), no failures.", warned)
        }
        return L10n.string("Checks complete: all rows resolved.")
    }

    var hasUnresolvedChecks: Bool {
        checks.contains { !$0.state.isTerminal }
    }

    private let credentialStore: TelegramCredentialStore
    private let providerCredentialStore: ProviderCredentialStore
    private let providerCallHealthStore: ProviderCallHealthStore
    private let telegramAPI: TelegramAPIClient
    private let telegramInstaller: TelegramVMInstaller
    private let hermesUpdater: HermesUpdater
    /// Bridges to AppState — DoctorViewModel doesn't take AppState in its
    /// init (avoids a cycle, keeps unit tests simple), but the update
    /// trigger + availability state need to flow back so the Overview
    /// banner sees the same source-of-truth. Set after construction via
    /// `bindHermesUpdateBridge`.
    private var performHermesUpdateBridge: @MainActor () async -> Void = { }
    private var publishHermesAvailability: @MainActor (HermesUpdateAvailability) -> Void = { _ in }
    private var currentConnection: ConnectionProfile?
    private var currentProfileId: String?
    private var currentRunID: String?
    private var currentDefinitions: [String: CheckDefinition] = [:]
    private var harnessSelfCheckTask: Task<Void, Never>?
    private let checkDefinitionsForTesting: [CheckDefinition]?

    init(
        credentialStore: TelegramCredentialStore,
        providerCredentialStore: ProviderCredentialStore = ProviderCredentialStore(),
        providerCallHealthStore: ProviderCallHealthStore = ProviderCallHealthStore(),
        telegramAPI: TelegramAPIClient = TelegramAPIClient(),
        telegramInstaller: TelegramVMInstaller,
        hermesUpdater: HermesUpdater,
        checkDefinitionsForTesting: [CheckDefinition]? = nil
    ) {
        self.credentialStore = credentialStore
        self.providerCredentialStore = providerCredentialStore
        self.providerCallHealthStore = providerCallHealthStore
        self.telegramAPI = telegramAPI
        self.telegramInstaller = telegramInstaller
        self.hermesUpdater = hermesUpdater
        self.checkDefinitionsForTesting = checkDefinitionsForTesting
    }

    func bindHermesUpdateBridge(
        performUpdate: @escaping @MainActor () async -> Void,
        publishAvailability: @escaping @MainActor (HermesUpdateAvailability) -> Void
    ) {
        self.performHermesUpdateBridge = performUpdate
        self.publishHermesAvailability = publishAvailability
    }

    func setActiveConnection(_ connection: ConnectionProfile?) {
        if currentConnection?.id == connection?.id { return }
        currentConnection = connection
        currentProfileId = connection?.id.uuidString
        // Reset transient state — the new host has its own checks.
        checks = []
        lastRefreshedAt = nil
        actionError = nil
    }

    // MARK: - Refresh

    func refresh() async {
        guard !isRefreshing else { return }
        let runID = UUID().uuidString
        currentRunID = runID
        isRefreshing = true
        defer {
            if currentRunID == runID {
                isRefreshing = false
                lastRefreshedAt = Date()
                harnessSelfCheckTask?.cancel()
                harnessSelfCheckTask = nil
            }
        }
        actionError = nil

        // Local stack checks always run — they don't depend on a host
        // being selected. These cover the moving parts that historically
        // failed silently (codex auth, claude CLI, WUPHF, launchd plists,
        // keychain credentials, voice-port freshness).
        let now = Date()
        let recentEvents = CodexSessionManager.shared.recentEvents(limit: 10_000)
        paymentsSnapshot = Self.paymentsHealthSnapshot(recentEvents: recentEvents)
        fleetSnapshot = Self.fleetHealthSnapshot(
            sessions: CodexSessionManager.shared.sessions,
            events: recentEvents,
            now: now
        )
        let definitions = checkDefinitionsForTesting ?? makeCheckDefinitions(
            recentEvents: recentEvents,
            connection: currentConnection
        )
        await runCheckDefinitions(definitions, runID: runID)
    }

    private func makeCheckDefinitions(
        recentEvents: [CompanyEvent],
        connection: ConnectionProfile?
    ) -> [CheckDefinition] {
        var definitions = makeLocalStackCheckDefinitions(recentEvents: recentEvents)
        guard let connection else {
            definitions.append(CheckDefinition(
                id: "no-connection",
                title: L10n.string("No host selected"),
                timeoutSeconds: 1
            ) {
                Check(
                    id: "no-connection",
                    title: L10n.string("No host selected"),
                    severity: .unknown,
                    summary: L10n.string("Pick a host on the Host tab to run host-level checks (gateway, Hermes, Telegram)."),
                    detail: nil,
                    actions: [],
                    state: .skipped,
                    timeoutSeconds: 1
                )
            })
            return definitions
        }

        definitions.append(contentsOf: [
            CheckDefinition(
                id: "gateway",
                title: L10n.string("Hermes gateway"),
                logPath: Self.gatewayLogPath
            ) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                let statusResult = try await self.telegramInstaller.checkStatus(on: connection)
                let snapshot = GatewayStateSnapshot.decode(from: statusResult.gateway_state_json)
                return self.makeGatewayCheck(result: statusResult, snapshot: snapshot)
            },
            CheckDefinition(
                id: "hermes-version",
                title: L10n.string("Hermes version"),
                logPath: Self.gatewayLogPath
            ) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                let availability = await self.probeHermesAvailability(on: connection)
                if !Task.isCancelled {
                    self.publishHermesAvailability(availability)
                }
                return self.makeHermesCheck(availability: availability)
            },
            CheckDefinition(
                id: "telegram",
                title: L10n.string("Telegram bot"),
                logPath: Self.gatewayLogPath
            ) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeTelegramCheck(snapshot: nil)
            }
        ])
        return definitions
    }

    private func runCheckDefinitions(_ definitions: [CheckDefinition], runID: String) async {
        currentDefinitions = Dictionary(definitions.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        checks = definitions.map {
            Check.pending(id: $0.id, title: $0.title, timeoutSeconds: $0.timeoutSeconds, logPath: $0.logPath)
        }
        scheduleHarnessSelfCheck(runID: runID)
        for definition in definitions {
            updateCheck(
                id: definition.id,
                with: Check.pending(
                    id: definition.id,
                    title: definition.title,
                    timeoutSeconds: definition.timeoutSeconds,
                    logPath: definition.logPath
                ).replacing(
                    state: .running,
                    summary: L10n.string("Running…")
                )
            )
        }

        await withTaskGroup(of: ResolvedCheck.self) { group in
            for definition in definitions {
                group.addTask {
                    await Self.executeCheckDefinition(definition)
                }
            }

            for await resolved in group {
                guard currentRunID == runID else { continue }
                updateCheck(id: resolved.check.id, with: resolved.check)
                CodexSessionManager.shared.recordDoctorCheckEvent(
                    runID: runID,
                    checkName: resolved.check.title,
                    checkID: resolved.check.id,
                    startedAt: resolved.startedAt,
                    endedAt: resolved.endedAt,
                    outcome: resolved.check.state.rawValue,
                    latencyMS: resolved.latencyMS,
                    error: resolved.errorMessage
                )
            }
        }
    }

    nonisolated static func executeCheckDefinition(_ definition: CheckDefinition) async -> ResolvedCheck {
        let startedAt = Date()
        let result = await checkResultWithTimeout(definition)
        let endedAt = Date()
        let latencyMS = max(0, Int(endedAt.timeIntervalSince(startedAt) * 1_000))

        switch result {
        case .success(let check):
            let state = check.state.isTerminal ? check.state : Check.terminalState(for: check.severity)
            return ResolvedCheck(
                check: check.replacing(
                    state: state,
                    timeoutSeconds: definition.timeoutSeconds,
                    logPath: check.logPath ?? definition.logPath
                ),
                startedAt: startedAt,
                endedAt: endedAt,
                latencyMS: latencyMS,
                errorMessage: nil
            )
        case .failure(let error as DoctorCheckTimeoutError):
            let message = error.errorDescription ?? L10n.string("Doctor check timed out.")
            return ResolvedCheck(
                check: Check(
                    id: definition.id,
                    title: definition.title,
                    severity: .error,
                    summary: L10n.string("Timed out. Click Retry to run this check again."),
                    detail: message + " " + L10n.string("Click Retry to run this check again."),
                    actions: [.retryCheck(definition.id)],
                    state: .timeout,
                    timeoutSeconds: definition.timeoutSeconds,
                    logPath: definition.logPath,
                    errorMessage: message
                ),
                startedAt: startedAt,
                endedAt: endedAt,
                latencyMS: latencyMS,
                errorMessage: message
            )
        case .failure(let error):
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            let logPath = definition.logPath ?? doctorEventLogPath
            return ResolvedCheck(
                check: Check(
                    id: definition.id,
                    title: definition.title,
                    severity: .error,
                    summary: L10n.string("Check failed. Open logs or retry."),
                    detail: message,
                    actions: [.openLogs(logPath), .retryCheck(definition.id)],
                    state: .fail,
                    timeoutSeconds: definition.timeoutSeconds,
                    logPath: logPath,
                    errorMessage: message
                ),
                startedAt: startedAt,
                endedAt: endedAt,
                latencyMS: latencyMS,
                errorMessage: message
            )
        }
    }

    private nonisolated static func checkResultWithTimeout(_ definition: CheckDefinition) async -> Result<Check, Error> {
        await withCheckedContinuation { continuation in
            let gate = CheckResultGate()
            let operation = Task { @MainActor in
                do {
                    let check = try await definition.run()
                    _ = gate.resume(continuation, returning: .success(check))
                } catch {
                    _ = gate.resume(continuation, returning: .failure(error))
                }
            }
            Task {
                let timeoutNanoseconds = UInt64(max(0.001, definition.timeoutSeconds) * 1_000_000_000)
                try? await Task.sleep(nanoseconds: timeoutNanoseconds)
                let timeout = DoctorCheckTimeoutError(
                    title: definition.title,
                    timeoutSeconds: definition.timeoutSeconds
                )
                if gate.resume(continuation, returning: .failure(timeout)) {
                    operation.cancel()
                }
            }
        }
    }

    private func updateCheck(id: String, with check: Check) {
        if let index = checks.firstIndex(where: { $0.id == id }) {
            checks[index] = check
        } else {
            checks.append(check)
        }
    }

    private func scheduleHarnessSelfCheck(runID: String) {
        harnessSelfCheckTask?.cancel()
        harnessSelfCheckTask = Task { [weak self] in
            let nanoseconds = UInt64(Self.harnessNoCompletionAlertSeconds * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            await MainActor.run {
                guard let self,
                      self.currentRunID == runID,
                      !self.checks.contains(where: { $0.state.isTerminal })
                else { return }
                self.actionError = L10n.string(
                    "Doctor harness alert: no checks completed within %.0f seconds. Open logs and retry the run.",
                    Self.harnessNoCompletionAlertSeconds
                )
            }
        }
    }

    // MARK: - Local stack checks

    private func makeLocalStackCheckDefinitions(recentEvents: [CompanyEvent]) -> [CheckDefinition] {
        [
            CheckDefinition(id: "cli-codex", title: "Codex CLI", timeoutSeconds: 8) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeBinaryCheck(id: "cli-codex", title: "Codex CLI", binary: "codex", versionArgs: ["--version"])
            },
            CheckDefinition(id: "cli-claude", title: "Claude Code CLI", timeoutSeconds: 8) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeBinaryCheck(id: "cli-claude", title: "Claude Code CLI", binary: "claude", versionArgs: ["--version"])
            },
            CheckDefinition(id: "wuphf", title: "WUPHF office", timeoutSeconds: 8) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeWUPHFCheck()
            },
            CheckDefinition(id: "launchd", title: "Launchd plists", timeoutSeconds: 8) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeLaunchdCheck()
            },
            CheckDefinition(id: "voice-port", title: "Voice server port", timeoutSeconds: 5) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeVoicePortCheck()
            },
            CheckDefinition(id: "keychain", title: "Keychain credentials", timeoutSeconds: 12) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeKeychainCheck()
            },
            CheckDefinition(id: "api-first-connectors", title: "API-first connectors") { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeConnectorHealthCheck()
            },
            CheckDefinition(id: "company-credential-scopes", title: "Company credential scopes") { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeSharedCredentialScopeCheck()
            },
            CheckDefinition(id: "notarization", title: "App bundle signing", timeoutSeconds: 12) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeNotarizationCheck()
            },
            CheckDefinition(id: "production-gates", title: L10n.string("Production gates")) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeProductionGatesCheck()
            },
            CheckDefinition(id: "evaluation-harness", title: L10n.string("Agent eval harness")) { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeEvaluationHarnessCheck()
            },
            CheckDefinition(id: "data-governance", title: "Data governance") { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeDataGovernanceCheck()
            },
            CheckDefinition(id: "company-state-backups", title: "Company state backups") { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeStateBackupCheck()
            },
            CheckDefinition(id: "durable-state-schema", title: "Durable state schema") { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeDurableStateSchemaCheck()
            },
            CheckDefinition(id: "codex-heartbeat-sandbox", title: "Codex heartbeat sandbox") { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeCodexHeartbeatSandboxCheck()
            },
            CheckDefinition(id: "codex-feature-matrix", title: "Codex feature matrix") { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeCodexFeatureMatrixCheck()
            },
            CheckDefinition(id: "browser-stealth-coverage", title: "Browser stealth coverage") { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeBrowserStealthCoverageCheck()
            },
            CheckDefinition(id: "provider-key-health", title: "Provider keys") { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return await self.makeProviderKeyHealthCheck(recentEvents: recentEvents)
            },
            CheckDefinition(id: "portfolio-p&l", title: "Portfolio P&L") { [weak self] in
                guard let self else { throw DoctorCheckError.deallocated }
                return self.makePortfolioPnLCheck()
            }
        ]
    }

    /// Builds the `portfolio-p&l` Doctor row. Reads the most recent persisted
    /// snapshot from `PortfolioSnapshotStore` and applies the 7-day cost>revenue
    /// rule. If no snapshot is available yet (cold start), shows an `unknown`
    /// state rather than green — we don't claim health we can't prove.
    nonisolated func makePortfolioPnLCheck() -> Check {
        let store = PortfolioSnapshotStore.defaultStore()
        guard let report = try? store.loadLatest() else {
            return Self.portfolioPnLDoctorRow(report: nil)
        }
        return Self.portfolioPnLDoctorRow(report: report)
    }

    /// Pure rendering of the Doctor row from a snapshot. Static + nonisolated
    /// so the test suite can drive it with synthetic reports.
    nonisolated static func portfolioPnLDoctorRow(
        report: PortfolioAggregateReport?,
        thresholdDays: Int = 7
    ) -> Check {
        guard let report else {
            return Check(
                id: "portfolio-p&l",
                title: "Portfolio P&L",
                severity: .unknown,
                summary: "No portfolio snapshot recorded yet.",
                detail: "Open the Portfolio tab to record the first snapshot. The row turns red after \(thresholdDays) consecutive days of cost > revenue.",
                actions: []
            )
        }
        let verdict = PortfolioAggregator.portfolioPnLVerdict(report: report, thresholdDays: thresholdDays)
        let margin = report.totalRevenueUSD - report.totalCostUSD
        let summary = String(
            format: "Margin %@$%.2f over %d companies (last recompute: %@).",
            margin >= 0 ? "+" : "−",
            abs(margin),
            report.companyCount,
            report.recomputeTrigger.rawValue
        )
        switch verdict {
        case .red(let streak):
            return Check(
                id: "portfolio-p&l",
                title: "Portfolio P&L",
                severity: .error,
                summary: summary,
                detail: "Aggregate cost has exceeded revenue for \(streak) consecutive days (≥ \(thresholdDays) threshold). Pause underperformers or cut spend.",
                actions: []
            )
        case .degraded(let streak):
            return Check(
                id: "portfolio-p&l",
                title: "Portfolio P&L",
                severity: .warn,
                summary: summary,
                detail: "Cost-heavy for \(streak) of the last \(thresholdDays) days. Trending toward the red threshold.",
                actions: []
            )
        case .healthy(let streak):
            return Check(
                id: "portfolio-p&l",
                title: "Portfolio P&L",
                severity: .ok,
                summary: summary,
                detail: streak == 0 ? "Revenue ≥ cost on every recent day." : "Brief \(streak)-day cost-heavy streak; well below the \(thresholdDays)-day threshold.",
                actions: []
            )
        case .insufficientData:
            return Check(
                id: "portfolio-p&l",
                title: "Portfolio P&L",
                severity: .unknown,
                summary: summary,
                detail: "Not enough daily history yet to evaluate the \(thresholdDays)-day rule.",
                actions: []
            )
        }
    }

    private func makeProviderKeyHealthCheck(recentEvents: [CompanyEvent]) async -> Check {
        let credentialStatuses = providerCredentialStore.loadConnectionStatuses(forProfileId: currentProfileId)
        let storedCalls = providerCallHealthStore.loadLastSuccessfulCalls(forProfileId: currentProfileId)
        let eventCalls = Self.lastSuccessfulProviderCalls(from: recentEvents)
        let rows = Self.providerKeyHealthRows(
            credentialStatuses: credentialStatuses,
            lastSuccessfulCalls: Self.mergeLatestProviderCalls(storedCalls, eventCalls)
        )
        let missing = rows.filter { !$0.hasKey }.count
        return Check(
            id: "provider-key-health",
            title: "Provider keys",
            severity: missing == 0 ? .ok : .warn,
            summary: missing == 0 ? "All provider keys are present" : "\(missing) provider key(s) missing",
            detail: rows.map(\.summary).joined(separator: "\n"),
            actions: []
        )
    }

    nonisolated static func providerKeyHealthRows(
        credentialStatuses: [String: Bool],
        lastSuccessfulCalls: [String: Date]
    ) -> [ProviderKeyHealthRow] {
        ProviderCatalog.entries.map { entry in
            ProviderKeyHealthRow(
                providerSlug: entry.slug,
                displayName: entry.displayName,
                hasKey: credentialStatuses[entry.slug] ?? false,
                lastSuccessfulCall: lastSuccessfulCalls[entry.slug]
            )
        }
    }

    nonisolated static func lastSuccessfulProviderCalls(from events: [CompanyEvent]) -> [String: Date] {
        let providerSlugs = Set(ProviderCatalog.entries.map(\.slug))
        return events.reduce(into: [:]) { result, event in
            guard event.kind == .externalSideEffect,
                  let providerSlug = event.tool,
                  providerSlugs.contains(providerSlug),
                  event.approvalState != "blocked"
            else { return }
            let occurredAt = event.occurredAt
            if let previous = result[providerSlug], previous >= occurredAt { return }
            result[providerSlug] = occurredAt
        }
    }

    nonisolated static func mergeLatestProviderCalls(
        _ first: [String: Date],
        _ second: [String: Date]
    ) -> [String: Date] {
        var result = first
        for (slug, date) in second {
            if let previous = result[slug], previous >= date { continue }
            result[slug] = date
        }
        return result
    }

    private func makeBrowserStealthCoverageCheck() async -> Check {
        let configuredDomains = Self.discoveredBrowserStealthProfileDomains()
        let rows = Self.browserStealthCoverageRows(configuredDomains: configuredDomains)
        let missingCount = rows.filter { $0.hasSuffix("missing") }.count
        return Check(
            id: "browser-stealth-coverage",
            title: missingCount == 0 ? "Browser stealth coverage" : "Browser stealth coverage incomplete",
            severity: missingCount == 0 ? .ok : .warn,
            summary: missingCount == 0
                ? "Consumer-platform browser automation has stealth profiles for every required domain"
                : "\(missingCount) consumer-platform domain(s) are missing stealth profiles",
            detail: rows.joined(separator: "\n"),
            actions: []
        )
    }

    nonisolated static func browserStealthCoverageRows(configuredDomains: Set<String>) -> [String] {
        CompanyBrowserSafetyPolicy.consumerPlatformDomains
            .sorted()
            .map { domain in
                let normalized = CompanyBrowserSafetyPolicy.normalizeDomain(domain)
                let status = configuredDomains.contains(normalized) ? "covered" : "missing"
                return "\(normalized): \(status)"
            }
    }

    private nonisolated static func discoveredBrowserStealthProfileDomains() -> Set<String> {
        // Profile persistence is intentionally file-based; each company writes
        // browser-stealth/<domain>.json under its codex task directory.
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".os1/codex-tasks", isDirectory: true)
        guard let companies = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return Set(companies.flatMap { companyURL -> [String] in
            let stealthRoot = companyURL.appendingPathComponent("browser-stealth", isDirectory: true)
            guard let profiles = try? FileManager.default.contentsOfDirectory(
                at: stealthRoot,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            return profiles
                .filter { $0.pathExtension == "json" }
                .map { CompanyBrowserSafetyPolicy.normalizeDomain($0.deletingPathExtension().lastPathComponent) }
        })
    }

    private func makeCodexFeatureMatrixCheck() async -> Check {
        let profile = CompanyCodexProfile.productionDefault(companyID: "doctor")
        let required: [CompanyCodexProfile.Feature] = [
            .imagegen,
            .web,
            .vision,
            .mcp,
            .customToolRegistration,
            .sandboxMode,
            .approvalModes,
            .resume,
            .streaming,
            .auditTimeline,
            .argsHashing,
            .latencyTracking,
            .costTracking
        ]
        let missing = required.filter { !profile.supports($0) }
        let enabled = required.map(\.rawValue).joined(separator: ", ")
        return Check(
            id: "codex-feature-matrix",
            title: missing.isEmpty ? "Codex feature matrix: ON" : "Codex feature matrix: incomplete",
            severity: missing.isEmpty ? .ok : .error,
            summary: missing.isEmpty
                ? "Production company profile enables required Codex runtime features"
                : "Production company profile is missing \(missing.count) required Codex features",
            detail: missing.isEmpty
                ? "Enabled features: \(enabled)."
                : "Missing features: \(missing.map(\.rawValue).joined(separator: ", ")).",
            actions: []
        )
    }

    private func makeCodexHeartbeatSandboxCheck() async -> Check {
        let session = CodexSession(
            id: "doctor",
            title: "doctor-sandbox-probe",
            task: "Probe Codex heartbeat sandbox launch mode.",
            worktreePath: "/tmp/os1-doctor-sandbox-probe",
            branch: "company/doctor",
            status: .idle,
            startedAt: Date(timeIntervalSince1970: 0),
            finishedAt: nil,
            exitCode: nil,
            pid: nil,
            cadenceMinutes: 15,
            heartbeatCount: 0,
            lastHeartbeatAt: nil,
            nextHeartbeatAt: nil,
            pendingUserInstruction: nil,
            templateID: nil,
            budget: nil,
            lifecycleStage: .validating,
            sandboxMode: .sandbox,
            environment: .sandbox,
            credentialAllowlist: [],
            heartbeatLease: nil,
            assignedRunnerID: CompanyScaleScheduler.localRunnerID
        )
        let launchPlan = CodexSessionManager.heartbeatLaunchPlan(
            session: session,
            sandboxProfileURL: URL(fileURLWithPath: "/tmp/os1-doctor-sandbox-probe.sb"),
            promptFile: "/tmp/os1-doctor-sandbox-probe.prompt"
        )
        let runtime = Self.codexHeartbeatSandboxRuntime(
            sandboxExecIsExecutable: FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec"),
            launchPlan: launchPlan
        )
        return Check(
            id: "codex-heartbeat-sandbox",
            title: runtime.title,
            severity: runtime.isOn ? .ok : .error,
            summary: runtime.summary,
            detail: runtime.detail,
            actions: []
        )
    }

    static func paymentsHealthSnapshot(
        recentEvents: [CompanyEvent] = [],
        replayStoreSize: Int = 0
    ) -> PaymentsHealthSnapshot {
        func lastEvent(for provider: String, fallback: String) -> String {
            let latest = recentEvents
                .filter {
                    $0.kind == .ledgerEntryRecorded &&
                    $0.metadata["provider"]?.caseInsensitiveCompare(provider) == .orderedSame
                }
                .max { $0.occurredAt < $1.occurredAt }
            guard let latest else { return fallback }
            let eventID = latest.metadata["eventID"] ?? latest.metadata["providerEventID"] ?? "event"
            return "\(eventID) @ \(ISO8601DateFormatter().string(from: latest.occurredAt))"
        }

        return PaymentsHealthSnapshot(rows: [
            .init(
                provider: "Stripe",
                endpoint: "/webhooks/stripe",
                lastEvent: lastEvent(for: "stripe", fallback: "waiting-for-event"),
                reconciliation: "ledger-ready",
                replayStoreSize: replayStoreSize
            ),
            .init(
                provider: "Gumroad",
                endpoint: "/webhooks/gumroad",
                lastEvent: lastEvent(for: "gumroad", fallback: "waiting-for-event"),
                reconciliation: "ledger-ready",
                replayStoreSize: replayStoreSize
            ),
            .init(provider: "Etsy", endpoint: "sales.csv", lastEvent: "csv-ready", reconciliation: "ledger-ready", replayStoreSize: replayStoreSize),
            .init(provider: "KDP", endpoint: "royalties.csv", lastEvent: "csv-ready", reconciliation: "ledger-ready", replayStoreSize: replayStoreSize),
            .init(provider: "App Store", endpoint: "sales.csv", lastEvent: "csv-ready", reconciliation: "ledger-ready", replayStoreSize: replayStoreSize),
            .init(provider: "Google Play", endpoint: "earnings.csv", lastEvent: "csv-ready", reconciliation: "ledger-ready", replayStoreSize: replayStoreSize)
        ])
    }

    static func fleetHealthSnapshot(
        sessions: [CodexSession],
        events: [CompanyEvent] = [],
        runners: [CompanyRunner] = [.local],
        now: Date = Date()
    ) -> CompanyFleetHealthSnapshot {
        CompanyFleetHealthSnapshot.make(
            sessions: sessions,
            runners: runners,
            driftFlaggedCompanyIDs: CompanyFleetHealthSnapshot.driftFlaggedCompanyIDs(from: events),
            now: now
        )
    }

    static func fleetDoctorRows(snapshot: CompanyFleetHealthSnapshot) -> [String] {
        [
            L10n.string(
                "Fleet capacity: %lld workers × cap %lld = %lld concurrent",
                snapshot.activeWorkers,
                snapshot.perWorkerCap,
                snapshot.totalConcurrentCapacity
            ),
            L10n.string("Companies flagged as drifting: %lld", snapshot.driftingCompanyCount)
        ]
    }

    private func makeStateBackupCheck() async -> Check {
        let inventory = Self.stateBackupInventory()
        guard let latest = inventory.latest else {
            return Check(
                id: "company-state-backups",
                title: "Company state backups",
                severity: .warn,
                summary: "No state backup manifest found",
                detail: "Create a backup before relying on autonomous company recovery.",
                actions: []
            )
        }

        let integrity = latest.encryptedBackup.map {
            Self.encryptedBundleDoctorIntegrityReport($0)
        } ?? CompanyStateBackupBuilder.verifyManifest(latest.manifest, backupRoot: latest.root)
        let problems = Self.stateBackupProblems(
            latestManifest: latest.manifest,
            integrityReport: integrity,
            now: Date(),
            oldestManifest: inventory.oldest?.manifest,
            staleThresholdHours: inventory.staleThresholdHours,
            unreadableBackupCount: inventory.unreadableCount
        )
        let detailRows = Self.stateBackupDoctorRows(
            latestManifest: latest.manifest,
            oldestManifest: inventory.oldest?.manifest,
            integrityReport: integrity,
            now: Date(),
            staleThresholdHours: inventory.staleThresholdHours,
            unreadableBackupCount: inventory.unreadableCount
        )
        if problems.isEmpty {
            return Check(
                id: "company-state-backups",
                title: "Company state backups",
                severity: .ok,
                summary: "Latest backup is current; oldest retained backup is tracked",
                detail: detailRows.joined(separator: "\n"),
                actions: []
            )
        }

        return Check(
            id: "company-state-backups",
            title: "Company state backups",
            severity: integrity.isPassing ? .warn : .error,
            summary: "Backup needs attention",
            detail: (detailRows + problems).joined(separator: "\n"),
            actions: []
        )
    }

    private func makeDurableStateSchemaCheck() async -> Check {
        let status = CodexSessionManager.shared.durableStateSchemaStatus()
        return Self.durableStateSchemaCheck(status: status)
    }

    nonisolated static func durableStateSchemaCheck(status: CompanySchemaVersionStatus) -> Check {
        let onDisk = status.onDiskVersion.map { "v\($0)" } ?? "missing"
        let expected = "v\(status.expectedVersion)"
        let summary = "On disk \(onDisk), expected \(expected)"
        let detail: String?
        let severity: Severity
        switch status.state {
        case .current:
            severity = .ok
            detail = "Durable session state is compatible with this OS1 build."
        case .missing:
            severity = .warn
            detail = "Durable session state is missing a schema version; run migration before relying on startup recovery."
        case .migrationRequired:
            severity = .warn
            detail = "Durable session state was written by an older OS1 schema and should be migrated before startup uses it."
        case .unsupported:
            severity = .error
            detail = "Durable session state was written by a newer OS1 schema. Upgrade OS1 or restore from a compatible backup."
        case .unreadable:
            severity = .error
            detail = "Durable session state could not be inspected for schema version."
        }
        return Check(
            id: "durable-state-schema",
            title: "Durable state schema",
            severity: severity,
            summary: summary,
            detail: [detail, status.warningCode.map { "warningCode=\($0)" }]
                .compactMap { $0 }
                .joined(separator: "\n"),
            actions: status.requiresMigration ? [.migrateSchema] : []
        )
    }

    private func makeConnectorHealthCheck() async -> Check {
        let reports = CodexSessionManager.shared.sessions.map { session in
            CompanyIntegrationPlanner.healthReport(
                companyID: session.id,
                workflowPlans: CompanyIntegrationPlanner.defaultWorkflowInventory(companyID: session.id)
            )
        }
        let problems = Self.connectorHealthProblems(reports: reports)
        if problems.isEmpty {
            return Check(
                id: "api-first-connectors",
                title: "API-first connectors",
                severity: .ok,
                summary: "No connector auth or rate-limit failures recorded",
                detail: "Browser automation is treated as a high-fragility fallback path.",
                actions: []
            )
        }
        return Check(
            id: "api-first-connectors",
            title: "API-first connectors",
            severity: .warn,
            summary: "Connector issues can block company workflows",
            detail: problems.joined(separator: "\n"),
            actions: []
        )
    }

    nonisolated static func connectorHealthProblems(reports: [CompanyIntegrationHealthReport]) -> [String] {
        reports.flatMap { report -> [String] in
            var problems: [String] = []
            if let blocked = report.blockedReason {
                problems.append("\(report.companyID): \(blocked)")
            }
            if report.hasRateLimitPressure {
                problems.append("\(report.companyID): connector rate limit pressure")
            }
            if !report.browserFallbackWorkflowIDs.isEmpty {
                problems.append(
                    "\(report.companyID): browser fallback workflows \(report.browserFallbackWorkflowIDs.joined(separator: ", "))"
                )
            }
            return problems
        }.sorted()
    }

    private func makeProductionGatesCheck() async -> Check {
        let docURL = Self.productionOperatingModelURL()
        guard let document = try? String(contentsOf: docURL, encoding: .utf8) else {
            return Check(
                id: "production-gates",
                title: L10n.string("Production gates"),
                severity: .warn,
                summary: L10n.string("Missing production operating model"),
                detail: L10n.string("Create docs/production-operating-model.md before live autonomy."),
                actions: []
            )
        }

        let missing = Self.productionOperatingModelMissingSections(in: document)
        if missing.isEmpty {
            return Check(
                id: "production-gates",
                title: L10n.string("Production gates"),
                severity: .ok,
                summary: L10n.string("Production operating model configured"),
                detail: L10n.string("docs/production-operating-model.md maps autonomy, risk tiers, approvals, live checklist, emergency stop, and non-autonomous areas."),
                actions: []
            )
        }

        return Check(
            id: "production-gates",
            title: L10n.string("Production gates"),
            severity: .warn,
            summary: L10n.string("Missing required sections: %@", missing.joined(separator: ", ")),
            detail: docURL.path,
            actions: []
        )
    }

    nonisolated static func productionOperatingModelMissingSections(in document: String) -> [String] {
        let required = [
            "Version:",
            "## Autonomy Levels",
            "## Risk Tiers",
            "## Tool / Action Approval Matrix",
            "## Sandbox to Live Revenue Checklist",
            "## Emergency Stop",
            "## Non-Autonomous Areas",
            "## GitHub / Release Linkage",
        ]
        return required.filter { !document.contains($0) }
    }

    private func makeDataGovernanceCheck() async -> Check {
        let docURL = Self.dataGovernanceURL()
        guard let document = try? String(contentsOf: docURL, encoding: .utf8) else {
            return Check(
                id: "data-governance",
                title: "Data governance",
                severity: .warn,
                summary: "Missing data governance configuration",
                detail: """
                Create docs/data-governance.md with categories, retention, deletion, prompt redaction, and breach \
                response.
                """,
                actions: []
            )
        }

        let missing = Self.dataGovernanceMissingSections(in: document)
        if missing.isEmpty {
            return Check(
                id: "data-governance",
                title: "Data governance",
                severity: .ok,
                summary: "Retention, deletion, prompt redaction, and breach response configured",
                detail: docURL.path,
                actions: []
            )
        }

        return Check(
            id: "data-governance",
            title: "Data governance",
            severity: .warn,
            summary: "Missing required sections: \(missing.joined(separator: ", "))",
            detail: docURL.path,
            actions: []
        )
    }

    nonisolated static func dataGovernanceMissingSections(in document: String) -> [String] {
        let required = [
            "Version:",
            "## Data Categories",
            "## Retention Policies",
            "## Customer Export Workflow",
            "## Customer Deletion Workflow",
            "## Prompt Redaction Rules",
            "## Breach Response Checklist",
            "## Doctor Configuration",
        ]
        return required.filter { !document.contains($0) }
    }

    private nonisolated static func productionOperatingModelURL() -> URL {
        repositoryFileURL("docs/production-operating-model.md")
    }

    private func makeEvaluationHarnessCheck() async -> Check {
        let reportURL = Self.evaluationReportURL()
        guard let summary = Self.evaluationReportSummary(at: reportURL) else {
            return Check(
                id: "evaluation-harness",
                title: L10n.string("Agent eval harness"),
                severity: .warn,
                summary: L10n.string("No non-live eval report found"),
                detail: L10n.string("Run `make evals` to create artifacts/evals/non-live-report.json. CI runs this on every PR and uploads the report artifact."),
                actions: []
            )
        }

        return Check(
            id: "evaluation-harness",
            title: L10n.string("Agent eval harness"),
            severity: summary.passed ? .ok : .error,
            summary: L10n.string(
                "Eval suite %@: %lld/%lld passed, score %.1f",
                summary.suite,
                summary.passedCount,
                summary.totalCount,
                summary.averageScore
            ),
            detail: reportURL.path,
            actions: []
        )
    }

    struct EvaluationReportSummary: Decodable, Equatable {
        let suite: String
        let passed: Bool
        let passedCount: Int
        let totalCount: Int
        let averageScore: Double
    }

    nonisolated static func evaluationReportSummary(at url: URL) -> EvaluationReportSummary? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(EvaluationReportSummary.self, from: data)
    }

    private nonisolated static func evaluationReportURL() -> URL {
        repositoryFileURL("artifacts/evals/non-live-report.json")
    }

    private nonisolated static func dataGovernanceURL() -> URL {
        repositoryFileURL("docs/data-governance.md")
    }

    nonisolated static func stateBackupProblems(
        latestManifest: CompanyStateBackupManifest?,
        integrityReport: CompanyBackupIntegrityReport?,
        now: Date,
        oldestManifest: CompanyStateBackupManifest? = nil,
        staleThresholdHours: Int? = nil,
        unreadableBackupCount: Int = 0
    ) -> [String] {
        guard let latestManifest else { return ["No state backup manifest found."] }
        var problems: [String] = []
        let ageHours = now.timeIntervalSince(latestManifest.createdAt) / 3_600
        let threshold = staleThresholdHours ?? latestManifest.recoveryPointObjectiveHours
        if ageHours > Double(threshold) {
            problems.append(
                "Latest successful backup is \(Int(ageHours))h old; stale threshold is \(threshold)h."
            )
        }
        if let oldestManifest {
            let retentionHours = oldestManifest.createdAt.timeIntervalSince(latestManifest.createdAt) / 3_600
            if retentionHours > Double(latestManifest.retentionDays * 24) {
                problems.append("Oldest retained backup exceeds retention policy of \(latestManifest.retentionDays)d.")
            }
        }
        if unreadableBackupCount > 0 {
            problems.append("\(unreadableBackupCount) backup bundle(s) could not be decoded or failed manifest-hash validation.")
        }
        guard let integrityReport else {
            problems.append("Backup integrity has not been checked.")
            return problems
        }
        if let mismatch = integrityReport.manifestHashMismatch {
            problems.append("Manifest hash mismatch: \(mismatch).")
        }
        if !integrityReport.missingPaths.isEmpty {
            problems.append("Missing backup paths: \(integrityReport.missingPaths.joined(separator: ", ")).")
        }
        if !integrityReport.checksumMismatches.isEmpty {
            problems.append(
                "Checksum mismatches: \(integrityReport.checksumMismatches.joined(separator: ", "))."
            )
        }
        return problems
    }

    nonisolated static func stateBackupDoctorRows(
        latestManifest: CompanyStateBackupManifest,
        oldestManifest: CompanyStateBackupManifest?,
        integrityReport: CompanyBackupIntegrityReport?,
        now: Date,
        staleThresholdHours: Int,
        unreadableBackupCount: Int = 0
    ) -> [String] {
        let latestAge = Int(now.timeIntervalSince(latestManifest.createdAt) / 3_600)
        let oldest = oldestManifest ?? latestManifest
        let oldestAge = Int(now.timeIntervalSince(oldest.createdAt) / 3_600)
        let integrity = integrityReport?.isPassing == true ? "passed" : "needs attention"
        return [
            "Last successful backup age: \(latestAge)h (threshold \(staleThresholdHours)h)",
            "Oldest backup age: \(oldestAge)h",
            "Latest backup ID: \(latestManifest.backupID)",
            "Integrity: \(integrity); unreadable bundles: \(unreadableBackupCount)",
        ]
    }

    private nonisolated static func encryptedBundleDoctorIntegrityReport(
        _ backup: CompanyEncryptedStateBackup,
        checkedAt: Date = Date()
    ) -> CompanyBackupIntegrityReport {
        if let mismatch = CompanyStateBackupBuilder.manifestHashMismatch(in: backup) {
            return CompanyBackupIntegrityReport(
                status: .failed,
                checkedAt: checkedAt,
                verifiedEntryCount: 0,
                missingPaths: [],
                checksumMismatches: [],
                manifestHashMismatch: mismatch
            )
        }
        return CompanyBackupIntegrityReport(
            status: .passed,
            checkedAt: checkedAt,
            verifiedEntryCount: backup.manifest.entries.count,
            missingPaths: [],
            checksumMismatches: [],
            manifestHashMismatch: nil
        )
    }

    struct StateBackupInventory: Equatable, Sendable {
        struct Item: Equatable, Sendable {
            let manifest: CompanyStateBackupManifest
            let root: URL
            let encryptedBackup: CompanyEncryptedStateBackup?
        }

        let latest: Item?
        let oldest: Item?
        let staleThresholdHours: Int
        let unreadableCount: Int
    }

    nonisolated static func configuredStateBackupStaleThresholdHours(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int? {
        environment["OS1_BACKUP_STALE_THRESHOLD_HOURS"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil }
    }

    private nonisolated static func stateBackupInventory(
        root: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".os1/codex-tasks/backups", isDirectory: true)
    ) -> StateBackupInventory {
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return StateBackupInventory(
                latest: nil,
                oldest: nil,
                staleThresholdHours: configuredStateBackupStaleThresholdHours() ?? 24,
                unreadableCount: 0
            )
        }

        let decoder = CompanyStateBackupCodec.decoder()
        var unreadable = 0
        let items = children
            .compactMap { backupRoot -> StateBackupInventory.Item? in
                if let bundleData = try? Data(contentsOf: backupRoot.appendingPathComponent(CompanyEncryptedBackupBundleStore.bundleFilename)),
                   let bundle = try? decoder.decode(CompanyEncryptedStateBackup.self, from: bundleData),
                   (try? CompanyStateBackupBuilder.validateEncryptedBackupBundle(bundle)) != nil {
                    return StateBackupInventory.Item(manifest: bundle.manifest, root: backupRoot, encryptedBackup: bundle)
                }
                let manifestURL = backupRoot.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestURL),
                      let manifest = try? decoder.decode(CompanyStateBackupManifest.self, from: data)
                else {
                    unreadable += 1
                    return nil
                }
                return StateBackupInventory.Item(manifest: manifest, root: backupRoot, encryptedBackup: nil)
            }
            .sorted { $0.manifest.createdAt > $1.manifest.createdAt }
        let latest = items.first
        let threshold = configuredStateBackupStaleThresholdHours() ?? latest?.manifest.recoveryPointObjectiveHours ?? 24
        return StateBackupInventory(
            latest: latest,
            oldest: items.last,
            staleThresholdHours: threshold,
            unreadableCount: unreadable
        )
    }

    /// Reports whether the built OS1.app bundle is Developer-ID-signed +
    /// notarized + stapled. Matters when distributing to anyone other than
    /// yourself — without notarization, fresh Macs show "unidentified
    /// developer" Gatekeeper warnings.
    private func makeNotarizationCheck() async -> Check {
        let appPath = Self.repositoryFileURL("dist/OS1.app").path
        guard FileManager.default.fileExists(atPath: appPath) else {
            return Check(
                id: "notarization",
                title: "App bundle signing",
                severity: .unknown,
                summary: L10n.string("dist/OS1.app not built yet"),
                detail: L10n.string("Run scripts/build-macos-app.sh to produce a bundle. Then this check will report its signing + notarization state."),
                actions: []
            )
        }
        let codesignOut = await runWithTimeout(
            executable: "/usr/bin/codesign",
            args: ["-dv", "--verbose=2", appPath],
            timeoutSec: 4
        ) ?? ""
        let isAdhoc = codesignOut.contains("Signature=adhoc")
        let hardenedRuntime = codesignOut.contains("flags=0x10000(runtime)") || codesignOut.contains("hardened")

        let spctlOut = await runWithTimeout(
            executable: "/usr/sbin/spctl",
            args: ["--assess", "--type", "execute", "-vv", appPath],
            timeoutSec: 4
        ) ?? ""
        let notarized = spctlOut.contains("source=Notarized Developer ID")
        let stapleOut = await runWithTimeout(
            executable: "/usr/bin/xcrun",
            args: ["stapler", "validate", appPath],
            timeoutSec: 4
        ) ?? ""
        let stapled = stapleOut.contains("worked")

        if notarized && stapled {
            return Check(
                id: "notarization",
                title: "App bundle signing",
                severity: .ok,
                summary: L10n.string("Notarized + stapled, hardened runtime"),
                detail: codesignOut.prefix(400) + "\n---\n" + spctlOut.prefix(200),
                actions: []
            )
        }
        if isAdhoc {
            return Check(
                id: "notarization",
                title: "App bundle signing",
                severity: .warn,
                summary: L10n.string("Ad-hoc signed only — fine for local dev, not shippable"),
                detail: L10n.string("To ship: set OS1_CODESIGN_IDENTITY to a Developer ID Application cert and re-run scripts/build-macos-app.sh, then run scripts/notarize.sh. See the script header for the one-time `xcrun notarytool store-credentials` setup."),
                actions: []
            )
        }
        return Check(
            id: "notarization",
            title: "App bundle signing",
            severity: .warn,
            summary: L10n.string("Signed but not notarized"),
            detail: L10n.string("Hardened runtime: %@. Notarized: %@. Stapled: %@. Run scripts/notarize.sh to complete the chain.",
                                hardenedRuntime ? "yes" : "no",
                                notarized ? "yes" : "no",
                                stapled ? "yes" : "no"),
            actions: []
        )
    }

    private func makeBinaryCheck(id: String, title: String, binary: String, versionArgs: [String]) async -> Check {
        let path = which(binary)
        guard let path else {
            return Check(
                id: id,
                title: title,
                severity: .warn,
                summary: L10n.string("Not installed or not on PATH."),
                detail: L10n.string("OS1 looked for `%@` on PATH but didn't find it. Install it before agentic features that depend on it will work.", binary),
                actions: []
            )
        }
        let version = await runWithTimeout(executable: path, args: versionArgs, timeoutSec: 4) ?? ""
        let short = version.components(separatedBy: .newlines).first?.trimmingCharacters(in: .whitespaces) ?? "(no version output)"
        return Check(
            id: id,
            title: title,
            severity: .ok,
            summary: short,
            detail: "\(path)\n\n\(version.prefix(400))",
            actions: []
        )
    }

    private func makeWUPHFCheck() async -> Check {
        guard let url = URL(string: "http://127.0.0.1:7891/api/stripe/status") else {
            return Check(id: "wuphf", title: "WUPHF office", severity: .warn, summary: "Bad URL", detail: nil, actions: [])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                let status = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
                let secretConfigured = (status["webhook_secret_configured"] as? Bool) == true
                return Check(
                    id: "wuphf",
                    title: "WUPHF office",
                    severity: .ok,
                    summary: secretConfigured
                        ? "Proxy routing Stripe status on :7891"
                        : "Proxy routing Stripe status on :7891; webhook secret missing",
                    detail: "http://127.0.0.1:7891/api/stripe/status returned 200. The WUPHF proxy is routing OS1 payment endpoints.",
                    actions: []
                )
            }
            return Check(
                id: "wuphf",
                title: "WUPHF office",
                severity: .error,
                summary: code == 404 ? "Stripe proxy route missing on :7891" : "Unexpected HTTP \(code) from Stripe status route",
                detail: "Doctor reached :7891, but /api/stripe/status did not return 200. "
                    + "Raw WUPHF or an old LaunchAgent may be bound to the public port; "
                    + "run make install or reinstall the LaunchAgent.",
                actions: [.reinstallLaunchAgents]
            )
        } catch {
            return Check(
                id: "wuphf",
                title: "WUPHF office",
                severity: .warn,
                summary: L10n.string("Not reachable on :7891"),
                detail: L10n.string(
                    "Run `make install` from the OS1 checkout to render and load the WUPHF proxy LaunchAgent. Error: %@",
                    error.localizedDescription
                ),
                actions: [.reinstallLaunchAgents]
            )
        }
    }

    private func makeLaunchdCheck() async -> Check {
        let output = await runWithTimeout(executable: "/bin/launchctl", args: ["list"], timeoutSec: 3) ?? ""
        let labels = Self.launchAgentLabels
        let loaded = labels.filter { output.contains($0) }
        let missing = labels.filter { !output.contains($0) }
        let driftReports = Self.launchAgentDriftReports()
        let driftProblems = driftReports.compactMap(\.problem)
        if missing.isEmpty && driftProblems.isEmpty {
            return Check(
                id: "launchd",
                title: "Launchd plists",
                severity: .ok,
                summary: L10n.string("All %lld OS1 agents loaded", labels.count),
                detail: (loaded + driftReports.map { "\($0.label): \($0.expectedHash)" }).joined(separator: "\n"),
                actions: []
            )
        }
        return Check(
            id: "launchd",
            title: "Launchd plists",
            severity: .warn,
            summary: driftProblems.isEmpty
                ? L10n.string("%lld of %lld OS1 agents loaded", loaded.count, labels.count)
                : L10n.string("%lld of %lld OS1 agents loaded; %lld plist(s) need reinstall", loaded.count, labels.count, driftProblems.count),
            detail: [
                "Loaded: \(loaded.joined(separator: ", "))",
                "Missing: \(missing.joined(separator: ", "))",
                driftProblems.joined(separator: "\n"),
                "Run `make install` or click Reinstall LaunchAgent to render and reload the current templates."
            ].joined(separator: "\n\n"),
            actions: [.reinstallLaunchAgents]
        )
    }

    private func makeVoicePortCheck() async -> Check {
        let preferredPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".os1")
            .appendingPathComponent(RealtimeVoiceSessionServer.localServerPortFileName)
            .path
        let legacyPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".os1")
            .appendingPathComponent(RealtimeVoiceSessionServer.legacyVoicePortFileName)
            .path
        let path = FileManager.default.fileExists(atPath: preferredPath) ? preferredPath : legacyPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            return Check(
                id: "voice-port",
                title: "Local server port",
                severity: .warn,
                summary: "No ~/.os1/local-server-port or ~/.os1/voice-port file",
                detail: "OS1 writes its local HTTP server TCP port here when it starts. "
                    + "Missing file means local routes such as Stripe webhooks and voice setup are not mounted.",
                actions: []
            )
        }
        let age = Date().timeIntervalSince(mtime)
        let port = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        if age < 300 {
            return Check(
                id: "voice-port",
                title: "Local server port",
                severity: .ok,
                summary: L10n.string("Port %@ (fresh, %.0fs old)", port, age),
                detail: path,
                actions: []
            )
        }
        return Check(
            id: "voice-port",
            title: "Local server port",
            severity: .warn,
            summary: L10n.string("Port %@ (stale, %.0f min old)", port, age / 60),
            detail: "The local HTTP server has not refreshed its port file recently. "
                + "Could be a stale file from a prior OS1 process. Restart OS1 to rewrite it.",
            actions: []
        )
    }

    private func makeKeychainCheck() async -> Check {
        // Probe each service+account pair without reading the value
        // (avoids Mac prompting "Allow OS1 to access Keychain?").
        let entries: [(label: String, service: String, account: String)] = [
            ("Orgo",         "ai.orgo.mac.api-key",       "default"),
            ("ElevenLabs",   "io.elevenlabs.api-key",     "default"),
            ("Composio",     "dev.composio.connect.api-key", "default"),
            ("Telegram bot", "org.telegram.bot-token",    "default"),
        ]
        var present: [String] = []
        var missing: [String] = []
        for entry in entries {
            let found = await runWithTimeout(
                executable: "/usr/bin/security",
                args: ["find-generic-password", "-s", entry.service, "-a", entry.account],
                timeoutSec: 2
            ) != nil
            (found ? present.append(entry.label) : missing.append(entry.label))
        }
        if missing.isEmpty {
            return Check(
                id: "keychain",
                title: "Keychain credentials",
                severity: .ok,
                summary: L10n.string("All %lld credentials present", entries.count),
                detail: present.joined(separator: ", "),
                actions: []
            )
        }
        return Check(
            id: "keychain",
            title: "Keychain credentials",
            severity: .warn,
            summary: L10n.string("Missing: %@", missing.joined(separator: ", ")),
            detail: L10n.string("Save missing ones via the Providers / Connectors tabs, or `security add-generic-password -s <service> -a default -w <secret>`."),
            actions: []
        )
    }

    private func makeSharedCredentialScopeCheck() async -> Check {
        let credentialNames = CodexSessionManager.loadCredentialNames()
        let unsafe = Self.sharedProductionCredentialProblems(
            credentialNames: credentialNames,
            sessions: CodexSessionManager.shared.sessions
        )
        if unsafe.isEmpty {
            return Check(
                id: "company-credential-scopes",
                title: "Company credential scopes",
                severity: .ok,
                summary: "No overbroad company credential grants detected",
                detail: credentialNames.isEmpty ? "No ~/.os1/credentials.env credentials loaded." : "Loaded credential names: \(credentialNames.joined(separator: ", "))",
                actions: []
            )
        }
        return Check(
            id: "company-credential-scopes",
            title: "Company credential scopes",
            severity: .warn,
            summary: "Shared production credentials are unsafe",
            detail: unsafe.joined(separator: "\n"),
            actions: []
        )
    }

    nonisolated static func sharedProductionCredentialProblems(
        credentialNames: [String],
        sessions: [CodexSession]
    ) -> [String] {
        let names = Set(credentialNames.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        guard !names.isEmpty else { return [] }

        return sessions.compactMap { session in
            if session.sandboxMode == .localDevelopment {
                return "\(session.title) uses localDevelopment and can read all shared credentials."
            }
            let allowlist = Set(session.credentialAllowlist)
            if !allowlist.isEmpty && names.isSubset(of: allowlist) {
                return "\(session.title) is granted every shared credential: \(credentialNames.sorted().joined(separator: ", "))."
            }
            return nil
        }
    }

    nonisolated static func codexHeartbeatSandboxRuntime(
        sandboxExecIsExecutable: Bool,
        launchPlan: CodexHeartbeatLaunchPlan
    ) -> CodexHeartbeatSandboxRuntime {
        let isOn = sandboxExecIsExecutable
            && launchPlan.usesMacOSSandbox
            && launchPlan.executablePath == "/usr/bin/sandbox-exec"
            && launchPlan.arguments.contains("-f")
            && launchPlan.sandboxProfilePath != nil
        if isOn {
            return CodexHeartbeatSandboxRuntime(
                isOn: true,
                title: "Codex heartbeat sandbox: ON",
                summary: "macOS sandbox-exec wraps sandbox-mode heartbeats",
                detail: "OS1 generates a per-company sandbox profile and launches Codex through "
                    + "/usr/bin/sandbox-exec. Codex still receives its internal bypass flag inside that OS sandbox "
                    + "so the heartbeat can run unattended without per-command prompts."
            )
        }

        return CodexHeartbeatSandboxRuntime(
            isOn: false,
            title: "Codex heartbeat sandbox: OFF",
            summary: "Heartbeat launch plan is not wrapped by macOS sandbox-exec",
            detail: "Do not run revenue companies in this mode. The Codex process can read and write outside "
                + "the company worktree unless an operator explicitly treats it as local-development only."
        )
    }

    nonisolated static let launchAgentLabels = [
        "com.os1.wuphf",
        "com.os1.app",
        "com.os1.samantha-bot",
        "com.os1.coo"
    ]

    nonisolated static func renderLaunchAgentTemplate(
        _ template: String,
        repoRoot: String,
        home: String,
        path: String
    ) -> String {
        template
            .replacingOccurrences(of: "__OS1_REPO_ROOT__", with: repoRoot)
            .replacingOccurrences(of: "__OS1_HOME__", with: home)
            .replacingOccurrences(of: "__OS1_PATH__", with: path)
    }

    nonisolated static func stableLaunchAgentHash(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    nonisolated static func launchAgentDriftReports(
        repoRoot: URL? = nil,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        installedDirectory: URL? = nil
    ) -> [LaunchAgentDriftReport] {
        guard let repoRoot = repoRoot ?? launchAgentRepoRoot() else {
            return [LaunchAgentDriftReport(
                label: "launchd",
                installedPath: "",
                expectedHash: "",
                installedHash: nil,
                problem: "Could not find OS1 repo root for LaunchAgent template comparison"
            )]
        }
        let templateDirectory = repoRoot.appendingPathComponent("launchd", isDirectory: true)
        let installedDirectory = installedDirectory ?? home
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
        let path = defaultLaunchAgentPath(home: home)
        let templates = (try? FileManager.default.contentsOfDirectory(
            at: templateDirectory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ))?
            .filter { $0.lastPathComponent.hasPrefix("com.os1.") && $0.lastPathComponent.hasSuffix(".plist.template") }
            .sorted { $0.lastPathComponent < $1.lastPathComponent } ?? []

        return templates.map { templateURL in
            let baseName = String(templateURL.lastPathComponent.dropLast(".template".count))
            let label = String(baseName.dropLast(".plist".count))
            let installedURL = installedDirectory.appendingPathComponent(baseName)
            let template = (try? String(contentsOf: templateURL, encoding: .utf8)) ?? ""
            let expected = renderLaunchAgentTemplate(
                template,
                repoRoot: repoRoot.path,
                home: home.path,
                path: path
            )
            let expectedHash = stableLaunchAgentHash(expected)
            guard let installed = try? String(contentsOf: installedURL, encoding: .utf8) else {
                return LaunchAgentDriftReport(
                    label: label,
                    installedPath: installedURL.path,
                    expectedHash: expectedHash,
                    installedHash: nil,
                    problem: "\(label): missing installed plist at \(installedURL.path) (expected \(expectedHash))"
                )
            }
            let installedHash = stableLaunchAgentHash(installed)
            return LaunchAgentDriftReport(
                label: label,
                installedPath: installedURL.path,
                expectedHash: expectedHash,
                installedHash: installedHash,
                problem: installed == expected
                    ? nil
                    : "\(label): installed plist out of date at \(installedURL.path) "
                        + "(installed \(installedHash), expected \(expectedHash))"
            )
        }
    }

    private nonisolated static func defaultLaunchAgentPath(home: URL) -> String {
        [
            "/opt/homebrew/bin",
            home.appendingPathComponent(".local/bin").path,
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ].joined(separator: ":")
    }

    private nonisolated static func launchAgentRepoRoot() -> URL? {
        var candidates: [URL] = []
        if let env = ProcessInfo.processInfo.environment["OS1_REPO_ROOT"], !env.isEmpty {
            candidates.append(URL(fileURLWithPath: env, isDirectory: true))
        }
        candidates.append(URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true))
        var bundleURL = Bundle.main.bundleURL
        for _ in 0..<5 {
            candidates.append(bundleURL)
            bundleURL.deleteLastPathComponent()
        }
        return candidates.first { candidate in
            FileManager.default.fileExists(atPath: candidate.appendingPathComponent("launchd", isDirectory: true).path)
        }
    }

    private nonisolated static func repositoryFileURL(_ relativePath: String) -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let cwdURL = cwd.appendingPathComponent(relativePath)
        if FileManager.default.fileExists(atPath: cwdURL.path) {
            return cwdURL
        }
        if let repoRoot = launchAgentRepoRoot() {
            return repoRoot.appendingPathComponent(relativePath)
        }
        return cwdURL
    }

    private func which(_ binary: String) -> String? {
        let env = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/local/bin:/usr/bin:/bin:/opt/homebrew/bin"
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", NSString(string: "~/.local/bin").expandingTildeInPath]
        let dirs = (extra + env.split(separator: ":").map(String.init))
        for d in dirs {
            let path = (d as NSString).appendingPathComponent(binary)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// Run a subprocess synchronously with a hard timeout. Returns combined
    /// stdout/stderr on exit 0, nil otherwise. Never throws — Doctor checks
    /// should always produce a row, even when the underlying call dies.
    private func runWithTimeout(executable: String, args: [String], timeoutSec: Double) async -> String? {
        await withCheckedContinuation { (cont: CheckedContinuation<String?, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let proc = Process()
                proc.executableURL = URL(fileURLWithPath: executable)
                proc.arguments = args
                let pipe = Pipe()
                proc.standardOutput = pipe
                proc.standardError = pipe
                do { try proc.run() } catch { cont.resume(returning: nil); return }
                let killer = DispatchWorkItem {
                    if proc.isRunning { proc.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSec, execute: killer)
                proc.waitUntilExit()
                killer.cancel()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let out = String(data: data, encoding: .utf8)
                cont.resume(returning: proc.terminationStatus == 0 ? out : nil)
            }
        }
    }

    // MARK: - Actions

    func runAction(_ action: Action) async {
        guard actionInFlight == nil else { return }
        switch action {
        case .reinstallLaunchAgents:
            actionInFlight = action
            actionError = nil
            defer { actionInFlight = nil }
            await reinstallLaunchAgents()
            await refresh()
            return
        case .openLogs(let path):
            openLogs(at: path)
            return
        case .retryCheck(let id):
            await retryCheck(id: id)
            return
        case .migrateSchema:
            actionInFlight = action
            actionError = nil
            defer { actionInFlight = nil }
            do {
                _ = try CodexSessionManager.shared.migrateDurableStateIfNeeded()
            } catch {
                actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            await refresh()
            return
        case .restartGateway, .revalidateTelegram, .updateHermes:
            break
        }
        guard let connection = currentConnection else {
            actionError = L10n.string("No host selected.")
            return
        }
        actionInFlight = action
        actionError = nil
        defer { actionInFlight = nil }

        switch action {
        case .restartGateway:
            await restartGateway(on: connection)
        case .revalidateTelegram:
            await revalidateTelegramToken()
        case .updateHermes:
            await performHermesUpdateBridge()
        case .reinstallLaunchAgents, .migrateSchema, .retryCheck, .openLogs:
            break
        }
        // Always refresh after an action so the user sees the new state.
        await refresh()
    }

    private func retryCheck(id: String) async {
        guard let definition = currentDefinitions[id] else {
            await refresh()
            return
        }
        actionInFlight = .retryCheck(id)
        actionError = nil
        defer { actionInFlight = nil }

        updateCheck(
            id: id,
            with: Check.pending(
                id: definition.id,
                title: definition.title,
                timeoutSeconds: definition.timeoutSeconds,
                logPath: definition.logPath
            ).replacing(
                state: .running,
                summary: L10n.string("Running…")
            )
        )
        let runID = currentRunID ?? UUID().uuidString
        let resolved = await Self.executeCheckDefinition(definition)
        updateCheck(id: id, with: resolved.check)
        CodexSessionManager.shared.recordDoctorCheckEvent(
            runID: runID,
            checkName: resolved.check.title,
            checkID: resolved.check.id,
            startedAt: resolved.startedAt,
            endedAt: resolved.endedAt,
            outcome: resolved.check.state.rawValue,
            latencyMS: resolved.latencyMS,
            error: resolved.errorMessage
        )
    }

    private func openLogs(at path: String) {
        let url = URL(fileURLWithPath: path)
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(url.deletingLastPathComponent())
        }
    }

    private func restartGateway(on connection: ConnectionProfile) async {
        guard let token = credentialStore.loadToken(forProfileId: currentProfileId) else {
            actionError = L10n.string("No Telegram token configured. Paste one on the Messaging tab first.")
            return
        }
        do {
            let result = try await telegramInstaller.install(
                on: connection,
                token: token,
                allowedUsers: nil
            )
            if !result.success {
                actionError = result.errors.isEmpty
                    ? L10n.string("Restart failed.")
                    : result.errors.joined(separator: "\n")
            }
        } catch {
            actionError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func revalidateTelegramToken() async {
        guard let token = credentialStore.loadToken(forProfileId: currentProfileId) else {
            actionError = L10n.string("No Telegram token configured. Paste one on the Messaging tab first.")
            return
        }
        do {
            _ = try await telegramAPI.getMe(token: token)
        } catch let error as TelegramAPIError {
            actionError = error.errorDescription
        } catch {
            actionError = error.localizedDescription
        }
    }

    private func reinstallLaunchAgents() async {
        guard let repoRoot = Self.launchAgentRepoRoot() else {
            actionError = "Could not find OS1 repo root for LaunchAgent reinstall."
            return
        }
        let script = repoRoot.appendingPathComponent("scripts/install-launch-agents.sh").path
        guard FileManager.default.isExecutableFile(atPath: script) else {
            actionError = "LaunchAgent installer is not executable at \(script)."
            return
        }
        guard let output = await runWithTimeout(executable: script, args: ["--reload"], timeoutSec: 30) else {
            actionError = "LaunchAgent reinstall failed or timed out. Run `make install` from \(repoRoot.path) for full output."
            return
        }
        if !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            actionError = nil
        }
    }

    // MARK: - Check builders

    private func makeGatewayCheck(
        result: TelegramVMResult,
        snapshot: GatewayStateSnapshot?
    ) -> Check {
        let logTail = result.gateway_log_tail
        let actions: [Action] = [.restartGateway]

        // Prefer the live state file when present — it's the most
        // accurate signal. Fall back to the text-based status output.
        if let snapshot {
            if snapshot.isRunning {
                let connected = snapshot.allPlatformsConnected
                if connected == true {
                    let count = snapshot.platforms?.count ?? 0
                    return Check(
                        id: "gateway",
                        title: L10n.string("Hermes gateway"),
                        severity: .ok,
                        summary: L10n.string(count == 1
                            ? "Running, 1 platform connected."
                            : "Running, all platforms connected."),
                        detail: logTail,
                        actions: actions
                    )
                }
                // Running but at least one platform isn't connected.
                let problems = (snapshot.platforms ?? [:])
                    .filter { !$0.value.isConnected }
                    .map { "\($0.key): \($0.value.state ?? "unknown")\($0.value.error_message.map { " (\($0))" } ?? "")" }
                    .sorted()
                return Check(
                    id: "gateway",
                    title: L10n.string("Hermes gateway"),
                    severity: .warn,
                    summary: L10n.string("Running, but some platforms aren't connected."),
                    detail: problems.joined(separator: "\n") + (logTail.map { "\n\n\($0)" } ?? ""),
                    actions: actions
                )
            }
            // Snapshot present but not running.
            return Check(
                id: "gateway",
                title: L10n.string("Hermes gateway"),
                severity: .error,
                summary: L10n.string("Not running.") + " " + L10n.string("Click Restart gateway to bring it up."),
                detail: logTail,
                actions: actions
            )
        }

        // No snapshot → fall back to text-based status.
        if result.isGatewayOnline {
            return Check(
                id: "gateway",
                title: L10n.string("Hermes gateway"),
                severity: .ok,
                summary: L10n.string("Running."),
                detail: logTail,
                actions: actions
            )
        }
        if let status = result.gateway_status, !status.isEmpty {
            return Check(
                id: "gateway",
                title: L10n.string("Hermes gateway"),
                severity: .error,
                summary: L10n.string("Not running.") + " " + L10n.string("Click Restart gateway to bring it up."),
                detail: [status, logTail].compactMap { $0 }.joined(separator: "\n\n"),
                actions: actions
            )
        }
        return Check(
            id: "gateway",
            title: L10n.string("Hermes gateway"),
            severity: .unknown,
            summary: L10n.string("Couldn't determine gateway state."),
            detail: logTail,
            actions: actions
        )
    }

    private func makeTelegramCheck(snapshot: GatewayStateSnapshot?) async -> Check {
        let actions: [Action] = [.revalidateTelegram]

        guard let token = credentialStore.loadToken(forProfileId: currentProfileId) else {
            return Check(
                id: "telegram",
                title: L10n.string("Telegram bot"),
                severity: .warn,
                summary: L10n.string("No token configured."),
                detail: L10n.string("Paste a bot token on the Messaging tab to enable Telegram."),
                actions: []
            )
        }

        // Validate the token against api.telegram.org. This is the
        // ground truth for "is the token still good."
        let bot: TelegramBotInfo
        do {
            bot = try await telegramAPI.getMe(token: token)
        } catch let error as TelegramAPIError {
            // 401-style rejection → token-revoked path.
            switch error {
            case .invalidToken, .revokedToken:
                return Check(
                    id: "telegram",
                    title: L10n.string("Telegram bot"),
                    severity: .error,
                    summary: L10n.string("Token rejected by Telegram."),
                    detail: L10n.string("Regenerate via BotFather and paste the new token on the Messaging tab.") +
                        "\n\n" + (error.errorDescription ?? ""),
                    actions: actions
                )
            default:
                return Check(
                    id: "telegram",
                    title: L10n.string("Telegram bot"),
                    severity: .warn,
                    summary: L10n.string("Couldn't reach api.telegram.org."),
                    detail: error.errorDescription,
                    actions: actions
                )
            }
        } catch {
            return Check(
                id: "telegram",
                title: L10n.string("Telegram bot"),
                severity: .warn,
                summary: L10n.string("Couldn't reach api.telegram.org."),
                detail: error.localizedDescription,
                actions: actions
            )
        }

        // Token validates. Now reconcile with what the gateway thinks.
        let gatewayPlatform = snapshot?.platform("telegram")
        let summaryOk = bot.displayHandle

        if let platform = gatewayPlatform {
            if platform.isConnected {
                return Check(
                    id: "telegram",
                    title: L10n.string("Telegram bot"),
                    severity: .ok,
                    summary: summaryOk + " " + L10n.string("is online."),
                    detail: nil,
                    actions: actions
                )
            }
            if platform.isConnecting {
                return Check(
                    id: "telegram",
                    title: L10n.string("Telegram bot"),
                    severity: .warn,
                    summary: L10n.string("Token valid; gateway is still connecting."),
                    detail: platform.error_message,
                    actions: actions
                )
            }
            return Check(
                id: "telegram",
                title: L10n.string("Telegram bot"),
                severity: .warn,
                summary: L10n.string("Token valid; gateway can't connect."),
                detail: platform.error_message ?? L10n.string("State: ") + (platform.state ?? "unknown"),
                actions: actions
            )
        }

        // Token valid but no gateway snapshot — gateway probably down.
        return Check(
            id: "telegram",
            title: L10n.string("Telegram bot"),
            severity: .warn,
            summary: L10n.string("Token valid; gateway not running."),
            detail: L10n.string("Click Restart gateway above to bring it online."),
            actions: actions
        )
    }

    private func probeHermesAvailability(on connection: ConnectionProfile) async -> HermesUpdateAvailability {
        do {
            let result = try await hermesUpdater.checkAvailability(on: connection)
            return .make(from: result, fallbackLabel: L10n.string("Hermes Agent"))
        } catch {
            return .unknown
        }
    }

    private func makeHermesCheck(availability: HermesUpdateAvailability) -> Check {
        switch availability {
        case .unknown:
            return Check(
                id: "hermes-version",
                title: L10n.string("Hermes version"),
                severity: .unknown,
                summary: L10n.string("Couldn't determine version."),
                detail: nil,
                actions: []
            )
        case .notInstalled:
            return Check(
                id: "hermes-version",
                title: L10n.string("Hermes version"),
                severity: .warn,
                summary: L10n.string("Hermes isn't installed on this host."),
                detail: L10n.string("Install Hermes Agent from the Overview tab first."),
                actions: []
            )
        case .upToDate(let versionLabel):
            return Check(
                id: "hermes-version",
                title: L10n.string("Hermes version"),
                severity: .ok,
                summary: versionLabel,
                detail: L10n.string("Up to date with origin/main."),
                actions: [.updateHermes]
            )
        case .behind(let versionLabel, let offer):
            let summary: String
            if let commits = offer.commits, commits > 0 {
                summary = String(
                    format: L10n.string(commits == 1
                        ? "%@ — %d commit behind main."
                        : "%@ — %d commits behind main."),
                    versionLabel,
                    commits
                )
            } else {
                summary = String(
                    format: L10n.string("%@ — update available."),
                    versionLabel
                )
            }
            return Check(
                id: "hermes-version",
                title: L10n.string("Hermes version"),
                severity: .warn,
                summary: summary,
                detail: L10n.string("Click Update to run hermes update --backup. The gateway restarts automatically."),
                actions: [.updateHermes]
            )
        }
    }
}
