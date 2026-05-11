import Foundation
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
    }

    struct Check: Identifiable, Equatable, Sendable {
        let id: String
        let title: String
        let severity: Severity
        let summary: String
        let detail: String?
        let actions: [Action]
    }

    @Published private(set) var checks: [Check] = []
    @Published private(set) var isRefreshing = false
    @Published private(set) var actionInFlight: Action?
    @Published var actionError: String?
    @Published private(set) var lastRefreshedAt: Date?

    private let credentialStore: TelegramCredentialStore
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

    init(
        credentialStore: TelegramCredentialStore,
        telegramAPI: TelegramAPIClient = TelegramAPIClient(),
        telegramInstaller: TelegramVMInstaller,
        hermesUpdater: HermesUpdater
    ) {
        self.credentialStore = credentialStore
        self.telegramAPI = telegramAPI
        self.telegramInstaller = telegramInstaller
        self.hermesUpdater = hermesUpdater
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
        isRefreshing = true
        defer { isRefreshing = false }
        actionError = nil

        // Local stack checks always run — they don't depend on a host
        // being selected. These cover the moving parts that historically
        // failed silently (codex auth, claude CLI, WUPHF, launchd plists,
        // keychain credentials, voice-port freshness).
        let localChecks = await makeLocalStackChecks()

        guard let connection = currentConnection else {
            checks = localChecks + [Check(
                id: "no-connection",
                title: L10n.string("No host selected"),
                severity: .unknown,
                summary: L10n.string("Pick a host on the Host tab to run host-level checks (gateway, Hermes, Telegram)."),
                detail: nil,
                actions: []
            )]
            lastRefreshedAt = Date()
            return
        }

        // Probe the host. If this fails, host-level checks are moot — but
        // local stack checks still matter (in fact more so, because a
        // local stack issue may be the reason the host is unreachable).
        let statusResult: TelegramVMResult
        do {
            statusResult = try await telegramInstaller.checkStatus(on: connection)
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            checks = localChecks + [Check(
                id: "host-unreachable",
                title: L10n.string("Host unreachable"),
                severity: .error,
                summary: L10n.string("Couldn't reach this host to run health checks."),
                detail: message,
                actions: []
            )]
            lastRefreshedAt = Date()
            return
        }

        let snapshot = GatewayStateSnapshot.decode(from: statusResult.gateway_state_json)
        let gatewayCheck = makeGatewayCheck(result: statusResult, snapshot: snapshot)
        let telegramCheck = await makeTelegramCheck(snapshot: snapshot)
        let availability = await probeHermesAvailability(on: connection)
        publishHermesAvailability(availability)
        let hermesCheck = makeHermesCheck(availability: availability)
        // Order: local stack first (machine-side state user can fix without
        // touching the VM), then host-level (gateway, Hermes version,
        // Telegram downstream).
        checks = localChecks + [gatewayCheck, hermesCheck, telegramCheck]
        lastRefreshedAt = Date()
    }

    // MARK: - Local stack checks

    /// Probe the Mac-side moving parts that the rest of OS1 depends on.
    /// Each runs with a short timeout and returns a Check row; never throws.
    private func makeLocalStackChecks() async -> [Check] {
        async let codex = makeBinaryCheck(id: "cli-codex", title: "Codex CLI", binary: "codex", versionArgs: ["--version"])
        async let claude = makeBinaryCheck(id: "cli-claude", title: "Claude Code CLI", binary: "claude", versionArgs: ["--version"])
        async let wuphf = makeWUPHFCheck()
        async let launchd = makeLaunchdCheck()
        async let voicePort = makeVoicePortCheck()
        async let keychain = makeKeychainCheck()
        async let notarization = makeNotarizationCheck()
        async let productionGates = makeProductionGatesCheck()
        return await [codex, claude, wuphf, launchd, voicePort, keychain, notarization, productionGates]
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

    private nonisolated static func productionOperatingModelURL() -> URL {
        let cwd = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
        let cwdDoc = cwd.appendingPathComponent("docs/production-operating-model.md")
        if FileManager.default.fileExists(atPath: cwdDoc.path) {
            return cwdDoc
        }
        return URL(fileURLWithPath: "/Users/gaganarora/Desktop/my projects/hermes-desktop-os1/docs/production-operating-model.md")
    }

    /// Reports whether the built OS1.app bundle is Developer-ID-signed +
    /// notarized + stapled. Matters when distributing to anyone other than
    /// yourself — without notarization, fresh Macs show "unidentified
    /// developer" Gatekeeper warnings.
    private func makeNotarizationCheck() async -> Check {
        let appPath = "/Users/gaganarora/Desktop/my projects/hermes-desktop-os1/dist/OS1.app"
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
        guard let url = URL(string: "http://127.0.0.1:7891/api/channels") else {
            return Check(id: "wuphf", title: "WUPHF office", severity: .warn, summary: "Bad URL", detail: nil, actions: [])
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                let agentCount = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["channels"] as? [Any]
                return Check(
                    id: "wuphf",
                    title: "WUPHF office",
                    severity: .ok,
                    summary: L10n.string("Reachable on :7891 — %lld channel(s)", agentCount?.count ?? 0),
                    detail: "http://127.0.0.1:7891 responding. The autonomous AI employees layer is up.",
                    actions: []
                )
            }
            return Check(id: "wuphf", title: "WUPHF office", severity: .warn, summary: "Unexpected HTTP \(code)", detail: nil, actions: [])
        } catch {
            return Check(
                id: "wuphf",
                title: "WUPHF office",
                severity: .warn,
                summary: L10n.string("Not reachable on :7891"),
                detail: L10n.string("Start it with `launchctl load -w ~/Library/LaunchAgents/com.os1.wuphf.plist` (or run `wuphf --no-open --no-nex --pack starter` once for development). Error: %@", error.localizedDescription),
                actions: []
            )
        }
    }

    private func makeLaunchdCheck() async -> Check {
        let output = await runWithTimeout(executable: "/bin/launchctl", args: ["list"], timeoutSec: 3) ?? ""
        let labels = ["com.os1.wuphf", "com.os1.app", "com.os1.samantha-bot", "com.os1.coo"]
        let loaded = labels.filter { output.contains($0) }
        let missing = labels.filter { !output.contains($0) }
        if missing.isEmpty {
            return Check(
                id: "launchd",
                title: "Launchd plists",
                severity: .ok,
                summary: L10n.string("All %lld OS1 agents loaded", labels.count),
                detail: loaded.joined(separator: "\n"),
                actions: []
            )
        }
        return Check(
            id: "launchd",
            title: "Launchd plists",
            severity: .warn,
            summary: L10n.string("%lld of %lld OS1 agents loaded", loaded.count, labels.count),
            detail: "Loaded: \(loaded.joined(separator: ", "))\nMissing: \(missing.joined(separator: ", "))\n\nLoad missing ones with `launchctl load -w ~/Library/LaunchAgents/<label>.plist`.",
            actions: []
        )
    }

    private func makeVoicePortCheck() async -> Check {
        let path = NSString(string: "~/.os1/voice-port").expandingTildeInPath
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let mtime = attrs[.modificationDate] as? Date else {
            return Check(
                id: "voice-port",
                title: "Voice server port",
                severity: .warn,
                summary: L10n.string("No ~/.os1/voice-port file"),
                detail: L10n.string("OS1's voice server writes its TCP port here when it starts. Missing file = voice runtime never mounted (boot animation didn't finish, or the voice section was disabled)."),
                actions: []
            )
        }
        let age = Date().timeIntervalSince(mtime)
        let port = (try? String(contentsOfFile: path, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "?"
        if age < 300 {
            return Check(
                id: "voice-port",
                title: "Voice server port",
                severity: .ok,
                summary: L10n.string("Port %@ (fresh, %.0fs old)", port, age),
                detail: path,
                actions: []
            )
        }
        return Check(
            id: "voice-port",
            title: "Voice server port",
            severity: .warn,
            summary: L10n.string("Port %@ (stale, %.0f min old)", port, age / 60),
            detail: L10n.string("Voice server hasn't refreshed its port file recently. Could be a stale file from a prior OS1 process. Restart OS1 to rewrite it."),
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
        }
        // Always refresh after an action so the user sees the new state.
        await refresh()
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
            if !result.installed { return .notInstalled }
            let label = result.version_label ?? L10n.string("Hermes Agent")
            switch result.behind {
            case .some(0):
                return .upToDate(versionLabel: label)
            case .some(let n) where n > 0:
                return .behind(versionLabel: label, commits: n)
            case .some(-1):
                return .behind(versionLabel: label, commits: nil)
            default:
                // Probe couldn't determine — don't nag the user.
                return .upToDate(versionLabel: label)
            }
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
        case .behind(let versionLabel, let commits):
            let summary: String
            if let commits, commits > 0 {
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
