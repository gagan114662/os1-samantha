import SwiftUI

/// Multi-VM tile grid. Lists every computer in the active Orgo workspace and
/// renders each as a live screenshot-streaming tile (see
/// `ScreenshotStreamView`). Auto-refreshes so computers Samantha
/// spins up via voice tools appear within ~10 seconds.
struct TilesView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    @State private var computers: [OrgoComputerSummary] = []
    @State private var endpoints: [String: OrgoVNCEndpoint] = [:]
    @State private var loadError: String = ""
    @State private var isLoading = false
    @State private var isCreating = false
    @State private var refreshTask: Task<Void, Never>?
    @State private var pollTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 14)]

    var body: some View {
        VStack(spacing: 0) {
            header

            if let workspaceId = activeWorkspaceId, !workspaceId.isEmpty {
                grid(workspaceId: workspaceId)
            } else {
                noWorkspacePlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.coral)
        .onAppear {
            startRefresh()
            startPolling()
        }
        .onDisappear {
            refreshTask?.cancel(); refreshTask = nil
            pollTask?.cancel(); pollTask = nil
        }
        .onChange(of: activeWorkspaceId) { _, _ in
            computers = []
            endpoints = [:]
            startRefresh()
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x2")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)

            Text(L10n.string("Tiles"))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)

            Text("·")
                .foregroundStyle(theme.palette.onCoralMuted)

            Text(L10n.string(
                UIDisplayFormatting.computerCountLabelKey(for: computers.count),
                computers.count
            ))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)

            Spacer()

            if isLoading {
                ProgressView()
                    .controlSize(.small)
                    .tint(theme.palette.onCoralPrimary)
            }

            Button {
                Task { await createComputer() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                    Text(L10n.string("Spin up"))
                }
                .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.os1Icon)
            .disabled(isCreating || activeWorkspaceId == nil)

            Button {
                startRefresh()
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 12, weight: .semibold))
            }
            .buttonStyle(.os1Icon)
            .disabled(isLoading)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .background(theme.palette.coral)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.onCoralMuted.opacity(0.18))
                .frame(height: 1)
        }
    }

    private func grid(workspaceId: String) -> some View {
        ScrollView {
            if !loadError.isEmpty {
                Text(loadError)
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .padding(.horizontal, 18)
                    .padding(.top, 12)
            }

            if computers.isEmpty && !isLoading {
                emptyPlaceholder
                    .padding(40)
            } else {
                LazyVGrid(columns: columns, spacing: 14) {
                    ForEach(computers, id: \.id) { computer in
                        tile(for: computer)
                            .id(computer.id)
                    }
                }
                .padding(14)
            }
        }
    }

    private func tile(for computer: OrgoComputerSummary) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(computer.status))
                    .frame(width: 7, height: 7)
                Text(computer.name)
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .lineLimit(1)
                Spacer()
                Text(computer.status)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(theme.palette.coral.opacity(0.85))

            ZStack {
                Color.black
                ScreenshotStreamView(computerId: computer.id)
            }
            .aspectRatio(16.0 / 9.0, contentMode: .fit)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.palette.onCoralMuted.opacity(0.3), lineWidth: 1)
        }
    }

    private var emptyPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "rectangle.split.2x2")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(theme.palette.onCoralMuted)
            Text(L10n.string("No computers in this workspace yet"))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)
            Text(L10n.string("Click \"Spin up\" or ask Samantha to create a new computer."))
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
    }

    private var noWorkspacePlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(theme.palette.onCoralMuted)
            Text(L10n.string("No Orgo workspace selected"))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)
            Text(L10n.string("Pick an Orgo VM connection on the Host tab — Tiles shows every computer in that workspace."))
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Data

    private var activeWorkspaceId: String? {
        guard let connection = appState.activeConnection else { return nil }
        if case .orgo(let cfg) = connection.transport, !cfg.workspaceId.isEmpty {
            return cfg.workspaceId
        }
        return nil
    }

    private func startRefresh() {
        guard let workspaceId = activeWorkspaceId else { return }
        refreshTask?.cancel()
        isLoading = true
        let catalog = appState.orgoCatalogService
        refreshTask = Task { @MainActor in
            defer { isLoading = false }
            do {
                let workspaces = try await catalog.listWorkspaces()
                guard !Task.isCancelled else { return }
                let computersInWorkspace = workspaces.first(where: { $0.id == workspaceId })?.computers ?? []
                self.computers = computersInWorkspace
                self.loadError = ""
                let liveIds = Set(computersInWorkspace.map(\.id))
                self.endpoints = endpoints.filter { liveIds.contains($0.key) }
            } catch {
                guard !Task.isCancelled else { return }
                self.loadError = (error as NSError).localizedDescription
            }
        }
    }

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                guard !Task.isCancelled else { break }
                startRefresh()
            }
        }
    }

    private func ensureEndpoint(for computerId: String) async {
        guard endpoints[computerId] == nil else { return }
        let transport = appState.orgoTransport
        do {
            let endpoint = try await transport.resolveVNCEndpoint(computerId: computerId)
            await MainActor.run { endpoints[computerId] = endpoint }
        } catch {
            // Per-tile failures are expected for spinning-up VMs; ignore here.
            // The next refresh poll will retry.
        }
    }

    private func createComputer() async {
        guard let workspaceId = activeWorkspaceId else { return }
        isCreating = true
        defer { isCreating = false }
        let name = "tile-\(Int(Date().timeIntervalSince1970) % 100000)"
        do {
            _ = try await appState.orgoCatalogService.createComputer(workspaceID: workspaceId, computerName: name)
            startRefresh()
        } catch {
            loadError = (error as NSError).localizedDescription
        }
    }

    private func statusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "running", "ready", "active":
            return .green
        case "starting", "creating", "provisioning":
            return .yellow
        case "stopped", "off":
            return .gray
        default:
            return .orange
        }
    }
}
