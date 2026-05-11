import AppKit
import SwiftUI

/// Connectors tab — central place to set up Composio Connect for the
/// Hermes agent. Two screens:
///
///  - `.unconfigured`: paste API key (BYOK; Composio is web-signup only)
///  - `.configured`:   account info + per-VM install panel
struct ConnectorsView: View {
    @ObservedObject var viewModel: ConnectorsViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    var body: some View {
        Group {
            switch viewModel.step {
            case .loading:
                loadingView
            case .unconfigured:
                unconfiguredView
            case .configured:
                configuredView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.coral)
        .onAppear { viewModel.refreshFromStorage() }
        .onChange(of: appState.activeConnection?.id) { _, newId in
            // Auto-swap creds when the user picks a different host so
            // One connection's key never leaks into another connection's view.
            viewModel.setActiveProfile(newId?.uuidString)
        }
        .task {
            // Initial sync at first render — onChange doesn't fire on
            // the initial value.
            viewModel.setActiveProfile(appState.activeConnection?.id.uuidString)
        }
        .task(id: scanTaskKey) {
            // When we land on the Connectors tab unconfigured AND
            // there's an active host, ask that host whether it already
            // has a Composio MCP entry (typical case for users who
            // installed Composio CLI / Claude Desktop on a VM before
            // ever opening OS1).
            if viewModel.step == .unconfigured,
               let connection = appState.activeConnection {
                await viewModel.scanForVMKey(connection: connection)
            }
        }
    }

    /// Re-runs the VM-key scan whenever the active connection changes
    /// or the user moves between configured/unconfigured states.
    private var scanTaskKey: String {
        let connectionId = appState.activeConnection?.id.uuidString ?? "none"
        let stepTag: String
        switch viewModel.step {
        case .loading:      stepTag = "loading"
        case .unconfigured: stepTag = "unconfigured"
        case .configured:   stepTag = "configured"
        }
        return "\(connectionId)-\(stepTag)"
    }

    // MARK: - Loading

    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large).tint(theme.palette.onCoralPrimary)
            Text(L10n.string("Checking Composio setup…"))
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Unconfigured

    private var unconfiguredView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HermesPageHeader(
                    title: "Connectors",
                    subtitle: "Plug Hermes into Gmail, Slack, Notion, AgentMail, Linear, and 1,000+ other apps through one Composio Connect MCP entry. The agent only loads the tools it needs at runtime, so adding more connectors doesn't bloat its context."
                )

                if let discovered = viewModel.discoveredVMKey {
                    discoveredKeyBanner(discovered)
                }

                if let connection = appState.activeConnection,
                   viewModel.discoveredVMKey == nil {
                    detectFromHostPanel(connection: connection)
                }

                gettingStartedBanner

                HermesSurfacePanel(
                    title: "API key",
                    subtitle: "Stored in macOS Keychain — never written to disk."
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        EditorField(label: "Paste Composio API key") {
                            VStack(alignment: .leading, spacing: 4) {
                                SecureField(L10n.string("ck_..."), text: $viewModel.apiKeyDraft)
                                    .os1Underlined()
                                    .disabled(viewModel.isBusy)
                                Text(L10n.string("Get your personal consumer key (`ck_...`) at dashboard.composio.dev — it's shown alongside the OpenClaw / OS1 client setup flow. Stored in macOS Keychain on this Mac, never written to disk."))
                                    .os1Style(theme.typography.smallCaps)
                                    .foregroundStyle(theme.palette.onCoralMuted)
                            }
                        }

                        if let error = viewModel.formError {
                            errorBanner(error)
                        }

                        HStack(spacing: 10) {
                            Spacer()
                            Button(L10n.string("Save key")) { viewModel.saveAPIKey() }
                                .buttonStyle(.os1Primary)
                                .disabled(viewModel.apiKeyDraft.isEmpty || viewModel.isBusy)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
        }
    }

    private func detectFromHostPanel(connection: ConnectionProfile) -> some View {
        let hostLabel = connection.label.isEmpty ? L10n.string("active host") : connection.label
        return HStack(alignment: .center, spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)

            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("Already configured on %@?", hostLabel))
                    .os1Style(theme.typography.bodyEmphasis)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(detectFromHostSubtitle(hostLabel: hostLabel))
                    .os1Style(theme.typography.smallCaps)
                    .foregroundStyle(theme.palette.onCoralMuted)
            }

            Spacer(minLength: 8)

            Button {
                Task { await viewModel.scanForVMKey(connection: connection) }
            } label: {
                if viewModel.isScanningForVMKey {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                        Text(L10n.string("Scanning…"))
                    }
                } else {
                    Text(L10n.string("Detect"))
                }
            }
            .buttonStyle(.os1Secondary)
            .disabled(viewModel.isScanningForVMKey)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.palette.glassFill.opacity(0.5))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        }
    }

    private func detectFromHostSubtitle(hostLabel: String) -> String {
        switch viewModel.lastScanResult {
        case .notRun:
            return L10n.string("Pull the existing API key from this host's ~/.hermes/config.yaml.")
        case .found:
            return L10n.string("Found a key on %@.", hostLabel)
        case .notFound:
            return L10n.string("No Composio install detected on %@.", hostLabel)
        case .failed(let message):
            return L10n.string("Couldn't scan %@: %@", hostLabel, message)
        }
    }

    private func discoveredKeyBanner(_ discovered: ConnectorsViewModel.DiscoveredKey) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)
            VStack(alignment: .leading, spacing: 6) {
                Text(L10n.string("Detected an existing Composio install"))
                    .os1Style(theme.typography.bodyEmphasis)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(L10n.string("%@ already has Composio configured in ~/.hermes/config.yaml. Import the key so OS1 can manage your connectors with the same credential.", discovered.connectionLabel))
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 10) {
                    Button(L10n.string("Import key")) {
                        viewModel.importDiscoveredKey()
                    }
                    .buttonStyle(.os1Primary)

                    Button(L10n.string("Paste my own instead")) {
                        viewModel.dismissDiscoveredKey()
                    }
                    .buttonStyle(.os1Secondary)
                }
                .padding(.top, 4)
            }
            Spacer(minLength: 0)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.palette.glassFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        }
    }

    private var gettingStartedBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("How Composio Connect works"))
                    .os1Style(theme.typography.bodyEmphasis)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(L10n.string("Composio is a single MCP endpoint at connect.composio.dev/mcp that brokers OAuth and tool calls across 1,000+ apps — Gmail, Slack, Notion, GitHub, Linear, HubSpot, and more. Authorize each app once in dashboard.composio.dev → Connect Apps (or let the agent prompt you on first use), and the connection persists across sessions."))
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.palette.glassFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        }
    }

    // MARK: - Configured

    private var configuredView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HermesPageHeader(
                    title: "Connectors",
                    subtitle: "Composio Connect is set up on this Mac. Install it on each VM where you want the Hermes agent to use connectors."
                )

                HermesSurfacePanel(title: "Account") {
                    VStack(alignment: .leading, spacing: 12) {
                        HermesLabeledValue(label: "Composio API key", value: "Stored in Keychain")
                        HStack {
                            Spacer()
                            Button(L10n.string("Disconnect")) { viewModel.disconnect() }
                                .buttonStyle(.os1Secondary)
                        }
                    }
                }

                vmInstallPanel

                toolkitsPanel
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .task(id: appState.activeConnection?.id) {
            if let connection = appState.activeConnection {
                await viewModel.checkVMStatus(on: connection)
            }
        }
        .onAppear {
            viewModel.refreshToolkits()
        }
    }

    // MARK: - Toolkits panel

    private var toolkitsPanel: some View {
        HermesSurfacePanel(
            title: "Toolkits",
            subtitle: "Apps the agent can use through Composio. Connect/disconnect actions land in the next checkpoint — for now this is a read-only view of what your account already has authorized."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                toolkitListHeader

                if let error = viewModel.connectError {
                    HStack(alignment: .top, spacing: 8) {
                        Text(error)
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            viewModel.clearConnectError()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.os1Icon)
                    }
                    .padding(10)
                    .background(theme.palette.onCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                if viewModel.toolkits.isEmpty {
                    switch viewModel.toolkitListState {
                    case .idle, .loading:
                        toolkitLoadingPlaceholder
                    case .failed(let message):
                        errorBanner(message)
                    case .loaded:
                        Text(L10n.string("No toolkits found."))
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                    }
                } else {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(viewModel.groupedToolkits, id: \.tag) { group in
                            Text(group.tag.rawValue.capitalized)
                                .os1Style(theme.typography.smallCaps)
                                .foregroundStyle(theme.palette.onCoralMuted)
                            VStack(spacing: 8) {
                                ForEach(group.toolkits) { kit in
                                    toolkitRow(kit)
                                }
                            }
                        }
                    }
                    if case .failed(let message) = viewModel.toolkitListState {
                        // Stale data shown above; show banner so the user
                        // knows the latest refresh failed.
                        errorBanner(message)
                    }
                }
            }
        }
    }

    private var toolkitListHeader: some View {
        HStack(spacing: 8) {
            Text(L10n.string("Available connectors"))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)
            Spacer()
            Button {
                if let url = URL(string: "https://dashboard.composio.dev") {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                HStack(spacing: 4) {
                    Text(L10n.string("Browse all in dashboard"))
                    Image(systemName: "arrow.up.forward.app")
                        .font(.system(size: 10, weight: .semibold))
                }
                .os1Style(theme.typography.smallCaps)
                .foregroundStyle(theme.palette.onCoralSecondary)
            }
            .buttonStyle(.plain)
            .help(L10n.string("Open dashboard.composio.dev → Connect Apps to authorize any of 1,000+ apps."))

            Button {
                viewModel.refreshToolkits()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.os1Icon)
            .help(L10n.string("Refresh toolkit statuses"))
            .disabled(viewModel.toolkitListState == .loading)
        }
    }

    private var toolkitLoadingPlaceholder: some View {
        HStack(spacing: 10) {
            ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
            Text(L10n.string("Loading toolkits…"))
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
        }
        .padding(.vertical, 6)
    }

    private func toolkitRow(_ kit: ConnectorsViewModel.ToolkitDisplay) -> some View {
        HStack(alignment: .center, spacing: 12) {
            toolkitLogo(kit)
                .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(kit.name)
                    .os1Style(theme.typography.bodyEmphasis)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                if let description = kit.description, !description.isEmpty {
                    Text(description)
                        .os1Style(theme.typography.smallCaps)
                        .foregroundStyle(theme.palette.onCoralMuted)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            Spacer(minLength: 8)

            statusPill(for: kit.status)

            toolkitActionButton(for: kit)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.palette.glassFill.opacity(0.5))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        }
    }

    @ViewBuilder
    private func toolkitActionButton(for kit: ConnectorsViewModel.ToolkitDisplay) -> some View {
        let isInFlight = viewModel.inFlightToolkitSlug == kit.slug
        let isOtherInFlight = viewModel.inFlightToolkitSlug != nil && !isInFlight

        switch kit.status {
        case .unknown, .notConnected:
            if isInFlight {
                authorizingButton
            } else {
                Button(L10n.string("Connect")) {
                    viewModel.connectToolkit(slug: kit.slug)
                }
                .buttonStyle(.os1Secondary)
                .disabled(isOtherInFlight)
            }

        case .connected:
            if isInFlight {
                // Disconnect-in-flight is too short to bother offering
                // cancellation; just show a spinner.
                HStack(spacing: 6) {
                    ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                    Text(L10n.string("Removing…"))
                        .os1Style(theme.typography.smallCaps)
                        .foregroundStyle(theme.palette.onCoralMuted)
                }
            } else {
                Button(L10n.string("Disconnect")) {
                    Task { await viewModel.disconnectToolkit(slug: kit.slug) }
                }
                .buttonStyle(.os1Secondary)
                .disabled(isOtherInFlight)
            }
        }
    }

    /// Two-piece composite for an in-flight Connect: a non-clickable
    /// "Authorizing…" indicator + a clickable "Cancel" button. Lets the
    /// user back out after opening the browser without waiting for the
    /// 5-min poll timeout.
    private var authorizingButton: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                Text(L10n.string("Authorizing…"))
                    .os1Style(theme.typography.smallCaps)
                    .foregroundStyle(theme.palette.onCoralMuted)
            }
            Button(L10n.string("Cancel")) {
                viewModel.cancelInFlightAuth()
            }
            .buttonStyle(.os1Secondary)
        }
    }

    @ViewBuilder
    private func toolkitLogo(_ kit: ConnectorsViewModel.ToolkitDisplay) -> some View {
        // Composio MCP doesn't return logo URLs in MANAGE_CONNECTIONS,
        // so we always render the SF Symbol fallback. Real logos could
        // come from a follow-up RETRIEVE_TOOLKITS call later — kept
        // minimal for now.
        let symbol: String = {
            switch kit.slug.lowercased() {
            case "agent_mail", "agentmail": return "envelope.fill"
            case "gmail":                    return "at.circle.fill"
            case "slack":                    return "message.fill"
            case "notion":                   return "doc.text.fill"
            case "linear":                   return "rectangle.3.group.fill"
            case "github":                   return "chevron.left.forwardslash.chevron.right"
            case "googlecalendar":           return "calendar"
            case "googledrive":              return "externaldrive.fill"
            default:                         return "puzzlepiece.extension.fill"
            }
        }()
        Image(systemName: symbol)
            .font(.system(size: 18, weight: .semibold))
            .foregroundStyle(theme.palette.onCoralPrimary)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func statusPill(for status: ConnectorsViewModel.ToolkitConnectionStatus) -> some View {
        let (text, icon): (String, String) = {
            switch status {
            case .connected(let count):
                let label = count > 1 ? L10n.string("Connected · %@", "\(count)") : L10n.string("Connected")
                return (label, "checkmark.circle.fill")
            case .notConnected:
                return (L10n.string("Not connected"), "circle")
            case .unknown:
                return (L10n.string("Unknown"), "circle.dotted")
            }
        }()
        return HermesBadge(
            text: text,
            tint: .os1OnCoralPrimary,
            systemImage: icon
        )
    }

    @ViewBuilder
    private var vmInstallPanel: some View {
        if let connection = appState.activeConnection {
            HermesSurfacePanel(
                title: "Install on this VM",
                subtitle: vmInstallSubtitle(connection: connection)
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    vmInstallStatusRow

                    if let error = viewModel.vmInstallError {
                        errorBanner(error)
                    }

                    HStack {
                        Spacer()
                        Button {
                            Task { await viewModel.installOnVM(connection: connection) }
                        } label: {
                            if isInstallBusy {
                                ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                            } else {
                                Text(installButtonLabel)
                            }
                        }
                        .buttonStyle(.os1Primary)
                        .disabled(isInstallBusy)
                    }
                }
            }
        } else {
            HermesSurfacePanel(
                title: "Install on a VM",
                subtitle: "Connect to a Hermes-equipped host first — the install drops a single MCP entry into ~/.hermes/config.yaml on that VM."
            ) {
                Text(L10n.string("No connection selected."))
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
            }
        }
    }

    private func vmInstallSubtitle(connection: ConnectionProfile) -> String {
        let host = connection.label.isEmpty ? L10n.string("active host") : connection.label
        return L10n.string("Adds an `mcp_servers.composio` entry pointing at connect.composio.dev/mcp to ~/.hermes/config.yaml on %@. The agent picks it up on next start.", host)
    }

    private var vmInstallStatusRow: some View {
        HStack(spacing: 8) {
            Image(systemName: vmInstallStatusIcon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)
                .frame(width: 18)
            Text(vmInstallStatusText)
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralPrimary)
            Spacer()
        }
    }

    private var vmInstallStatusIcon: String {
        switch viewModel.vmInstallState {
        case .unknown, .checking, .installing:
            return "circle.dotted"
        case .notInstalled:
            return "circle"
        case .installed:
            return "checkmark.circle.fill"
        case .failed:
            return "exclamationmark.octagon.fill"
        }
    }

    private var vmInstallStatusText: String {
        switch viewModel.vmInstallState {
        case .unknown:      return L10n.string("Status unknown")
        case .checking:     return L10n.string("Checking VM…")
        case .notInstalled: return L10n.string("Not installed on this VM")
        case .installing:   return L10n.string("Installing on VM…")
        case .installed:    return L10n.string("Installed and registered with Hermes")
        case .failed:       return L10n.string("Install failed")
        }
    }

    private var installButtonLabel: String {
        switch viewModel.vmInstallState {
        case .installed: return L10n.string("Reinstall / refresh key")
        case .failed:    return L10n.string("Retry install")
        default:         return L10n.string("Install on VM")
        }
    }

    private var isInstallBusy: Bool {
        switch viewModel.vmInstallState {
        case .checking, .installing: return true
        default: return false
        }
    }

    // MARK: - Reusable bits

    private func errorBanner(_ message: String) -> some View {
        Text(message)
            .os1Style(theme.typography.body)
            .foregroundStyle(theme.palette.onCoralPrimary)
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(theme.palette.onCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }
}
