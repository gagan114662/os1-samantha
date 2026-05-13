import SwiftUI

struct OverviewView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        HermesPageContainer(width: .dashboard) {
            VStack(alignment: .leading, spacing: 24) {
                header

                if let activeConnection = appState.activeConnection {
                    hermesInstallBanner(for: activeConnection)
                }

                hermesUpdateBanner

                if let activeConnection = appState.activeConnection,
                   let overview = appState.overview {
                    overviewLayout(activeConnection: activeConnection, overview: overview)
                } else if let overviewError = appState.overviewError {
                    HermesSurfacePanel {
                        ContentUnavailableView(
                            "Discovery failed",
                            systemImage: "exclamationmark.triangle",
                            description: Text(overviewError)
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    }
                } else {
                    HermesSurfacePanel {
                        HermesLoadingState(
                            label: "Discovering the active Hermes workspace…",
                            minHeight: 320
                        )
                    }
                }
            }
        }
        .task(id: appState.activeConnectionID) {
            if appState.overview == nil {
                await appState.refreshOverview()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                Text(L10n.string("Overview"))
                    .font(.os1TitleSection)
                    .fontWeight(.semibold)

                Text(L10n.string("See which host Hermes is connected to, where its files live, and which source powers Sessions, Cron Jobs, and Usage."))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            HermesRefreshButton(isRefreshing: appState.isRefreshingOverview) {
                Task {
                    await appState.refreshOverview(manual: true)
                }
            }
            .disabled(appState.isBusy)
        }
    }

    @ViewBuilder
    private func overviewLayout(activeConnection: ConnectionProfile, overview: RemoteDiscovery) -> some View {
        ViewThatFits(in: .horizontal) {
            regularLayout(activeConnection: activeConnection, overview: overview)
            compactLayout(activeConnection: activeConnection, overview: overview)
        }
    }

    private func regularLayout(activeConnection: ConnectionProfile, overview: RemoteDiscovery) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                currentHostPanel(activeConnection)
                    .frame(minWidth: 230, maxWidth: .infinity)

                workspacePanel(overview)
                    .frame(minWidth: 270, maxWidth: .infinity)

                statusPanel(for: overview)
                    .frame(minWidth: 230, maxWidth: .infinity)
            }

            HStack(alignment: .top, spacing: 16) {
                workspaceFilesPanel(overview)
                    .frame(minWidth: 420, maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 16) {
                    sessionHistoryPanel(overview)
                    kanbanPanel(overview)
                }
                .frame(minWidth: 420, maxWidth: .infinity, alignment: .top)
            }
        }
    }

    private func compactLayout(activeConnection: ConnectionProfile, overview: RemoteDiscovery) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            currentHostPanel(activeConnection)
            workspacePanel(overview)
            statusPanel(for: overview)
            workspaceFilesPanel(overview)
            sessionHistoryPanel(overview)
            kanbanPanel(overview)
        }
    }

    private func currentHostPanel(_ activeConnection: ConnectionProfile) -> some View {
        HermesSurfacePanel(
            title: "Current Host",
            subtitle: "The active SSH connection for this workspace."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(activeConnection.label)
                        .font(.os1TitlePanel)
                        .fontWeight(.semibold)

                    Text(activeConnection.displayDestination)
                        .font(.system(.subheadline, design: .monospaced))
                        .foregroundStyle(.os1OnCoralSecondary)
                        .textSelection(.enabled)
                }

                HermesLabeledValue(
                    label: "Connection",
                    value: "SSH",
                    emphasizeValue: true
                )

                if let alias = activeConnection.trimmedAlias {
                    HermesLabeledValue(
                        label: "Alias",
                        value: alias,
                        isMonospaced: true
                    )
                } else if let host = activeConnection.trimmedHost {
                    HermesLabeledValue(
                        label: "Host",
                        value: host,
                        isMonospaced: true
                    )
                }

                if let lastConnectedAt = activeConnection.lastConnectedAt {
                    HermesLabeledValue(
                        label: "Last connected",
                        value: DateFormatters.relativeFormatter().localizedString(for: lastConnectedAt, relativeTo: .now)
                    )
                }
            }
        }
    }

    private func workspacePanel(_ overview: RemoteDiscovery) -> some View {
        HermesSurfacePanel(
            title: "Workspace",
            subtitle: "The active Hermes profile and the folders it resolves to on the current host."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HermesLabeledValue(
                    label: "Active profile",
                    value: overview.activeProfile.name,
                    emphasizeValue: true
                )

                HermesLabeledValue(
                    label: "Home folder",
                    value: L10n.string(UIDisplayFormatting.readableHomeFolder(overview.remoteHome)),
                    isMonospaced: true
                )

                HermesLabeledValue(
                    label: "Hermes home",
                    value: overview.hermesHome,
                    isMonospaced: true,
                    emphasizeValue: true
                )

                if !overview.availableProfiles.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string("Discovered profiles"))
                            .font(.os1SmallCaps)
                            .foregroundStyle(.os1OnCoralSecondary)

                        HStack(spacing: 8) {
                            ForEach(overview.availableProfiles) { profile in
                                HermesBadge(
                                    text: profile.name,
                                    tint: profile.name == overview.activeProfile.name ? .accentColor : .secondary
                                )
                            }
                        }
                    }
                }
            }
        }
    }

    private func statusPanel(for overview: RemoteDiscovery) -> some View {
        let statusItems = makeStatusItems(for: overview)
        let readyCount = statusItems.filter(\.isReady).count
        let summaryTitle = readyCount == statusItems.count ? "Ready" : "Needs attention"
        let summaryDetail = readyCount == statusItems.count
            ? "All \(statusItems.count) checks passed"
            : "\(readyCount) of \(statusItems.count) checks passed"

        return HermesSurfacePanel(
            title: "Status",
            subtitle: "Quick checks to confirm the active host is ready for files, sessions, usage, and terminal access."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    HermesBadge(
                        text: summaryTitle,
                        tint: readyCount == statusItems.count ? .green : .orange
                    )

                    Text(summaryDetail)
                        .font(.os1Body)
                        .foregroundStyle(.os1OnCoralSecondary)
                }

                VStack(alignment: .leading, spacing: 10) {
                    ForEach(statusItems) { item in
                        OverviewStatusRow(item: item)
                    }
                }
            }
        }
    }

    private func workspaceFilesPanel(_ overview: RemoteDiscovery) -> some View {
        HermesSurfacePanel(
            title: "Workspace Files",
            subtitle: "Expected Hermes files and folders on the active host."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                OverviewPathRow(
                    title: "User file",
                    badge: "USER.md",
                    value: overview.paths.user,
                    isReady: overview.exists.user
                )

                OverviewPathRow(
                    title: "Memory file",
                    badge: "MEMORY.md",
                    value: overview.paths.memory,
                    isReady: overview.exists.memory
                )

                OverviewPathRow(
                    title: "Soul file",
                    badge: "SOUL.md",
                    value: overview.paths.soul,
                    isReady: overview.exists.soul
                )

                OverviewPathRow(
                    title: "Session artifacts",
                    badge: "Sessions",
                    value: overview.paths.sessionsDir,
                    isReady: overview.exists.sessionsDir
                )

                OverviewPathRow(
                    title: "Cron jobs registry",
                    badge: "Cron",
                    value: overview.paths.cronJobs,
                    isReady: overview.exists.cronJobs
                )

                OverviewPathRow(
                    title: "Kanban board",
                    badge: "Kanban",
                    value: overview.paths.kanbanDatabase ?? "~/.hermes/kanban.db",
                    isReady: overview.exists.kanbanDatabase ?? false
                )
            }
        }
    }

    private func sessionHistoryPanel(_ overview: RemoteDiscovery) -> some View {
        HermesSurfacePanel(
            title: "Session History",
            subtitle: "The source Hermes uses for Sessions and Usage on the active host."
        ) {
            VStack(alignment: .leading, spacing: 16) {
                if let sessionStore = overview.sessionStore {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "internaldrive.fill")
                            .font(.os1TitlePanel)
                            .foregroundStyle(Color.os1OnCoralPrimary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("SQLite database detected"))
                                .font(.os1TitlePanel)

                            Text(L10n.string("Hermes can read structured session and message records directly."))
                                .font(.os1Body)
                                .foregroundStyle(.os1OnCoralSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        HermesBadge(text: sessionStore.kind.displayName, tint: .accentColor)
                    }

                    VStack(alignment: .leading, spacing: 14) {
                        HermesLabeledValue(
                            label: "Database path",
                            value: sessionStore.path,
                            isMonospaced: true,
                            emphasizeValue: true
                        )

                        if let sessionTable = sessionStore.sessionTable {
                            HermesLabeledValue(
                                label: "Sessions table",
                                value: sessionTable,
                                isMonospaced: true
                            )
                        }

                        if let messageTable = sessionStore.messageTable {
                            HermesLabeledValue(
                                label: "Messages table",
                                value: messageTable,
                                isMonospaced: true
                            )
                        }
                    }
                } else {
                    HStack(alignment: .center, spacing: 12) {
                        Image(systemName: "doc.text.magnifyingglass")
                            .font(.os1TitlePanel)
                            .foregroundStyle(.os1OnCoralSecondary)

                        VStack(alignment: .leading, spacing: 4) {
                            Text(L10n.string("Using transcript files"))
                                .font(.os1TitlePanel)

                            Text(L10n.string("No SQLite database was found, so Hermes will fall back to session transcript artifacts when available."))
                                .font(.os1Body)
                                .foregroundStyle(.os1OnCoralSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Spacer(minLength: 12)

                        HermesBadge(text: "JSONL", tint: .secondary)
                    }

                    HermesLabeledValue(
                        label: "Transcript folder",
                        value: overview.paths.sessionsDir,
                        isMonospaced: true,
                        emphasizeValue: true
                    )
                }
            }
        }
    }

    private func kanbanPanel(_ overview: RemoteDiscovery) -> some View {
        HermesSurfacePanel(
            title: "Kanban Board",
            subtitle: "Host-wide coordination state shared by Hermes profiles on this SSH target."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "rectangle.3.group")
                        .font(.os1TitlePanel)
                        .foregroundStyle(overview.kanban?.exists == true ? Color.os1OnCoralPrimary : .secondary)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string(overview.kanban?.exists == true ? "Kanban database detected" : "Kanban database not initialized"))
                            .font(.os1TitlePanel)

                        Text(L10n.string("Desktop reads and updates this board over SSH without using the web dashboard API."))
                            .font(.os1Body)
                            .foregroundStyle(.os1OnCoralSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    Spacer(minLength: 12)

                    HermesBadge(text: "Host-wide", tint: .accentColor)
                }

                HermesLabeledValue(
                    label: "Database path",
                    value: overview.kanban?.databasePath ?? overview.paths.kanbanDatabase ?? "~/.hermes/kanban.db",
                    isMonospaced: true,
                    emphasizeValue: true
                )

                HStack(spacing: 10) {
                    HermesBadge(
                        text: overview.kanban?.hasHermesCLI == true ? "CLI ready" : "CLI missing",
                        tint: overview.kanban?.hasHermesCLI == true ? .green : .orange
                    )

                    HermesBadge(
                        text: overview.kanban?.hasKanbanModule == true ? "Module ready" : "Module fallback",
                        tint: overview.kanban?.hasKanbanModule == true ? .green : .secondary
                    )

                    if let dispatcher = overview.kanban?.dispatcher,
                       let running = dispatcher.running {
                        HermesBadge(
                            text: running ? "Dispatcher active" : "Dispatcher inactive",
                            tint: running ? .green : .orange
                        )
                    }
                }

                if overview.kanban?.dispatcher?.isKnownInactive == true,
                   let message = overview.kanban?.dispatcher?.message {
                    Text(message)
                        .font(.os1SmallCaps)
                        .foregroundStyle(.os1OnCoralSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func makeStatusItems(for overview: RemoteDiscovery) -> [OverviewStatusItem] {
        [
            OverviewStatusItem(
                id: "profile",
                title: "Selected profile home",
                isReady: overview.activeProfile.exists
            ),
            OverviewStatusItem(
                id: "files",
                title: "Workspace files",
                isReady: overview.exists.user && overview.exists.memory && overview.exists.soul
            ),
            OverviewStatusItem(
                id: "sessions",
                title: "Sessions/Usage source",
                isReady: overview.sessionStore != nil || overview.exists.sessionsDir
            ),
            OverviewStatusItem(
                id: "kanban",
                title: "Host-wide Kanban board",
                isReady: overview.kanban?.exists == true || overview.kanban?.hasHermesCLI == true || overview.kanban?.hasKanbanModule == true
            )
        ]
    }

    // MARK: - Hermes install banner (Orgo-only)

    @ViewBuilder
    private func hermesInstallBanner(for connection: ConnectionProfile) -> some View {
        if case .orgo = connection.transport {
            switch appState.hermesInstallStatus {
            case .running:
                installRunningBanner
            case .failed(let message):
                installFailedBanner(message: message)
            case .idle:
                if let overview = appState.overview, overview.kanban?.hasHermesCLI != true {
                    installCTABanner
                }
            }
        }
    }

    private var installCTABanner: some View {
        HermesSurfacePanel(
            title: "Install Hermes Agent",
            subtitle: "Hermes isn't installed on this Orgo VM yet."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("Sessions, Kanban, Files, Skills, and Cron all read from ~/.hermes on the VM. Install Hermes Agent to enable them. The installer takes about 30 to 90 seconds."))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Button {
                    Task { await appState.installHermesOnActiveOrgoConnection() }
                } label: {
                    Label(L10n.string("Install Hermes Agent"), systemImage: "arrow.down.circle.fill")
                }
                .buttonStyle(.os1Primary)
            }
        }
    }

    private var installRunningBanner: some View {
        HermesSurfacePanel(
            title: "Installing Hermes Agent",
            subtitle: "Running install.sh from NousResearch/hermes-agent. This usually takes under 90 seconds."
        ) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(L10n.string("Downloading, setting up the Python virtualenv, and installing dependencies on the VM…"))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Hermes update banner (works for both Orgo + SSH)

    @ViewBuilder
    private var hermesUpdateBanner: some View {
        switch appState.hermesUpdateStatus {
        case .running:
            updateRunningBanner
        case .failed(let message, let logTail):
            updateFailedBanner(message: message, logTail: logTail)
        case .idle:
            if case .behind(let versionLabel, let commits) = appState.hermesUpdateAvailability {
                updateAvailableBanner(versionLabel: versionLabel, commits: commits)
            }
        }
    }

    private func updateAvailableBanner(versionLabel: String, commits: Int?) -> some View {
        let subtitle: String = {
            if let commits, commits > 0 {
                return String(
                    format: L10n.string(commits == 1
                        ? "%@ — %d commit behind main."
                        : "%@ — %d commits behind main."),
                    versionLabel,
                    commits
                )
            }
            return String(format: L10n.string("%@ — update available."), versionLabel)
        }()
        return HermesSurfacePanel(
            title: "Hermes update available",
            subtitle: subtitle
        ) {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("Runs hermes update --backup on this host. The gateway restarts automatically; the previous state is restorable via hermes backup restore --state pre-update."))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 10) {
                    Button {
                        Task { await appState.performHermesUpdate() }
                    } label: {
                        Label(L10n.string("Update Hermes Agent"), systemImage: "arrow.up.circle.fill")
                    }
                    .buttonStyle(.os1Primary)

                    Link(destination: URL(string: "https://github.com/NousResearch/hermes-agent/commits/main")!) {
                        Label(L10n.string("View changelog"), systemImage: "list.bullet.rectangle")
                    }
                    .buttonStyle(.os1Secondary)
                }
            }
        }
    }

    private var updateRunningBanner: some View {
        HermesSurfacePanel(
            title: "Updating Hermes Agent",
            subtitle: "Running hermes update --backup. Gateway restarts when the update completes."
        ) {
            HStack(spacing: 12) {
                ProgressView().controlSize(.small)
                Text(L10n.string("Pulling latest code, reinstalling dependencies, restarting the gateway…"))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func updateFailedBanner(message: String, logTail: String?) -> some View {
        HermesSurfacePanel(
            title: "Hermes update failed",
            subtitle: "Last 4 KB of the update process output is shown below."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(logTail?.isEmpty == false ? logTail! : message)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(Color.os1OnCoralSecondary.opacity(0.08))
                .cornerRadius(6)

                HStack(spacing: 10) {
                    Button {
                        Task { await appState.performHermesUpdate() }
                    } label: {
                        Label(L10n.string("Retry update"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.os1Primary)

                    Button(L10n.string("Dismiss")) {
                        appState.dismissHermesUpdateError()
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func installFailedBanner(message: String) -> some View {
        HermesSurfacePanel(
            title: "Hermes installer failed",
            subtitle: "Last 4 KB of the installer's stderr is shown below."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView {
                    Text(message)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(8)
                }
                .frame(maxHeight: 200)
                .background(Color.os1OnCoralSecondary.opacity(0.08))
                .cornerRadius(6)

                HStack(spacing: 10) {
                    Button {
                        Task { await appState.installHermesOnActiveOrgoConnection() }
                    } label: {
                        Label(L10n.string("Retry install"), systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.os1Primary)

                    Button(L10n.string("Dismiss")) {
                        appState.dismissHermesInstallError()
                    }
                }
            }
        }
    }
}

private struct OverviewPathRow: View {
    let title: String
    let badge: String
    let value: String
    let isReady: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                Text(L10n.string(title))
                    .font(.os1TitlePanel)

                HermesBadge(text: badge, tint: .secondary)

                Spacer(minLength: 12)

                HermesBadge(
                    text: isReady ? "Ready" : "Missing",
                    tint: .os1OnCoralPrimary,
                    systemImage: isReady ? "checkmark.circle.fill" : "circle.dotted"
                )
            }

            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.os1OnCoralSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.os1OnCoralSecondary.opacity(0.08))
        )
    }
}

private struct OverviewStatusItem: Identifiable {
    let id: String
    let title: String
    let isReady: Bool
}

private struct OverviewStatusRow: View {
    let item: OverviewStatusItem

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: item.isReady ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(item.isReady ? Color.os1OnCoralPrimary : Color.os1OnCoralMuted)

            Text(L10n.string(item.title))
                .font(.os1Body)
                .foregroundStyle(item.isReady ? Color.os1OnCoralPrimary : Color.os1OnCoralMuted)

            Spacer()

            Text(L10n.string(item.isReady ? "Ready" : "Missing"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(item.isReady ? Color.os1OnCoralPrimary : Color.os1OnCoralMuted)
        }
    }
}
