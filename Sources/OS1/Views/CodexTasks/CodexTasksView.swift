import SwiftUI

/// Voice-spawnable Codex Tasks. Each task = `codex exec --dangerously-bypass-approvals-and-sandbox`
/// running in its own git worktree under ~/.os1/codex-tasks/sessions/<id>.
struct CodexTasksView: View {
    @Environment(\.os1Theme) private var theme
    @StateObject private var manager = CodexSessionManager.shared

    @State private var newTaskText: String = ""
    @State private var newCompanyName: String = ""
    @State private var newCadenceMinutes: Int = 15
    @State private var spawnError: String = ""
    @State private var selectedID: String?
    @State private var interveneTexts: [String: String] = [:]
    @State private var nowTick: Date = Date()  // drives countdown labels

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            spawnBar
            if manager.sessions.isEmpty {
                emptyPlaceholder
            } else {
                ScrollView { grid }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.palette.coral)
        .onReceive(Timer.publish(every: 5, on: .main, in: .common).autoconnect()) { now in
            nowTick = now
        }
        .sheet(item: Binding(
            get: { selectedID.flatMap { id in manager.sessions.first(where: { $0.id == id }) } },
            set: { _ in selectedID = nil }
        )) { session in
            sessionDetail(session: session)
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "square.grid.2x2.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(theme.palette.onCoralPrimary)
            Text(L10n.string("Tasks"))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)
            Text("·")
                .foregroundStyle(theme.palette.onCoralMuted)
            Text(L10n.string("%lld total", manager.sessions.count))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)
            Spacer()
            Text(L10n.string("running %lld", manager.sessions.filter { $0.status == .running }.count))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(theme.palette.onCoralMuted.opacity(0.18))
                .frame(height: 1)
        }
    }

    // MARK: - Spawn bar

    private var spawnBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                TextField(L10n.string("Company name"), text: $newCompanyName)
                    .textFieldStyle(.plain)
                    .frame(width: 160)
                    .padding(.vertical, 10)
                    .padding(.horizontal, 12)
                    .background(theme.palette.glassFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                TextField(
                    L10n.string("Mission — \"build a YouTube channel that makes $1k/mo from AI tech reviews\""),
                    text: $newTaskText,
                    axis: .vertical
                )
                .textFieldStyle(.plain)
                .lineLimit(1...3)
                .padding(.vertical, 10)
                .padding(.horizontal, 12)
                .background(theme.palette.glassFill)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .onSubmit { spawn() }

                Picker(L10n.string("Heartbeat"), selection: $newCadenceMinutes) {
                    Text("5m").tag(5)
                    Text("15m").tag(15)
                    Text("30m").tag(30)
                    Text("1h").tag(60)
                    Text("4h").tag(240)
                }
                .frame(width: 110)

                Button(L10n.string("Hire")) { spawn() }
                    .buttonStyle(.os1Primary)
                    .disabled(newTaskText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if !spawnError.isEmpty {
                Text(spawnError)
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.danger)
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 10)
    }

    // MARK: - Grid

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(manager.sessions) { session in
                tile(session: session)
                    .onTapGesture { selectedID = session.id }
            }
        }
        .padding(14)
    }

    private func tile(session: CodexSession) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor(session.status))
                    .frame(width: 8, height: 8)
                Text(session.title)
                    .os1Style(theme.typography.titlePanel)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .lineLimit(1)
                Spacer()
                Text(session.status.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
            }

            Text(session.task)
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                Label("hb #\(session.heartbeatCount)", systemImage: "waveform.path.ecg")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.onCoralMuted)
                Label("every \(session.cadenceMinutes)m", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.onCoralMuted)
                Spacer()
                if session.status == .idle, let next = session.nextHeartbeatAt {
                    Label("next \(countdown(to: next))", systemImage: "arrow.right.circle")
                        .font(.caption2)
                        .foregroundStyle(theme.palette.onCoralMuted)
                } else if session.status == .running {
                    Label("running", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }

            if session.status == .blocked, let reason = session.blockedReason {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(reason)
                        .os1Style(theme.typography.label)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                        .lineLimit(3)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.orange.opacity(0.18))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

            // last 4 lines of journal
            let preview = manager.readJournal(id: session.id, maxBytes: 1500)
                .components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
                .suffix(4)
                .joined(separator: "\n")
            if !preview.isEmpty {
                Text(preview)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(4)
            }

            HStack(spacing: 6) {
                TextField(L10n.string("Tell the company what to do…"),
                          text: Binding(
                            get: { interveneTexts[session.id] ?? "" },
                            set: { interveneTexts[session.id] = $0 }))
                    .textFieldStyle(.plain)
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .background(theme.palette.glassFill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .onSubmit { intervene(id: session.id) }

                Button {
                    intervene(id: session.id)
                } label: {
                    Image(systemName: "arrow.up.circle.fill").font(.system(size: 16))
                }
                .buttonStyle(.os1Icon)

                Menu {
                    if session.status == .paused {
                        Button(L10n.string("Resume")) { manager.resume(id: session.id) }
                    } else {
                        Button(L10n.string("Pause")) { manager.pause(id: session.id) }
                    }
                    Button(L10n.string("Run heartbeat now")) {
                        Task { await manager.runHeartbeat(id: session.id) }
                    }
                    Divider()
                    Button(L10n.string("Open journal in Finder")) {
                        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: session.journalPath)])
                    }
                    Divider()
                    Button(L10n.string("Remove company"), role: .destructive) {
                        manager.cleanup(id: session.id)
                    }
                } label: {
                    Image(systemName: "ellipsis.circle").font(.system(size: 14))
                }
                .menuStyle(.borderlessButton)
                .frame(width: 24)
            }
        }
        .padding(12)
        .background(theme.palette.glassFill)
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(
                    session.status == .blocked ? Color.orange.opacity(0.7) : theme.palette.onCoralMuted.opacity(0.3),
                    lineWidth: session.status == .blocked ? 2 : 1
                )
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Detail sheet

    private func sessionDetail(session: CodexSession) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Circle().fill(statusColor(session.status)).frame(width: 10, height: 10)
                Text(session.title).os1Style(theme.typography.titlePanel)
                Spacer()
                Button(L10n.string("Close")) { selectedID = nil }
                    .buttonStyle(.os1Icon)
            }
            HStack(spacing: 14) {
                Label(session.id, systemImage: "number")
                    .font(.system(.caption, design: .monospaced))
                Label(session.branch, systemImage: "arrow.triangle.branch")
                    .font(.caption)
                Label(session.status.rawValue, systemImage: "circle.fill")
                    .font(.caption)
            }
            .foregroundStyle(theme.palette.onCoralMuted)

            Text(L10n.string("Task"))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)
            Text(session.task)
                .os1Style(theme.typography.body)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.palette.glassFill)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(L10n.string("Output (last 8 KB)"))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)
            ScrollView {
                Text(manager.tail(id: session.id, maxBytes: 8192))
                    .font(.system(.caption2, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(Color.black.opacity(0.3))
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(session.worktreePath)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.palette.onCoralMuted)
        }
        .padding(20)
        .frame(width: 760, height: 560)
    }

    // MARK: - Empty state

    private var emptyPlaceholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "square.grid.2x2")
                .font(.system(size: 32, weight: .light))
                .foregroundStyle(theme.palette.onCoralMuted)
            Text(L10n.string("No tasks yet"))
                .os1Style(theme.typography.titlePanel)
                .foregroundStyle(theme.palette.onCoralPrimary)
            Text(L10n.string("Type a task above or ask Samantha to spawn one."))
                .os1Style(theme.typography.body)
                .foregroundStyle(theme.palette.onCoralSecondary)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func spawn() {
        let trimmed = newTaskText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            _ = try manager.createCompany(
                name: newCompanyName.trimmingCharacters(in: .whitespacesAndNewlines),
                mission: trimmed,
                cadenceMinutes: newCadenceMinutes
            )
            newTaskText = ""
            newCompanyName = ""
            spawnError = ""
        } catch {
            spawnError = (error as NSError).localizedDescription
        }
    }

    private func intervene(id: String) {
        let text = (interveneTexts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        manager.injectInstruction(id: id, instruction: text)
        interveneTexts[id] = ""
    }

    private func countdown(to date: Date?) -> String {
        guard let date else { return "—" }
        let interval = date.timeIntervalSince(nowTick)
        if interval <= 0 { return L10n.string("now") }
        if interval < 60 { return "\(Int(interval))s" }
        if interval < 3600 { return "\(Int(interval / 60))m" }
        return "\(Int(interval / 3600))h"
    }

    private func relativeAge(_ date: Date) -> String {
        let interval = Date().timeIntervalSince(date)
        if interval < 60 { return "\(Int(interval))s ago" }
        if interval < 3600 { return "\(Int(interval / 60))m ago" }
        if interval < 86400 { return "\(Int(interval / 3600))h ago" }
        return "\(Int(interval / 86400))d ago"
    }

    private func statusColor(_ status: CodexSession.Status) -> Color {
        switch status {
        case .running:   return .yellow
        case .idle:      return .blue
        case .blocked:   return .orange
        case .paused:    return .gray
        case .completed: return .green
        case .failed:    return .red
        case .killed:    return .gray
        }
    }
}
