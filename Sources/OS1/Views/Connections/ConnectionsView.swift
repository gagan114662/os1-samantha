import SwiftUI

struct ConnectionsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    @State private var editingConnection = ConnectionProfile()
    @State private var editorPresentationID = UUID()
    @State private var isPresentingEditor = false
    @State private var editingExistingConnection = false

    var body: some View {
        HermesPageContainer(width: .standard) {
            VStack(alignment: .leading, spacing: 24) {
                HermesPageHeader(
                    title: "Hosts",
                    subtitle: "Alias-first SSH profiles for every Hermes workspace, from a Raspberry Pi to another Mac or a remote VPS."
                ) {
                    Button {
                        presentEditor(for: ConnectionProfile(), isEditing: false)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "plus")
                                .font(.system(size: 11, weight: .semibold))
                            Text(L10n.string("Add Host"))
                        }
                    }
                    .buttonStyle(.os1Primary)
                }

                if appState.connectionStore.connections.isEmpty {
                    HermesSurfacePanel {
                        VStack(alignment: .leading, spacing: 18) {
                            VStack(alignment: .leading, spacing: 10) {
                                Image(systemName: "network.slash")
                                    .font(.system(size: 36, weight: .light))
                                    .foregroundStyle(theme.palette.onCoralSecondary)
                                Text(L10n.string("No hosts yet"))
                                    .os1Style(theme.typography.titlePanel)
                                    .foregroundStyle(theme.palette.onCoralPrimary)
                                Text(L10n.string("Create your first SSH profile to connect OS1 to a Raspberry Pi, another Mac, a VPS, or this Mac via localhost."))
                                    .os1Style(theme.typography.body)
                                    .foregroundStyle(theme.palette.onCoralSecondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }

                            Button {
                                presentEditor(for: ConnectionProfile(), isEditing: false)
                            } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: "plus")
                                        .font(.system(size: 11, weight: .semibold))
                                    Text(L10n.string("Add First Host"))
                                }
                            }
                            .buttonStyle(.os1Primary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 240, alignment: .leading)
                    }
                } else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 16) {
                            hostsPanel
                                .frame(minWidth: 640, maxWidth: .infinity)

                            connectionGuidePanel
                                .frame(width: 320)
                        }

                        VStack(alignment: .leading, spacing: 16) {
                            hostsPanel
                            connectionGuidePanel
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(isPresented: $isPresentingEditor) {
            ConnectionEditorSheet(
                connection: editingConnection,
                isEditing: editingExistingConnection,
                credentialStore: appState.orgoCredentialStore,
                catalogService: appState.orgoCatalogService
            ) { updatedConnection in
                appState.saveConnection(updatedConnection)
            }
            .id(editorPresentationID)
        }
        .onAppear {
            presentPendingNewConnectionEditorIfNeeded()
        }
        .onChange(of: appState.pendingNewConnectionEditorRequestID) { _, _ in
            presentPendingNewConnectionEditorIfNeeded()
        }
    }

    private var hostsPanel: some View {
        HermesSurfacePanel(
            title: "Saved Hosts",
            subtitle: "Choose the active host for discovery, files, sessions and terminal access."
        ) {
            LazyVStack(alignment: .leading, spacing: 12) {
                ForEach(appState.connectionStore.connections) { connection in
                    ConnectionCard(
                        connection: connection,
                        isActive: appState.activeConnectionID == connection.id,
                        onConnect: { appState.connect(to: connection) },
                        onTest: { appState.testConnection(connection) },
                        onEdit: {
                            presentEditor(for: connection, isEditing: true)
                        },
                        onDelete: { appState.deleteConnection(connection) }
                    )
                }
            }
        }
    }

    private var connectionGuidePanel: some View {
        HermesSurfacePanel(
            title: "Connection Guide",
            subtitle: "Keep the setup technical, but easy to scan and reason about."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                HermesInsetSurface {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.string("Recommended"))
                            .os1Style(theme.typography.label)
                            .foregroundStyle(theme.palette.onCoralMuted)

                        Text(L10n.string("Use an SSH alias whenever possible. It keeps the system SSH config as the source of truth and makes profiles easier to move between machines."))
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                HermesInsetSurface {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(L10n.string("Authentication"))
                            .os1Style(theme.typography.label)
                            .foregroundStyle(theme.palette.onCoralMuted)

                        Text(L10n.string("Profiles work best when SSH already works from this Mac without prompts. Password login may still exist on the host, but the app expects a non-interactive SSH path such as keys or ssh-agent."))
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(L10n.string("The Mac and Hermes host do not need to share the same Wi-Fi. What matters is that normal ssh from this Mac can reach the host over LAN, public IP, VPN, or Tailscale."))
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                VStack(alignment: .leading, spacing: 12) {
                    GuideRow(label: "Alias", value: "hermes-home")
                    GuideRow(label: "Hostname", value: "mac-studio.local")
                    GuideRow(label: "LAN or public IP", value: "192.168.1.24 or 203.0.113.10")
                    GuideRow(label: "Same Mac", value: "localhost or a local SSH alias")
                }
            }
        }
    }

    private func presentEditor(for connection: ConnectionProfile, isEditing: Bool) {
        editingConnection = connection
        editingExistingConnection = isEditing
        editorPresentationID = UUID()
        isPresentingEditor = true
    }

    private func presentPendingNewConnectionEditorIfNeeded() {
        guard let requestID = appState.pendingNewConnectionEditorRequestID else { return }
        presentEditor(for: ConnectionProfile(), isEditing: false)
        appState.consumeNewConnectionEditorRequest(requestID)
    }
}

private struct GuideRow: View {
    @Environment(\.os1Theme) private var theme

    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(label))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)

            Text(value)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(theme.palette.onCoralSecondary)
                .textSelection(.enabled)
        }
    }
}

private struct ConnectionCard: View {
    @Environment(\.os1Theme) private var theme

    let connection: ConnectionProfile
    let isActive: Bool
    let onConnect: () -> Void
    let onTest: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HermesInsetSurface {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(connection.label)
                            .os1Style(theme.typography.titlePanel)
                            .foregroundStyle(theme.palette.onCoralPrimary)

                        Text(connection.displayDestination)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(theme.palette.onCoralSecondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 12)

                    VStack(alignment: .trailing, spacing: 8) {
                        if isActive {
                            HermesBadge(
                                text: "Active",
                                tint: theme.palette.onCoralPrimary,
                                prominence: .strong
                            )
                        }

                        HermesBadge(
                            text: aliasLabel,
                            tint: theme.palette.onCoralSecondary
                        )
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 16) {
                        metadataRow(label: "Target", value: resolvedTarget)
                        metadataRow(label: "SSH user", value: connection.trimmedUser ?? "Default")
                        metadataRow(label: "Port", value: displayPort)
                        metadataRow(label: "Hermes profile", value: connection.resolvedHermesProfileName)
                    }

                    VStack(alignment: .leading, spacing: 12) {
                        metadataRow(label: "Target", value: resolvedTarget)
                        metadataRow(label: "SSH user", value: connection.trimmedUser ?? "Default")
                        metadataRow(label: "Port", value: displayPort)
                        metadataRow(label: "Hermes profile", value: connection.resolvedHermesProfileName)
                    }
                }

                if let lastConnectedAt = connection.lastConnectedAt {
                    Text(L10n.string("Last connected %@", DateFormatters.relativeFormatter().localizedString(for: lastConnectedAt, relativeTo: .now)))
                        .os1Style(theme.typography.smallCaps)
                        .foregroundStyle(theme.palette.onCoralMuted)
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        primaryActions
                        Spacer(minLength: 12)
                        destructiveAction
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        primaryActions
                        destructiveAction
                    }
                }
            }
        }
    }

    private var primaryActions: some View {
        HStack(spacing: 10) {
            if isActive {
                Label(L10n.string("Currently Active"), systemImage: "checkmark.circle.fill")
                    .font(.os1SmallCaps)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 7)
                    .background(theme.palette.glassFill, in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
                    }
            } else {
                Button(L10n.string("Use Host"), action: onConnect)
                    .buttonStyle(.os1Primary)
            }

            Button(L10n.string("Test"), action: onTest)
                .buttonStyle(.os1Secondary)

            Button(L10n.string("Edit"), action: onEdit)
                .buttonStyle(.os1Secondary)
        }
    }

    private var destructiveAction: some View {
        Button(L10n.string("Remove"), action: onDelete)
            .buttonStyle(.os1Secondary)
    }

    private func metadataRow(label: String, value: String) -> some View {
        HermesLabeledValue(
            label: label,
            value: value,
            isMonospaced: label != "SSH user" || value != "Default"
        )
    }

    private var resolvedTarget: String {
        connection.trimmedAlias ?? connection.trimmedHost ?? "Not set"
    }

    private var displayPort: String {
        if let port = connection.resolvedPort {
            return String(port)
        }
        return "Default"
    }

    private var aliasLabel: String {
        switch connection.transport {
        case .ssh:
            return connection.trimmedAlias != nil ? "Alias" : "Direct host"
        case .orgo:
            return "Orgo VM"
        }
    }
}
