import SwiftUI

/// Live view of the active Orgo VM's desktop, rendered as a 2.5-second
/// screenshot stream. Replaces the older noVNC websockify path which
/// returns 404 on current Orgo VMs (gateway no longer exposes the
/// internal websockify port).
///
/// The actual streaming view (`ScreenshotStreamView`) lives in
/// `ScreenshotStreamView.swift` so both Desktop (single VM, big) and
/// Tiles (multi-VM, grid) share one implementation. Single source of
/// truth = no chance of the two views drifting in their VM-rendering
/// behavior. The status badge in the header is driven from the stream's
/// `onStatusChange` callback so it reflects real state (loading/live/
/// stale/failed) instead of always claiming "Streaming".
struct DesktopView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    /// Tracks the stream's actual state so the header badge tells the truth
    /// (loading vs live vs stale vs failed) instead of always saying "Streaming".
    @State private var streamStatus: ScreenshotStreamView.Status = .loading

    var body: some View {
        Group {
            if let computerId = activeOrgoComputerId {
                content(computerId: computerId)
            } else {
                noConnectionPlaceholder
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.coral)
        .onChange(of: activeOrgoComputerId) { _, _ in
            // Reset to .loading on VM swap so we don't carry over a stale "live" badge
            streamStatus = .loading
        }
    }

    // MARK: - Content

    private func content(computerId: String) -> some View {
        VStack(spacing: 0) {
            header(computerId: computerId)
            ZStack {
                Color.black
                ScreenshotStreamView(
                    computerId: computerId,
                    interactive: true,
                    onStatusChange: { status in streamStatus = status }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func header(computerId: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "display")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)
            Text(L10n.string("Desktop"))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)
            Text("·")
                .foregroundStyle(theme.palette.onCoralMuted)
            Text(computerId)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(theme.palette.onCoralMuted)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            statusBadge(for: streamStatus)
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

    @ViewBuilder
    private func statusBadge(for status: ScreenshotStreamView.Status) -> some View {
        switch status {
        case .loading:
            HermesBadge(text: L10n.string("Loading"),
                        tint: .os1OnCoralPrimary,
                        systemImage: "circle.dotted")
        case .live:
            HermesBadge(text: L10n.string("Live"),
                        tint: .os1OnCoralPrimary,
                        systemImage: "dot.radiowaves.left.and.right")
        case .stale(let secondsAgo):
            HermesBadge(text: L10n.string("Stale %lld s", secondsAgo),
                        tint: .os1OnCoralPrimary,
                        systemImage: "exclamationmark.circle")
        case .failed(let reason):
            HermesBadge(text: reason.prefix(40).description,
                        tint: .os1OnCoralPrimary,
                        systemImage: "xmark.octagon")
        }
    }

    private var noConnectionPlaceholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "display.trianglebadge.exclamationmark")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(theme.palette.onCoralMuted)
            Text(L10n.string("No Orgo VM selected"))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)
            Text(L10n.string("Pick an Orgo VM connection on the Host tab to view its desktop."))
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
        }
        .padding(40)
    }

    // MARK: - Active computer id

    private var activeOrgoComputerId: String? {
        guard let connection = appState.activeConnection else { return nil }
        if case .orgo(let cfg) = connection.transport, !cfg.computerId.isEmpty {
            return cfg.computerId
        }
        return nil
    }
}
