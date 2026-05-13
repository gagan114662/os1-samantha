import SwiftUI

struct DoctorView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme
    @ObservedObject var viewModel: DoctorViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                if let err = viewModel.actionError {
                    errorBanner(err)
                }
                if !viewModel.paymentsSnapshot.rows.isEmpty {
                    PaymentsHealthCard(snapshot: viewModel.paymentsSnapshot)
                }
                if !viewModel.fleetSnapshot.workers.isEmpty {
                    DoctorFleetSummaryRows(snapshot: viewModel.fleetSnapshot)
                }
                if !viewModel.checks.isEmpty {
                    DoctorChecksSummaryRow(summary: viewModel.checksSummary, isRunning: viewModel.hasUnresolvedChecks)
                }
                if viewModel.checks.isEmpty {
                    placeholder
                } else {
                    ForEach(viewModel.checks) { check in
                        DoctorCheckCard(check: check, viewModel: viewModel)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: 720, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.palette.coral)
        .onAppear {
            viewModel.setActiveConnection(appState.activeConnection)
            Task { await viewModel.refresh() }
        }
        .onChange(of: appState.activeConnection?.id) { _, _ in
            viewModel.setActiveConnection(appState.activeConnection)
            Task { await viewModel.refresh() }
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(L10n.string("Doctor"))
                    .os1Style(theme.typography.titlePanel)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(subtitle)
                    .os1Style(theme.typography.smallCaps)
                    .foregroundStyle(theme.palette.onCoralMuted)
            }
            Spacer()
            Button {
                Task { await viewModel.refresh() }
            } label: {
                HStack(spacing: 6) {
                    if viewModel.isRefreshing {
                        ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 12, weight: .semibold))
                    }
                    Text(L10n.string("Refresh"))
                }
            }
            .buttonStyle(.os1Secondary)
            .disabled(viewModel.isRefreshing)
        }
    }

    private var subtitle: String {
        if let date = viewModel.lastRefreshedAt {
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .short
            let when = formatter.localizedString(for: date, relativeTo: Date())
            return String(format: L10n.string("Last checked %@."), when)
        }
        return L10n.string("Health checks for this host.")
    }

    @ViewBuilder
    private var placeholder: some View {
        if appState.activeConnection == nil {
            HermesSurfacePanel(
                title: "No host selected",
                subtitle: "Connect to a host on the Host tab to run checks."
            ) { EmptyView() }
        } else if viewModel.isRefreshing {
            HermesSurfacePanel {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                    Text(L10n.string("Running checks…"))
                        .os1Style(theme.typography.body)
                        .foregroundStyle(theme.palette.onCoralSecondary)
                }
            }
        } else {
            HermesSurfacePanel(
                title: "Ready",
                subtitle: "Click Refresh to run checks against this host."
            ) { EmptyView() }
        }
    }

    private func errorBanner(_ message: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.palette.onCoralPrimary)
                .font(.system(size: 14, weight: .semibold))
            Text(message)
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.palette.glassFill)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        }
    }
}

private struct DoctorFleetSummaryRows: View {
    @Environment(\.os1Theme) private var theme
    let snapshot: CompanyFleetHealthSnapshot

    var body: some View {
        HermesSurfacePanel {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(DoctorViewModel.fleetDoctorRows(snapshot: snapshot), id: \.self) { row in
                    HStack(spacing: 8) {
                        Image(systemName: "cpu")
                            .foregroundStyle(theme.palette.onCoralMuted)
                            .frame(width: 18)
                        Text(row)
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                        Spacer()
                    }
                }
            }
        }
    }
}

private struct DoctorChecksSummaryRow: View {
    @Environment(\.os1Theme) private var theme
    let summary: String
    let isRunning: Bool

    var body: some View {
        HermesSurfacePanel {
            HStack(spacing: 10) {
                if isRunning {
                    ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                } else {
                    Image(systemName: "checklist.checked")
                        .foregroundStyle(theme.palette.onCoralMuted)
                        .frame(width: 18)
                }
                Text(summary)
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

private struct DoctorCheckCard: View {
    @Environment(\.os1Theme) private var theme
    let check: DoctorViewModel.Check
    @ObservedObject var viewModel: DoctorViewModel
    @State private var detailExpanded = false

    var body: some View {
        HermesSurfacePanel {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .top, spacing: 10) {
                    if check.state == .running {
                        ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                            .frame(width: 20, alignment: .center)
                    } else {
                        Image(systemName: stateIcon)
                            .foregroundStyle(stateColor)
                            .font(.system(size: 16, weight: .semibold))
                            .frame(width: 20, alignment: .center)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 8) {
                            Text(check.title)
                                .os1Style(theme.typography.titlePanel)
                                .foregroundStyle(theme.palette.onCoralPrimary)
                            Text(stateLabel)
                                .os1Style(theme.typography.smallCaps)
                                .foregroundStyle(theme.palette.onCoralMuted)
                        }
                        Text(check.summary)
                            .os1Style(theme.typography.body)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                }

                if let detail = check.detail, !detail.isEmpty {
                    Button {
                        detailExpanded.toggle()
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: detailExpanded ? "chevron.down" : "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                            Text(detailExpanded
                                ? L10n.string("Hide details")
                                : L10n.string("Show details"))
                                .os1Style(theme.typography.smallCaps)
                        }
                        .foregroundStyle(theme.palette.onCoralSecondary)
                    }
                    .buttonStyle(.plain)

                    if detailExpanded {
                        ScrollView {
                            Text(detail)
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(theme.palette.onCoralPrimary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .textSelection(.enabled)
                                .padding(10)
                        }
                        .frame(maxHeight: 200)
                        .background(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(theme.palette.darkOverlay)
                        )
                    }
                }

                if !check.actions.isEmpty {
                    HStack(spacing: 8) {
                        ForEach(check.actions, id: \.self) { action in
                            Button {
                                Task { await viewModel.runAction(action) }
                            } label: {
                                HStack(spacing: 6) {
                                    if viewModel.actionInFlight == action {
                                        ProgressView().controlSize(.small).tint(theme.palette.onCoralPrimary)
                                    }
                                    Text(actionLabel(action))
                                }
                            }
                            .buttonStyle(.os1Secondary)
                            .disabled(viewModel.actionInFlight != nil)
                        }
                        Spacer()
                    }
                }
            }
        }
    }

    private var stateIcon: String {
        switch check.state {
        case .pending: return "circle.dotted"
        case .running: return "arrow.triangle.2.circlepath"
        case .pass: return "checkmark.circle.fill"
        case .warn: return "exclamationmark.circle.fill"
        case .fail: return "exclamationmark.octagon.fill"
        case .timeout: return "clock.badge.exclamationmark"
        case .skipped: return "forward.end.circle"
        }
    }

    private var stateColor: Color {
        switch check.state {
        case .pending, .running, .skipped: return theme.palette.onCoralMuted
        case .pass: return Color(red: 0.40, green: 0.78, blue: 0.50)   // muted green that reads on coral
        case .warn: return Color(red: 0.96, green: 0.70, blue: 0.30) // amber
        case .fail, .timeout: return Color(red: 0.93, green: 0.46, blue: 0.40) // red-coral
        }
    }

    private var stateLabel: String {
        switch check.state {
        case .pending: return L10n.string("Pending")
        case .running: return L10n.string("Running")
        case .pass: return L10n.string("Pass")
        case .warn: return L10n.string("Warn")
        case .fail: return L10n.string("Fail")
        case .timeout: return L10n.string("Timeout")
        case .skipped: return L10n.string("Skipped")
        }
    }

    private func actionLabel(_ action: DoctorViewModel.Action) -> String {
        switch action {
        case .restartGateway: return L10n.string("Restart gateway")
        case .revalidateTelegram: return L10n.string("Revalidate token")
        case .updateHermes: return L10n.string("Update")
        case .reinstallLaunchAgents: return L10n.string("Reinstall LaunchAgents")
        case .migrateSchema: return L10n.string("Migrate")
        case .retryCheck: return L10n.string("Retry")
        case .openLogs: return L10n.string("Open logs")
        }
    }
}
