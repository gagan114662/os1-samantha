import SwiftUI

struct SessionsView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var splitLayout: HermesSplitLayout
    @State private var searchText = ""

    var body: some View {
        Group {
            if usesFullWidthEmptyState {
                fullWidthSessionStarter
            } else {
                HermesPersistentHSplitView(layout: $splitLayout, detailMinWidth: 420) {
                    primaryContent
                } detail: {
                    sessionDetail
                        .hermesSplitDetailColumn(minWidth: 420, idealWidth: 520)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: appState.activeConnectionID) {
            if appState.sessions.isEmpty {
                await appState.loadSessions(reset: true)
            }
        }
        .task(id: searchText) {
            guard appState.activeConnectionID != nil else { return }

            let normalizedQuery = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard normalizedQuery != appState.sessionSearchQuery else { return }

            try? await Task.sleep(for: .milliseconds(280))
            guard !Task.isCancelled else { return }
            await appState.loadSessions(reset: true, query: searchText)
        }
    }

    private var primaryContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            sessionsToolbar
            sessionsContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .safeAreaPadding(.top, 8)
    }

    private var fullWidthSessionStarter: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            sessionDetail
                .frame(maxWidth: .infinity, minHeight: 560, maxHeight: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .safeAreaPadding(.top, 8)
    }

    private var header: some View {
        HermesPageHeader(
            title: "Sessions",
            subtitle: "Browse the recent Hermes conversations discovered on the active host."
        ) {
            HStack(spacing: 10) {
                HermesRefreshButton(isRefreshing: appState.isRefreshingSessions) {
                    Task { await appState.refreshSessions(query: searchText) }
                }
                .disabled(appState.isLoadingSessions)

                HermesExpandableSearchField(
                    text: $searchText,
                    prompt: L10n.string("Search sessions"),
                    expandedWidth: 220
                )
            }
            .fixedSize(horizontal: true, vertical: false)
        }
    }

    private var sessionDetail: some View {
        SessionDetailView(
            session: selectedSession,
            messages: appState.sessionMessageDisplays,
            errorMessage: appState.sessionsError,
            conversationError: appState.sessionConversationError,
            isSendingMessage: appState.isSendingSessionMessage,
            isDeletingSession: selectedSession.map { selectedSession in
                appState.isDeletingSession && appState.selectedSessionID == selectedSession.id
            } ?? false,
            pendingTurn: appState.pendingSessionTurn,
            onResumeInTerminal: { session in
                appState.resumeSessionInTerminal(session)
            },
            onDeleteSession: { session in
                await appState.deleteSession(session)
            },
            onStartSession: { prompt, autoApproveCommands in
                await appState.startNewSession(
                    with: prompt,
                    autoApproveCommands: autoApproveCommands
                )
            },
            onSendMessage: { prompt, autoApproveCommands in
                await appState.sendMessageToSelectedSession(
                    prompt,
                    autoApproveCommands: autoApproveCommands
                )
            }
        )
    }

    private var usesFullWidthEmptyState: Bool {
        appState.sessions.isEmpty &&
            !appState.isLoadingSessions &&
            appState.sessionsError == nil &&
            appState.pendingSessionTurn == nil
    }

    @ViewBuilder
    private var sessionsContent: some View {
        sessionsPanel
    }

    @ViewBuilder
    private var sessionsPanel: some View {
        if appState.isLoadingSessions && !hasVisibleSessions {
            HermesSurfacePanel {
                HermesLoadingState(
                    label: "Loading sessions…",
                    minHeight: 300
                )
            }
        } else if let error = appState.sessionsError, !hasVisibleSessions {
            HermesSurfacePanel {
                ContentUnavailableView(
                    L10n.string("Unable to load sessions"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        } else if !hasVisibleSessions && !appState.sessionSearchQuery.isEmpty {
            HermesSurfacePanel {
                ContentUnavailableView(
                    L10n.string("No matching sessions"),
                    systemImage: "magnifyingglass",
                    description: Text(L10n.string("Try searching by session name, ID, preview text, or message content."))
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        } else if !hasVisibleSessions {
            HermesSurfacePanel {
                ContentUnavailableView(
                    L10n.string("No sessions found"),
                    systemImage: "tray",
                    description: Text(L10n.string("No readable Hermes sessions were discovered yet for this SSH target."))
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        } else {
            HermesSurfacePanel(
                title: panelTitle,
                subtitle: "Select a session to inspect its transcript, metadata and last activity."
            ) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        if !visiblePinnedSessions.isEmpty {
                            SessionSectionHeader(
                                title: L10n.string(
                                    "Pinned Sessions (%@)",
                                    "\(visiblePinnedSessions.count)"
                                )
                            )

                            ForEach(visiblePinnedSessions) { session in
                                sessionRow(session)
                            }

                            if !visibleStoredSessions.isEmpty {
                                Divider()
                                    .padding(.vertical, 2)

                                SessionSectionHeader(
                                    title: L10n.string("All Sessions (%@)", "\(appState.totalSessionsCount)")
                                )
                            }
                        }

                        ForEach(visibleStoredSessions) { session in
                            sessionRow(session)
                        }

                        if appState.hasMoreSessions {
                            Button(L10n.string("Load More")) {
                                Task { await appState.loadSessions(reset: false) }
                            }
                            .buttonStyle(.os1Secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.top, 6)
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .overlay(alignment: .topTrailing) {
                if appState.isLoadingSessions && !appState.isRefreshingSessions && !appState.sessions.isEmpty {
                    HermesLoadingOverlay()
                        .padding(18)
                }
            }
        }
    }

    private var trimmedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowPinnedSessions: Bool {
        appState.sessionSearchQuery.isEmpty && trimmedSearchText.isEmpty
    }

    private var visiblePinnedSessions: [SessionSummary] {
        shouldShowPinnedSessions ? appState.pinnedSessionSummaries : []
    }

    private var visibleStoredSessions: [SessionSummary] {
        shouldShowPinnedSessions ? appState.unpinnedSessions : appState.sessions
    }

    private var hasVisibleSessions: Bool {
        !visiblePinnedSessions.isEmpty || !visibleStoredSessions.isEmpty
    }

    private func sessionRow(_ session: SessionSummary) -> some View {
        let isPinned = appState.isSessionPinned(session.id)

        return SessionCardRow(
            session: session,
            isSelected: session.id == appState.selectedSessionID,
            isPinned: isPinned,
            onTogglePin: {
                appState.toggleSessionPin(session)
            }
        ) {
            Task {
                await appState.loadSessionDetail(sessionID: session.id)
            }
        }
        // Rows move between two LazyVStack sections when pinned. Include the pin state
        // in the row identity so the pin button subtree is rebuilt with the move.
        .id(SessionCardRowIdentity(sessionID: session.id, isPinned: isPinned))
    }

    private var sessionsToolbar: some View {
        HStack(spacing: 10) {
            HermesCreateActionButton("New Chat") {
                searchText = ""
                appState.prepareNewSessionComposer()
            }
            .disabled(appState.isSendingSessionMessage)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var panelTitle: String {
        if appState.sessionSearchQuery.isEmpty {
            return L10n.string("Sessions Library (%@)", "\(appState.totalSessionsCount)")
        }

        return L10n.string("Matching Sessions (%@)", "\(appState.totalSessionsCount)")
    }

    private var selectedSession: SessionSummary? {
        guard let selectedSessionID = appState.selectedSessionID else { return nil }
        return appState.sessionSummary(for: selectedSessionID)
    }
}

private struct SessionCardRowIdentity: Hashable {
    let sessionID: String
    let isPinned: Bool
}

private struct SessionSectionHeader: View {
    let title: String

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.os1OnCoralSecondary)
            .padding(.horizontal, 2)
    }
}

private struct SessionCardRow: View {
    let session: SessionSummary
    let isSelected: Bool
    let isPinned: Bool
    let onTogglePin: () -> Void
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            content
                .padding(.trailing, 34)
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .fill(isSelected ? Color.os1OnCoralPrimary.opacity(0.12) : Color.os1OnCoralSecondary.opacity(0.08))
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Color.os1OnCoralPrimary.opacity(isSelected ? 0.12 : 0.06), lineWidth: 1)
                }
                .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topTrailing) {
            pinButton
                .padding(.top, 12)
                .padding(.trailing, 14)
        }
    }

    private var pinButton: some View {
        Button(action: onTogglePin) {
            Image(systemName: isPinned ? "pin.fill" : "pin")
                .font(.caption.weight(.semibold))
                .foregroundStyle(isPinned ? Color.os1OnCoralPrimary : Color.os1OnCoralSecondary)
                .frame(width: 24, height: 24)
                .background(
                    Circle()
                        .fill(isPinned ? Color.os1OnCoralPrimary.opacity(0.18) : Color.os1OnCoralSecondary.opacity(0.08))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(pinHelpText)
        .accessibilityLabel(pinHelpText)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(session.resolvedTitle)
                        .font(.os1TitlePanel)
                        .foregroundStyle(.os1OnCoralPrimary)
                        .multilineTextAlignment(.leading)

                    Text(session.id)
                        .font(.os1SmallCaps)
                        .foregroundStyle(.os1OnCoralSecondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                if let count = session.messageCount {
                    HermesBadge(text: L10n.string("%@ messages", "\(count)"), tint: .secondary)
                }
            }

            if let searchMatch = session.searchMatch,
               let snippet = searchMatch.snippet,
               !snippet.isEmpty {
                searchMatchPreview(searchMatch, snippet: snippet)
            } else if let preview = session.preview, !preview.isEmpty {
                Text(preview)
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    if let startedAt = session.startedAt?.dateValue {
                        metaLabel(L10n.string("Started %@", DateFormatters.relativeFormatter().localizedString(for: startedAt, relativeTo: .now)))
                    }

                    if let lastActive = session.lastActive?.dateValue {
                        metaLabel(L10n.string("Active %@", DateFormatters.relativeFormatter().localizedString(for: lastActive, relativeTo: .now)))
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    if let startedAt = session.startedAt?.dateValue {
                        metaLabel(L10n.string("Started %@", DateFormatters.relativeFormatter().localizedString(for: startedAt, relativeTo: .now)))
                    }

                    if let lastActive = session.lastActive?.dateValue {
                        metaLabel(L10n.string("Active %@", DateFormatters.relativeFormatter().localizedString(for: lastActive, relativeTo: .now)))
                    }
                }
            }
        }
    }

    private func searchMatchPreview(_ match: SessionSearchMatch, snippet: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "text.magnifyingglass")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.os1OnCoralPrimary)

                Text(searchMatchLabel(match))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.os1OnCoralPrimary)
            }

            Text(snippet)
                .font(.os1Body)
                .foregroundStyle(.os1OnCoralSecondary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
        }
    }

    private func searchMatchLabel(_ match: SessionSearchMatch) -> String {
        let countText = match.matchCount == 1
            ? L10n.string("1 match")
            : L10n.string("%@ matches", "\(match.matchCount)")

        guard let role = match.role else {
            return countText
        }

        return "\(role.displayTitle) - \(countText)"
    }

    private var pinHelpText: String {
        L10n.string(isPinned ? "Unpin session" : "Pin session")
    }

    private func metaLabel(_ text: String) -> some View {
        Text(text)
            .font(.os1SmallCaps)
            .foregroundStyle(.os1OnCoralSecondary)
    }
}
