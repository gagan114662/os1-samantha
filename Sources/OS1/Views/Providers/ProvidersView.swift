import AppKit
import SwiftUI

/// Providers tab — picks which model and media providers Samantha can
/// use on each remote host. Mirrors the Connectors tab's
/// "tab → list of cards → modal connect sheet" structure so users
/// see a consistent shape between "tools the agent can use" and
/// "models the agent runs as."
struct ProvidersView: View {
    @ObservedObject var viewModel: ProvidersViewModel
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HermesPageHeader(
                    title: "Providers",
                    subtitle: "Connect text, image, video, voice, music, avatar, and render providers. Paste an API key or sign in where supported, then install it on the active host."
                )

                if let error = viewModel.topLevelError {
                    HStack(alignment: .top, spacing: 8) {
                        Text(error)
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralPrimary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button {
                            viewModel.clearTopLevelError()
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .buttonStyle(.os1Icon)
                    }
                    .padding(10)
                    .background(theme.palette.onCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
                }

                introBanner

                providerListPanel
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
            .frame(maxWidth: 760, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(theme.palette.coral)
        .onAppear { viewModel.refreshFromStorage() }
        .onChange(of: appState.activeConnection?.id) { _, newId in
            viewModel.setActiveProfile(newId?.uuidString)
        }
        .task {
            // Initial sync at first render — onChange doesn't fire on
            // the initial value.
            viewModel.setActiveProfile(appState.activeConnection?.id.uuidString)
        }
        .sheet(item: $viewModel.selectedProvider) { entry in
            ProviderConnectSheet(viewModel: viewModel, entry: entry)
        }
    }

    private var introBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "sparkles")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("How providers work"))
                    .os1Style(theme.typography.bodyEmphasis)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(L10n.string("Each provider's API key is stored in macOS Keychain on this Mac, scoped per host. Installing pushes it onto that host's ~/.hermes/.env so Samantha can use the provider on the next heartbeat — no daemon restart needed."))
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

    // MARK: - Provider list

    private var providerListPanel: some View {
        HermesSurfacePanel(
            title: "Available providers",
            subtitle: "Grouped by modality so text, media generation, voice, and render capacity are visible before companies request them."
        ) {
            VStack(alignment: .leading, spacing: 14) {
                ForEach(providerGroups, id: \.modality) { group in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(L10n.string(group.modality.displayName))
                            .os1Style(theme.typography.smallCaps)
                            .foregroundStyle(theme.palette.onCoralMuted)

                        VStack(spacing: 8) {
                            ForEach(group.providers) { display in
                                providerRow(display)
                            }
                        }
                    }
                }
            }
        }
    }

    private var providerGroups: [(modality: ProviderCatalogEntry.Modality, providers: [ProvidersViewModel.ProviderDisplay])] {
        ProviderCatalogEntry.Modality.allCases.compactMap { modality in
            let providers = viewModel.providers.filter { $0.entry.modality == modality }
            guard !providers.isEmpty else { return nil }
            return (modality, providers)
        }
    }

    @ViewBuilder
    private func providerRow(_ display: ProvidersViewModel.ProviderDisplay) -> some View {
        let isInFlight = viewModel.inFlightSlug == display.entry.slug

        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: display.entry.symbolName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(theme.palette.glassFill)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(display.entry.displayName)
                        .os1Style(theme.typography.bodyEmphasis)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                    Text(L10n.string(display.entry.tagline))
                        .os1Style(theme.typography.smallCaps)
                        .foregroundStyle(theme.palette.onCoralMuted)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(providerCapacityLine(for: display.entry))
                        .os1Style(theme.typography.smallCaps)
                        .foregroundStyle(theme.palette.onCoralMuted)
                        .fixedSize(horizontal: false, vertical: true)
                        .help(providerCapacityLine(for: display.entry))
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Spacer(minLength: 8)

                statusPill(for: display)
                primaryAction(for: display, isInFlight: isInFlight)
            }

            if display.hasKey, let connection = appState.activeConnection {
                installPanel(for: display, connection: connection, isInFlight: isInFlight)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(theme.palette.darkOverlay.opacity(0.35))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(theme.palette.glassBorder.opacity(0.6), lineWidth: 1)
        }
    }

    private func providerCapacityLine(for entry: ProviderCatalogEntry) -> String {
        let quota = entry.freeTierQuota.map { "\($0.amount) \($0.unit)" }
        return UIDisplayFormatting.providerCapacityLine(modality: entry.modality.displayName, quota: quota)
    }

    private func statusPill(for display: ProvidersViewModel.ProviderDisplay) -> some View {
        Group {
            if display.hasKey {
                HermesBadge(
                    text: display.isProfileScoped ? "Connected · this host" : "Connected · default",
                    tint: theme.palette.onCoralPrimary,
                    systemImage: "checkmark.circle.fill",
                    prominence: .strong
                )
            } else {
                HermesBadge(
                    text: "Not connected",
                    tint: theme.palette.onCoralMuted,
                    systemImage: "circle.dashed",
                    prominence: .subtle
                )
            }
        }
    }

    @ViewBuilder
    private func primaryAction(
        for display: ProvidersViewModel.ProviderDisplay,
        isInFlight: Bool
    ) -> some View {
        if display.hasKey {
            Menu {
                Button(L10n.string("Re-enter key")) {
                    viewModel.openConnectSheet(for: display.entry)
                }
                Button(L10n.string("Disconnect"), role: .destructive) {
                    viewModel.disconnect(slug: display.entry.slug)
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        } else {
            Button(L10n.string("Connect")) {
                viewModel.openConnectSheet(for: display.entry)
            }
            .buttonStyle(.os1Primary)
            .disabled(isInFlight)
        }
    }

    // MARK: - Install panel (per row, shown only when key is present)

    @ViewBuilder
    private func installPanel(
        for display: ProvidersViewModel.ProviderDisplay,
        connection: ConnectionProfile,
        isInFlight: Bool
    ) -> some View {
        let hostLabel = connection.label.isEmpty ? L10n.string("active host") : connection.label

        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                installStatusBadge(for: display.vmInstall, hostLabel: hostLabel)
                if let active = display.activeModel, !active.isEmpty {
                    Text(L10n.string("Active: %@", active))
                        .os1Style(theme.typography.smallCaps)
                        .foregroundStyle(theme.palette.onCoralMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Spacer()
                installAction(for: display, connection: connection, isInFlight: isInFlight)
            }

            if case .failed(let message) = display.vmInstall {
                HermesValidationMessage(text: message)
            }

            if let models = viewModel.modelsBySlug[display.entry.slug],
               !models.isEmpty,
               case .installed = display.vmInstall {
                modelPicker(for: display, models: models, connection: connection)
            }
        }
        .task(id: connection.id.uuidString + "/" + display.entry.slug) {
            await viewModel.checkVMStatus(slug: display.entry.slug, connection: connection)
        }
    }

    private func installStatusBadge(
        for state: ProvidersViewModel.VMInstallState,
        hostLabel: String
    ) -> some View {
        switch state {
        case .unknown:
            return HermesBadge(text: L10n.string("Status unknown"), tint: theme.palette.onCoralMuted, systemImage: "questionmark.circle", prominence: .subtle)
        case .checking:
            return HermesBadge(text: L10n.string("Checking %@…", hostLabel), tint: theme.palette.onCoralSecondary, systemImage: "arrow.triangle.2.circlepath", prominence: .subtle)
        case .notInstalled:
            return HermesBadge(text: L10n.string("Not on %@", hostLabel), tint: theme.palette.onCoralMuted, systemImage: "circle.dashed", prominence: .subtle)
        case .installing:
            return HermesBadge(text: L10n.string("Installing on %@…", hostLabel), tint: theme.palette.onCoralPrimary, systemImage: "arrow.down.circle", prominence: .strong)
        case .installed:
            return HermesBadge(text: L10n.string("Installed on %@", hostLabel), tint: theme.palette.onCoralPrimary, systemImage: "checkmark.circle.fill", prominence: .strong)
        case .failed:
            return HermesBadge(text: L10n.string("Install failed"), tint: theme.palette.onCoralPrimary, systemImage: "exclamationmark.triangle.fill", prominence: .strong)
        }
    }

    @ViewBuilder
    private func installAction(
        for display: ProvidersViewModel.ProviderDisplay,
        connection: ConnectionProfile,
        isInFlight: Bool
    ) -> some View {
        switch display.vmInstall {
        case .installed:
            Menu {
                Button(L10n.string("Refresh model list")) {
                    Task { await viewModel.refreshModels(slug: display.entry.slug) }
                }
                Button(L10n.string("Re-push key")) {
                    Task {
                        await viewModel.installOnHost(
                            slug: display.entry.slug,
                            connection: connection,
                            activateModel: display.activeModel
                        )
                    }
                }
                Button(L10n.string("Remove from host"), role: .destructive) {
                    Task {
                        await viewModel.uninstallFromHost(slug: display.entry.slug, connection: connection)
                    }
                }
            } label: {
                Text(L10n.string("Manage on host"))
                    .os1Style(theme.typography.smallCaps)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        case .installing, .checking:
            ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
        default:
            Button {
                Task {
                    await viewModel.installOnHost(
                        slug: display.entry.slug,
                        connection: connection,
                        activateModel: nil
                    )
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.up.circle")
                        .font(.system(size: 11, weight: .semibold))
                    Text(L10n.string("Install on host"))
                }
            }
            .buttonStyle(.os1Secondary)
            .disabled(isInFlight)
        }
    }

    private func modelPicker(
        for display: ProvidersViewModel.ProviderDisplay,
        models: [ProviderModelSummary],
        connection: ConnectionProfile
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string("Active model"))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)

            Menu {
                Section(L10n.string("Models")) {
                    ForEach(models) { model in
                        Button {
                            Task {
                                await viewModel.activateModel(
                                    slug: display.entry.slug,
                                    model: model.id,
                                    connection: connection
                                )
                            }
                        } label: {
                            if model.id == display.activeModel {
                                Label(model.displayName ?? model.id, systemImage: "checkmark")
                            } else {
                                Text(model.displayName ?? model.id)
                            }
                        }
                    }
                }
                Divider()
                Button(L10n.string("Refresh model list")) {
                    Task { await viewModel.refreshModels(slug: display.entry.slug) }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(display.activeModel ?? L10n.string("Pick a model"))
                        .os1Style(theme.typography.body)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(theme.palette.onCoralMuted)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(theme.palette.glassFill)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
                }
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
    }
}
