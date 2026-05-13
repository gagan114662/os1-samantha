import SwiftUI

struct KanbanView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var splitLayout: HermesSplitLayout

    @State private var searchText = ""
    @State private var statusFilter: KanbanStatusFilter = .all
    @State private var assigneeFilter = KanbanFilterOption.all
    @State private var tenantFilter = KanbanFilterOption.all
    @State private var isCreatingTask = false
    @State private var taskDraft = KanbanTaskDraft()

    var body: some View {
        Group {
            if usesFullWidthEmptyState {
                primaryContent
            } else {
                HermesPersistentHSplitView(layout: $splitLayout, detailMinWidth: 420) {
                    primaryContent
                } detail: {
                    detailContent
                        .hermesSplitDetailColumn(minWidth: 420, idealWidth: 560)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: appState.activeConnectionID) {
            if appState.kanbanBoard == nil {
                await appState.loadKanbanBoard()
            }
        }
        .onChange(of: appState.includeArchivedKanbanTasks) { _, includeArchived in
            Task { await appState.refreshKanbanBoard(includeArchived: includeArchived) }
        }
        .onChange(of: statusFilter) { _, filter in
            if filter == .archived, !appState.includeArchivedKanbanTasks {
                appState.includeArchivedKanbanTasks = true
            }
        }
    }

    private var usesFullWidthEmptyState: Bool {
        guard let board = appState.kanbanBoard else { return false }
        return !appState.isLoadingKanbanBoard &&
            appState.kanbanError == nil &&
            !isCreatingTask &&
            (!board.isInitialized || board.tasks.isEmpty)
    }

    private var primaryContent: some View {
        VStack(alignment: .leading, spacing: 18) {
            HermesPageHeader(
                title: "Kanban",
                subtitle: "Inspect and operate the host-wide Hermes Kanban board over SSH."
            ) {
                HStack(spacing: 10) {
                    HermesRefreshButton(isRefreshing: appState.isRefreshingKanbanBoard) {
                        Task { await appState.refreshKanbanBoard() }
                    }
                    .disabled(appState.isLoadingKanbanBoard || appState.isSavingKanbanTaskDraft)

                    HermesExpandableSearchField(
                        text: $searchText,
                        prompt: L10n.string("Search tasks"),
                        expandedWidth: 220
                    )
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            kanbanToolbar
            boardContent
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, 20)
        .padding(.vertical, 20)
        .safeAreaPadding(.top, 8)
    }

    private var kanbanToolbar: some View {
        HStack(spacing: 8) {
            statusPicker
            createTaskButton
            dispatchButton
            advancedFilterMenu
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusPicker: some View {
        HStack(spacing: 6) {
            Text(L10n.string("Status"))
                .font(.caption.weight(.semibold))
                .foregroundStyle(.os1OnCoralSecondary)

            Picker("", selection: $statusFilter) {
                ForEach(KanbanStatusFilter.allCases, id: \.self) { option in
                    Text(L10n.string(option.title)).tag(option)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .controlSize(.small)
            .frame(width: 112)
        }
        .fixedSize(horizontal: true, vertical: false)
    }

    private var createTaskButton: some View {
        HermesCreateActionButton("New Task", help: "Create a Kanban task") {
            taskDraft = KanbanTaskDraft()
            isCreatingTask = true
        }
        .disabled(appState.isSavingKanbanTaskDraft || appState.isOperatingOnKanbanTask)
    }

    private var dispatchButton: some View {
        Button {
            Task { await appState.dispatchKanbanNow() }
        } label: {
            if appState.isDispatchingKanban {
                ProgressView()
                    .controlSize(.small)
                    .frame(width: 14, height: 14)
            } else {
                Label(L10n.string("Dispatch"), systemImage: "paperplane")
                    .labelStyle(.iconOnly)
            }
        }
        .buttonStyle(.os1Secondary)
        .controlSize(.small)
        .help(L10n.string("Nudge the remote Kanban dispatcher once"))
        .disabled(appState.isDispatchingKanban || appState.isLoadingKanbanBoard)
    }

    private var advancedFilterMenu: some View {
        Menu {
            Section {
                Button {
                    assigneeFilter = .all
                } label: {
                    menuLabel("All assignees", isSelected: assigneeFilter == .all)
                }

                ForEach(assigneeOptions, id: \.self) { assignee in
                    Button {
                        assigneeFilter = .value(assignee)
                    } label: {
                        menuLabel(assignee, isSelected: assigneeFilter == .value(assignee), shouldLocalize: false)
                    }
                }
            } header: {
                Text(L10n.string("Assignee"))
            }

            Section {
                Button {
                    tenantFilter = .all
                } label: {
                    menuLabel("All tenants", isSelected: tenantFilter == .all)
                }

                ForEach(tenantOptions, id: \.self) { tenant in
                    Button {
                        tenantFilter = .value(tenant)
                    } label: {
                        menuLabel(tenant, isSelected: tenantFilter == .value(tenant), shouldLocalize: false)
                    }
                }
            } header: {
                Text(L10n.string("Tenant"))
            }

            Divider()

            Button {
                appState.includeArchivedKanbanTasks.toggle()
            } label: {
                menuLabel("Archived", isSelected: appState.includeArchivedKanbanTasks)
            }
        } label: {
            Label(
                L10n.string("Filter"),
                systemImage: hasAdvancedFilters ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle"
            )
        }
        .buttonStyle(.os1Secondary)
        .controlSize(.small)
        .tint(hasAdvancedFilters ? .accentColor : nil)
    }

    private func menuLabel(_ text: String, isSelected: Bool, shouldLocalize: Bool = true) -> some View {
        Group {
            if isSelected {
                Label(shouldLocalize ? L10n.string(text) : text, systemImage: "checkmark")
            } else {
                Text(shouldLocalize ? L10n.string(text) : text)
            }
        }
    }

    private var hasAdvancedFilters: Bool {
        assigneeFilter != .all ||
            tenantFilter != .all ||
            appState.includeArchivedKanbanTasks
    }

    @ViewBuilder
    private var boardContent: some View {
        if appState.isLoadingKanbanBoard && appState.kanbanBoard == nil {
            HermesSurfacePanel {
                HermesLoadingState(
                    label: "Loading Kanban board...",
                    minHeight: 320
                )
            }
        } else if let error = appState.kanbanError, appState.kanbanBoard == nil {
            HermesSurfacePanel {
                ContentUnavailableView(
                    L10n.string("Unable to load Kanban"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, minHeight: 320)
            }
        } else if let board = appState.kanbanBoard, !board.isInitialized {
            HermesSurfacePanel {
                VStack(alignment: .leading, spacing: 18) {
                    ContentUnavailableView(
                        L10n.string("No Kanban board yet"),
                        systemImage: "rectangle.3.group",
                        description: Text(L10n.string("No host-wide Kanban database exists at %@. Create the first task to initialize it on the remote host.", board.databasePath))
                    )
                    .frame(maxWidth: .infinity, minHeight: 260)

                    Button {
                        taskDraft = KanbanTaskDraft()
                        isCreatingTask = true
                    } label: {
                        Label(L10n.string("Create First Task"), systemImage: "plus")
                    }
                    .buttonStyle(.os1Primary)
                    .disabled(appState.isSavingKanbanTaskDraft)
                }
            }
        } else if let board = appState.kanbanBoard {
            HermesSurfacePanel(
                title: panelTitle,
                subtitle: boardSubtitle(board)
            ) {
                VStack(alignment: .leading, spacing: 12) {
                    if let warning = dispatcherWarning(for: board) {
                        KanbanWarningBanner(message: warning)
                    }

                    if let error = appState.kanbanError {
                        Text(error)
                            .foregroundStyle(.os1OnCoralPrimary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.os1OnCoralPrimary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
                    }

                    if filteredTasks.isEmpty {
                        ContentUnavailableView(
                            L10n.string("No matching tasks"),
                            systemImage: "magnifyingglass",
                            description: Text(L10n.string("Try a different search, status, assignee, tenant, or archive filter."))
                        )
                        .frame(maxWidth: .infinity, minHeight: 320)
                    } else {
                        ViewThatFits(in: .horizontal) {
                            kanbanBoardLayout(board)
                                .frame(minWidth: 920)

                            ScrollView {
                                kanbanGroupedList(board)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .overlay(alignment: .topTrailing) {
                if appState.isLoadingKanbanBoard && !appState.isRefreshingKanbanBoard {
                    HermesLoadingOverlay()
                        .padding(18)
                }
            }
        }
    }

    private func kanbanBoardLayout(_ board: KanbanBoard) -> some View {
        ScrollView([.horizontal, .vertical]) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(displayStatuses, id: \.rawValue) { status in
                    KanbanColumnView(
                        status: status,
                        tasks: filteredTasks(for: status),
                        selectedTaskID: appState.selectedKanbanTaskID,
                        onSelect: selectTask
                    )
                    .frame(width: 250)
                }
            }
            .padding(.bottom, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func kanbanGroupedList(_ board: KanbanBoard) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(displayStatuses, id: \.rawValue) { status in
                let tasks = filteredTasks(for: status)
                if !tasks.isEmpty {
                    VStack(alignment: .leading, spacing: 10) {
                        HStack(spacing: 8) {
                            Text(L10n.string(status.displayTitle))
                                .font(.os1TitlePanel)

                            HermesBadge(text: "\(tasks.count)", tint: KanbanColors.tint(for: status))
                        }

                        LazyVStack(alignment: .leading, spacing: 10) {
                            ForEach(tasks) { task in
                                KanbanTaskCard(
                                    task: task,
                                    isSelected: task.id == appState.selectedKanbanTaskID,
                                    onSelect: { selectTask(task) }
                                )
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private var detailContent: some View {
        if isCreatingTask {
            KanbanTaskEditorView(
                draft: $taskDraft,
                errorMessage: appState.kanbanError,
                isSaving: appState.isSavingKanbanTaskDraft,
                assignees: assigneeOptions,
                onCancel: {
                    isCreatingTask = false
                },
                onSave: {
                    if await appState.createKanbanTask(taskDraft) {
                        isCreatingTask = false
                    }
                }
            )
        } else {
            KanbanTaskDetailView(
                task: selectedTask,
                detail: appState.selectedKanbanTaskDetail,
                errorMessage: appState.kanbanError,
                isLoading: appState.isLoadingKanbanTaskDetail,
                operationInFlight: selectedTask.map { task in
                    appState.isOperatingOnKanbanTask && appState.operatingKanbanTaskID == task.id
                } ?? false,
                assignees: assigneeOptions,
                onCreate: {
                    taskDraft = KanbanTaskDraft()
                    isCreatingTask = true
                },
                onAssign: { taskID, assignee in
                    await appState.assignKanbanTask(taskID: taskID, assignee: assignee)
                },
                onComment: { taskID, comment in
                    await appState.addKanbanComment(taskID: taskID, body: comment)
                },
                onBlock: { taskID, reason in
                    await appState.blockKanbanTask(taskID: taskID, reason: reason)
                },
                onUnblock: { taskID in
                    await appState.unblockKanbanTask(taskID: taskID)
                },
                onComplete: { taskID, result in
                    await appState.completeKanbanTask(taskID: taskID, result: result)
                },
                onArchive: { taskID in
                    await appState.archiveKanbanTask(taskID: taskID)
                },
                onDelete: { taskID in
                    await appState.deleteKanbanTask(taskID: taskID)
                }
            )
        }
    }

    private var filteredTasks: [KanbanTask] {
        guard let board = appState.kanbanBoard else { return [] }
        return board.tasks.filter { task in
            if !appState.includeArchivedKanbanTasks && task.status == .archived {
                return false
            }
            if let status = statusFilter.status, task.status != status {
                return false
            }
            if case .value(let assignee) = assigneeFilter, task.assignee != assignee {
                return false
            }
            if case .value(let tenant) = tenantFilter, task.tenant != tenant {
                return false
            }
            return task.matchesSearch(searchText)
        }
    }

    private func filteredTasks(for status: KanbanTaskStatus) -> [KanbanTask] {
        filteredTasks.filter { $0.status == status }
    }

    private var displayStatuses: [KanbanTaskStatus] {
        if let status = statusFilter.status {
            return [status]
        }

        return KanbanTaskStatus.boardStatuses.filter { status in
            status != .archived || appState.includeArchivedKanbanTasks
        }
    }

    private var assigneeOptions: [String] {
        let boardAssignees = appState.kanbanBoard?.assignees.map(\.name) ?? []
        let taskAssignees = appState.kanbanBoard?.tasks.compactMap(\.assignee) ?? []
        return Array(Set(boardAssignees + taskAssignees)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var tenantOptions: [String] {
        let boardTenants = appState.kanbanBoard?.tenants ?? []
        let taskTenants = appState.kanbanBoard?.tasks.compactMap(\.tenant) ?? []
        return Array(Set(boardTenants + taskTenants)).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var selectedTask: KanbanTask? {
        appState.kanbanBoard?.task(id: appState.selectedKanbanTaskID)
    }

    private var panelTitle: String {
        let total = appState.kanbanBoard?.tasks.count ?? 0
        let filtered = filteredTasks.count
        let isFiltering = statusFilter != .all ||
            assigneeFilter != .all ||
            tenantFilter != .all ||
            !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            appState.includeArchivedKanbanTasks

        if isFiltering {
            return L10n.string("Kanban Tasks (%@ of %@)", "\(filtered)", "\(total)")
        }

        return L10n.string("Kanban Tasks (%@)", "\(total)")
    }

    private func boardSubtitle(_ board: KanbanBoard) -> String {
        "Host-wide board at \(board.databasePath). The selected Hermes profile is used as operator context, not as board scope."
    }

    private func dispatcherWarning(for board: KanbanBoard) -> String? {
        guard board.tasks.contains(where: { $0.status == .ready }) else { return nil }
        guard board.dispatcher?.isKnownInactive == true else { return nil }
        return board.dispatcher?.message ?? "Ready tasks are waiting, but the remote Hermes dispatcher does not appear to be active."
    }

    private func selectTask(_ task: KanbanTask) {
        Task { await appState.loadKanbanTaskDetail(taskID: task.id) }
    }
}

private enum KanbanStatusFilter: Hashable, CaseIterable {
    case all
    case triage
    case todo
    case ready
    case running
    case blocked
    case done
    case archived

    var title: String {
        switch self {
        case .all:
            "All"
        case .triage:
            "Triage"
        case .todo:
            "Todo"
        case .ready:
            "Ready"
        case .running:
            "Running"
        case .blocked:
            "Blocked"
        case .done:
            "Done"
        case .archived:
            "Archived"
        }
    }

    var status: KanbanTaskStatus? {
        switch self {
        case .all:
            nil
        case .triage:
            .triage
        case .todo:
            .todo
        case .ready:
            .ready
        case .running:
            .running
        case .blocked:
            .blocked
        case .done:
            .done
        case .archived:
            .archived
        }
    }
}

private enum KanbanFilterOption: Hashable {
    case all
    case value(String)

    var displayTitle: String {
        switch self {
        case .all:
            L10n.string("All")
        case .value(let value):
            value
        }
    }
}

private enum KanbanActionKind: Hashable {
    case assign
    case comment
    case complete
    case block
}

private enum KanbanColors {
    static func tint(for status: KanbanTaskStatus) -> Color {
        switch status {
        case .triage:
            .secondary
        case .todo:
            .blue
        case .ready:
            .green
        case .running:
            .orange
        case .blocked:
            .red
        case .done:
            .purple
        case .archived:
            .secondary
        case .other:
            .secondary
        }
    }
}

private struct KanbanWarningBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.os1OnCoralPrimary)

            Text(message)
                .font(.os1Body)
                .foregroundStyle(.os1OnCoralSecondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.os1OnCoralPrimary.opacity(0.10), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private struct KanbanColumnView: View {
    let status: KanbanTaskStatus
    let tasks: [KanbanTask]
    let selectedTaskID: String?
    let onSelect: (KanbanTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(L10n.string(status.displayTitle))
                    .font(.os1TitlePanel)

                HermesBadge(text: "\(tasks.count)", tint: KanbanColors.tint(for: status))
            }

            LazyVStack(alignment: .leading, spacing: 10) {
                if tasks.isEmpty {
                    Text(L10n.string("No tasks"))
                        .font(.os1SmallCaps)
                        .foregroundStyle(.os1OnCoralSecondary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.os1OnCoralSecondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                } else {
                    ForEach(tasks) { task in
                        KanbanTaskCard(
                            task: task,
                            isSelected: task.id == selectedTaskID,
                            onSelect: { onSelect(task) }
                        )
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(Color.os1OnCoralSecondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct KanbanTaskCard: View {
    let task: KanbanTask
    let isSelected: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 8) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(task.resolvedTitle)
                            .font(.os1TitlePanel)
                            .foregroundStyle(.os1OnCoralPrimary)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)

                        Text(task.shortID)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.os1OnCoralSecondary)
                    }

                    Spacer(minLength: 8)

                    HermesBadge(text: task.priorityLabel, tint: task.priority == 0 ? .secondary : .orange, isMonospaced: true)
                }

                if let body = task.trimmedBody {
                    Text(body.replacingOccurrences(of: "\n", with: " "))
                        .font(.os1Body)
                        .foregroundStyle(.os1OnCoralSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HermesWrappingFlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
                    if let assignee = task.assignee {
                        HermesBadge(text: "@\(assignee)", tint: .accentColor, isMonospaced: true)
                    }

                    if let tenant = task.tenant {
                        HermesBadge(text: tenant, tint: .secondary)
                    }

                    if task.commentCount > 0 {
                        HermesBadge(text: "\(task.commentCount) comments", tint: .secondary)
                    }

                    if let progress = task.progressLabel {
                        HermesBadge(text: progress, tint: .green, isMonospaced: true)
                    }

                    if !task.parentIDs.isEmpty {
                        HermesBadge(text: "\(task.parentIDs.count) deps", tint: .secondary)
                    }
                }

                if let latest = task.latestActivityDate {
                    Text(L10n.string("Active %@", DateFormatters.relativeFormatter().localizedString(for: latest, relativeTo: .now)))
                        .font(.os1SmallCaps)
                        .foregroundStyle(.os1OnCoralSecondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 11)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(isSelected ? Color.os1OnCoralPrimary.opacity(0.14) : Color.os1GlassFill)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(Color.os1OnCoralPrimary.opacity(isSelected ? 0.16 : 0.07), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct KanbanTaskEditorView: View {
    @Binding var draft: KanbanTaskDraft
    let errorMessage: String?
    let isSaving: Bool
    let assignees: [String]
    let onCancel: () -> Void
    let onSave: () async -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HermesSurfacePanel {
                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(L10n.string("New Kanban Task"))
                                .font(.os1TitleSection)
                                .fontWeight(.semibold)

                            Text(L10n.string("The task will be created in the host-wide Hermes Kanban board over SSH."))
                                .font(.os1Body)
                                .foregroundStyle(.os1OnCoralSecondary)
                        }

                        HStack(spacing: 10) {
                            Button(L10n.string("Create Task")) {
                                Task { await onSave() }
                            }
                            .buttonStyle(.os1Primary)
                            .disabled(isSaving || draft.validationError != nil)

                            Button(L10n.string("Cancel"), action: onCancel)
                                .buttonStyle(.os1Secondary)
                                .disabled(isSaving)

                            if isSaving {
                                ProgressView()
                                    .controlSize(.small)
                            }
                        }

                        if let validationError = draft.validationError {
                            HermesValidationMessage(text: validationError)
                        }
                    }
                }

                if let errorMessage {
                    KanbanWarningBanner(message: errorMessage)
                }

                HermesSurfacePanel(
                    title: "Task",
                    subtitle: "Describe the work and optionally assign it to a Hermes profile."
                ) {
                    VStack(alignment: .leading, spacing: 14) {
                        KanbanFormField(label: "Title") {
                            TextField(L10n.string("Investigate failing release check"), text: $draft.title)
                                .os1Underlined()
                        }

                        KanbanFormField(label: "Body") {
                            TextEditor(text: $draft.body)
                                .scrollContentBackground(.hidden)
                                .foregroundStyle(.os1OnCoralPrimary)
                                .font(.os1Body)
                                .frame(minHeight: 160)
                                .padding(10)
                                .background(
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .fill(Color.os1GlassFill)
                                )
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                                        .strokeBorder(Color.os1OnCoralPrimary.opacity(0.08), lineWidth: 1)
                                }
                        }

                        HStack(alignment: .top, spacing: 14) {
                            KanbanFormField(label: "Assignee") {
                                ComboBoxTextField(text: $draft.assignee, suggestions: assignees, placeholder: "researcher")
                            }

                            KanbanFormField(label: "Tenant") {
                                TextField(L10n.string("optional"), text: $draft.tenant)
                                    .os1Underlined()
                            }
                        }

                        HStack(alignment: .top, spacing: 16) {
                            KanbanFormField(label: "Priority") {
                                VStack(alignment: .leading, spacing: 5) {
                                    TextField("0", value: $draft.priority, format: .number)
                                        .os1Underlined()
                                        .frame(width: 96)

                                    Text(L10n.string("Higher values sort first. 0 is the Hermes default."))
                                        .font(.os1SmallCaps)
                                        .foregroundStyle(.os1OnCoralSecondary)
                                }
                            }

                            Toggle(L10n.string("Start in triage"), isOn: $draft.startsInTriage)
                                .toggleStyle(.checkbox)
                                .padding(.top, 20)
                        }

                        KanbanFormField(label: "Skills") {
                            TextField(L10n.string("deploy-check, release-notes"), text: $draft.skillsText)
                                .os1Underlined()
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
    }
}

private struct KanbanTaskDetailView: View {
    let task: KanbanTask?
    let detail: KanbanTaskDetail?
    let errorMessage: String?
    let isLoading: Bool
    let operationInFlight: Bool
    let assignees: [String]
    let onCreate: () -> Void
    let onAssign: (String, String?) async -> Void
    let onComment: (String, String) async -> Bool
    let onBlock: (String, String?) async -> Void
    let onUnblock: (String) async -> Void
    let onComplete: (String, String?) async -> Void
    let onArchive: (String) async -> Void
    let onDelete: (String) async -> Void

    @State private var draft = KanbanActionDraft()
    @State private var showArchiveConfirmation = false
    @State private var showDeleteConfirmation = false
    @State private var expandedAction: KanbanActionKind?

    private let metadataColumns = [
        GridItem(.adaptive(minimum: 160), alignment: .topLeading)
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if let task {
                    headerPanel(task)

                    if let errorMessage {
                        KanbanWarningBanner(message: errorMessage)
                    }

                    if isLoading && detail == nil {
                        HermesSurfacePanel {
                            HermesLoadingState(label: "Loading task detail...", minHeight: 180)
                        }
                    } else {
                        metadataPanel(task)
                        actionPanel(task)

                        if let body = task.trimmedBody {
                            HermesSurfacePanel(
                                title: "Body",
                                subtitle: "Task description stored on the remote board."
                            ) {
                                HermesInsetSurface {
                                    Text(body)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }

                        if let result = task.trimmedResult {
                            HermesSurfacePanel(
                                title: "Result",
                                subtitle: "Completion handoff stored by Hermes."
                            ) {
                                HermesInsetSurface {
                                    Text(result)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .textSelection(.enabled)
                                }
                            }
                        }

                        if let detail {
                            linksPanel(detail)
                            commentsPanel(task, detail)
                            runsPanel(detail)
                            eventsPanel(detail)
                            logPanel(detail)
                        }
                    }
                } else {
                    HermesSurfacePanel {
                        VStack(alignment: .leading, spacing: 18) {
                            ContentUnavailableView(
                                L10n.string("Select a Kanban task"),
                                systemImage: "rectangle.3.group",
                                description: Text(L10n.string("Choose a task from the host-wide board, or create a new one."))
                            )
                            .frame(maxWidth: .infinity, minHeight: 280)

                            Button {
                                onCreate()
                            } label: {
                                Label(L10n.string("Create Kanban Task"), systemImage: "plus")
                            }
                            .buttonStyle(.os1Primary)
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            .padding(.vertical, 22)
        }
        .onChange(of: task?.id) { _, _ in
            draft = KanbanActionDraft(
                comment: "",
                result: "",
                blockReason: "",
                assignee: task?.assignee ?? ""
            )
            expandedAction = nil
        }
        .onAppear {
            draft.assignee = task?.assignee ?? ""
        }
        .alert(L10n.string("Archive this task?"), isPresented: $showArchiveConfirmation, presenting: task) { task in
            Button(L10n.string("Archive"), role: .destructive) {
                Task { await onArchive(task.id) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: { task in
            Text(L10n.string("“%@” will be hidden from the active board unless archived tasks are shown.", task.resolvedTitle))
        }
        .alert(L10n.string("Delete this task?"), isPresented: $showDeleteConfirmation, presenting: task) { task in
            Button(L10n.string("Delete"), role: .destructive) {
                Task { await onDelete(task.id) }
            }
            Button(L10n.string("Cancel"), role: .cancel) {}
        } message: { task in
            Text(L10n.string("“%@” will be permanently removed from the remote Kanban database, including comments, links, events, and run history. Remote workspace files are left untouched.", task.resolvedTitle))
        }
    }

    private func headerPanel(_ task: KanbanTask) -> some View {
        HermesSurfacePanel {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(task.resolvedTitle)
                            .font(.os1TitleSection)
                            .fontWeight(.semibold)

                        Text(task.id)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.os1OnCoralSecondary)
                            .textSelection(.enabled)
                    }

                    Spacer(minLength: 12)

                    HStack(spacing: 8) {
                        HermesBadge(text: task.status.displayTitle, tint: KanbanColors.tint(for: task.status))
                        HermesBadge(text: task.priorityLabel, tint: task.priority == 0 ? .secondary : .orange, isMonospaced: true)
                    }
                }

                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        primaryActions(task)
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        primaryActions(task)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func primaryActions(_ task: KanbanTask) -> some View {
        if task.canUnblock {
            Button(L10n.string("Unblock")) {
                Task { await onUnblock(task.id) }
            }
            .buttonStyle(.os1Primary)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(operationInFlight)
        }

        if task.canComplete {
            if task.status == .blocked {
                Button(L10n.string("Complete")) {
                    toggleAction(.complete)
                }
                .buttonStyle(.os1Secondary)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(operationInFlight)
            } else {
                Button(L10n.string("Complete")) {
                    toggleAction(.complete)
                }
                .buttonStyle(.os1Primary)
                .fixedSize(horizontal: true, vertical: false)
                .disabled(operationInFlight)
            }
        }

        if task.canBlock {
            Button(L10n.string("Block")) {
                toggleAction(.block)
            }
            .buttonStyle(.os1Secondary)
            .fixedSize(horizontal: true, vertical: false)
            .disabled(operationInFlight)
        }

        Button(L10n.string("Archive"), role: .destructive) {
            showArchiveConfirmation = true
        }
        .buttonStyle(.os1Secondary)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(operationInFlight || task.status == .archived)

        Button(L10n.string("Delete"), role: .destructive) {
            showDeleteConfirmation = true
        }
        .buttonStyle(.os1Secondary)
        .fixedSize(horizontal: true, vertical: false)
        .disabled(operationInFlight)

        if operationInFlight {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func metadataPanel(_ task: KanbanTask) -> some View {
        HermesSurfacePanel(
            title: "Details",
            subtitle: "Board metadata from the remote host."
        ) {
            LazyVGrid(columns: metadataColumns, alignment: .leading, spacing: 14) {
                HermesLabeledValue(label: "Status", value: L10n.string(task.status.displayTitle), emphasizeValue: true)
                HermesLabeledValue(label: "Assignee", value: task.assignee ?? L10n.string("Unassigned"), isMonospaced: task.assignee != nil)
                HermesLabeledValue(label: "Priority", value: "\(task.priority)", isMonospaced: true)
                HermesLabeledValue(label: "Workspace", value: L10n.string(task.workspaceKind.displayTitle))

                if let workspacePath = task.workspacePath {
                    HermesLabeledValue(label: "Workspace path", value: workspacePath, isMonospaced: true)
                }

                if let progress = task.progressLabel {
                    HermesLabeledValue(label: "Child progress", value: progress, isMonospaced: true)
                }

                if let tenant = task.tenant {
                    HermesLabeledValue(label: "Tenant", value: tenant, isMonospaced: true)
                }

                if let createdBy = task.createdBy {
                    HermesLabeledValue(label: "Created by", value: createdBy, isMonospaced: true)
                }

                if let created = task.createdDate {
                    HermesLabeledValue(label: "Created", value: DateFormatters.shortDateTimeFormatter().string(from: created))
                }

                if let latest = task.latestActivityDate {
                    HermesLabeledValue(label: "Latest activity", value: DateFormatters.shortDateTimeFormatter().string(from: latest))
                }

                if let workerPID = task.workerPID {
                    HermesLabeledValue(label: "Worker PID", value: "\(workerPID)", isMonospaced: true)
                }

                if let heartbeat = task.lastHeartbeatAt {
                    HermesLabeledValue(
                        label: "Heartbeat",
                        value: DateFormatters.shortDateTimeFormatter().string(from: Date(timeIntervalSince1970: TimeInterval(heartbeat)))
                    )
                }
            }

            if !task.skills.isEmpty {
                Divider()
                    .opacity(0.5)

                HermesWrappingFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(task.skills, id: \.self) { skill in
                        HermesBadge(text: skill, tint: .accentColor, isMonospaced: true)
                    }
                }
            }

            if let lastSpawnError = task.lastSpawnError {
                Divider()
                    .opacity(0.5)

                KanbanWarningBanner(message: lastSpawnError)
            }
        }
    }

    private func actionPanel(_ task: KanbanTask) -> some View {
        HermesSurfacePanel(
            title: "Update Task",
            subtitle: nil
        ) {
            VStack(alignment: .leading, spacing: 0) {
                KanbanActionDisclosureRow(
                    title: "Assignee",
                    summary: task.assignee.map { "@\($0)" } ?? "Unassigned",
                    systemImage: "person.crop.circle",
                    isExpanded: expandedAction == .assign,
                    isDisabled: operationInFlight,
                    onToggle: { toggleAction(.assign) }
                ) {
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) {
                            ComboBoxTextField(text: $draft.assignee, suggestions: assignees, placeholder: "unassigned")

                            Button(L10n.string("Apply")) {
                                Task {
                                    await onAssign(task.id, draft.normalizedAssignee)
                                    expandedAction = nil
                                }
                            }
                            .buttonStyle(.os1Primary)
                            .disabled(operationInFlight || draft.normalizedAssignee == task.assignee)
                        }

                        VStack(alignment: .leading, spacing: 8) {
                            ComboBoxTextField(text: $draft.assignee, suggestions: assignees, placeholder: "unassigned")

                            Button(L10n.string("Apply")) {
                                Task {
                                    await onAssign(task.id, draft.normalizedAssignee)
                                    expandedAction = nil
                                }
                            }
                            .buttonStyle(.os1Primary)
                            .disabled(operationInFlight || draft.normalizedAssignee == task.assignee)
                        }
                    }
                }

                KanbanActionDivider()

                KanbanActionDisclosureRow(
                    title: "Comment",
                    summary: "Add a note to the task history",
                    systemImage: "text.bubble",
                    isExpanded: expandedAction == .comment,
                    isDisabled: operationInFlight,
                    onToggle: { toggleAction(.comment) }
                ) {
                    VStack(alignment: .trailing, spacing: 8) {
                        KanbanTextEditor(text: $draft.comment, placeholder: L10n.string("Write a short update..."))

                        Button(L10n.string("Add Comment")) {
                            Task {
                                if await onComment(task.id, draft.comment) {
                                    draft.comment = ""
                                    expandedAction = nil
                                }
                            }
                        }
                        .buttonStyle(.os1Secondary)
                        .disabled(operationInFlight || draft.normalizedComment == nil)
                    }
                }

                if task.canComplete {
                    KanbanActionDivider()

                    KanbanActionDisclosureRow(
                        title: "Complete",
                        summary: "Finish the task with an optional handoff",
                        systemImage: "checkmark.circle",
                        isExpanded: expandedAction == .complete,
                        isDisabled: operationInFlight,
                        onToggle: { toggleAction(.complete) }
                    ) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                TextField(L10n.string("Optional handoff summary"), text: $draft.result)
                                    .os1Underlined()

                                Button(L10n.string("Complete")) {
                                    Task {
                                        await onComplete(task.id, draft.normalizedResult)
                                        expandedAction = nil
                                    }
                                }
                                .buttonStyle(.os1Primary)
                                .disabled(operationInFlight)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                TextField(L10n.string("Optional handoff summary"), text: $draft.result)
                                    .os1Underlined()

                                Button(L10n.string("Complete")) {
                                    Task {
                                        await onComplete(task.id, draft.normalizedResult)
                                        expandedAction = nil
                                    }
                                }
                                .buttonStyle(.os1Primary)
                                .disabled(operationInFlight)
                            }
                        }
                    }
                }

                if task.canBlock {
                    KanbanActionDivider()

                    KanbanActionDisclosureRow(
                        title: "Block",
                        summary: "Pause the task and record the reason",
                        systemImage: "hand.raised",
                        isExpanded: expandedAction == .block,
                        isDisabled: operationInFlight,
                        onToggle: { toggleAction(.block) }
                    ) {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 8) {
                                TextField(L10n.string("Optional reason"), text: $draft.blockReason)
                                    .os1Underlined()

                                Button(L10n.string("Block")) {
                                    Task {
                                        await onBlock(task.id, draft.normalizedBlockReason)
                                        expandedAction = nil
                                    }
                                }
                                .buttonStyle(.os1Secondary)
                                .disabled(operationInFlight)
                            }

                            VStack(alignment: .leading, spacing: 8) {
                                TextField(L10n.string("Optional reason"), text: $draft.blockReason)
                                    .os1Underlined()

                                Button(L10n.string("Block")) {
                                    Task {
                                        await onBlock(task.id, draft.normalizedBlockReason)
                                        expandedAction = nil
                                    }
                                }
                                .buttonStyle(.os1Secondary)
                                .disabled(operationInFlight)
                            }
                        }
                    }
                }
            }
        }
    }

    private func toggleAction(_ action: KanbanActionKind) {
        withAnimation(.snappy(duration: 0.16)) {
            expandedAction = expandedAction == action ? nil : action
        }
    }

    private func linksPanel(_ detail: KanbanTaskDetail) -> some View {
        HermesSurfacePanel(
            title: "Dependencies",
            subtitle: "Parent and child task links discovered on the board."
        ) {
            VStack(alignment: .leading, spacing: 12) {
                KanbanIDGroup(title: "Parents", ids: detail.parentIDs)
                KanbanIDGroup(title: "Children", ids: detail.childIDs)
            }
        }
    }

    private func commentsPanel(_ task: KanbanTask, _ detail: KanbanTaskDetail) -> some View {
        HermesSurfacePanel(
            title: "Comments",
            subtitle: "Human and agent notes attached to this task."
        ) {
            if detail.comments.isEmpty {
                Text(L10n.string("No comments yet."))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(detail.comments) { comment in
                        KanbanCommentRow(comment: comment)
                    }
                }
            }
        }
    }

    private func runsPanel(_ detail: KanbanTaskDetail) -> some View {
        HermesSurfacePanel(
            title: "Runs",
            subtitle: "Attempt history recorded by Hermes."
        ) {
            if detail.runs.isEmpty {
                Text(L10n.string("No runs recorded yet."))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(detail.runs) { run in
                        KanbanRunRow(run: run)
                    }
                }
            }
        }
    }

    private func eventsPanel(_ detail: KanbanTaskDetail) -> some View {
        HermesSurfacePanel(
            title: "Events",
            subtitle: "Chronological board events for this task."
        ) {
            if detail.events.isEmpty {
                Text(L10n.string("No events recorded yet."))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(detail.events.suffix(20)) { event in
                        KanbanEventRow(event: event)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private func logPanel(_ detail: KanbanTaskDetail) -> some View {
        if let log = detail.workerLog?.trimmingCharacters(in: .whitespacesAndNewlines), !log.isEmpty {
            HermesSurfacePanel(
                title: "Worker Log",
                subtitle: "Tail of the remote worker log for this task."
            ) {
                HermesInsetSurface {
                    Text(log)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct KanbanFormField<Content: View>: View {
    let label: String
    let content: Content

    init(label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L10n.string(label))
                .font(.os1SmallCaps)
                .foregroundStyle(.os1OnCoralSecondary)

            content
        }
    }
}

private struct KanbanActionDisclosureRow<Content: View>: View {
    let title: String
    let summary: String
    let systemImage: String
    let isExpanded: Bool
    let isDisabled: Bool
    let onToggle: () -> Void
    let content: Content

    init(
        title: String,
        summary: String,
        systemImage: String,
        isExpanded: Bool,
        isDisabled: Bool,
        onToggle: @escaping () -> Void,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.summary = summary
        self.systemImage = systemImage
        self.isExpanded = isExpanded
        self.isDisabled = isDisabled
        self.onToggle = onToggle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: onToggle) {
                HStack(spacing: 11) {
                    Image(systemName: systemImage)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(.os1OnCoralSecondary)
                        .frame(width: 18)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.string(title))
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.os1OnCoralPrimary)

                        Text(L10n.string(summary))
                            .font(.os1SmallCaps)
                            .foregroundStyle(.os1OnCoralSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.os1OnCoralSecondary)
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isDisabled)

            if isExpanded {
                content
                    .padding(.leading, 29)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.vertical, 8)
    }
}

private struct KanbanActionDivider: View {
    var body: some View {
        Divider()
            .padding(.leading, 29)
            .opacity(0.55)
    }
}

private struct KanbanTextEditor: View {
    @Binding var text: String
    let placeholder: String

    var body: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: $text)
                .scrollContentBackground(.hidden)
                .foregroundStyle(.os1OnCoralPrimary)
                .font(.os1Body)
                .scrollContentBackground(.hidden)
                .frame(minHeight: 68)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)

            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(L10n.string(placeholder))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralMuted)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 14)
                    .allowsHitTesting(false)
            }
        }
        .background(Color.os1OnCoralSecondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.os1OnCoralPrimary.opacity(0.08), lineWidth: 1)
        }
    }
}

private struct ComboBoxTextField: View {
    @Binding var text: String
    let suggestions: [String]
    let placeholder: String

    var body: some View {
        HStack(spacing: 8) {
            TextField(L10n.string(placeholder), text: $text)
                .os1Underlined()
                .layoutPriority(1)

            if !suggestions.isEmpty {
                Menu {
                    Button(L10n.string("Unassigned")) {
                        text = ""
                    }

                    Divider()

                    ForEach(suggestions, id: \.self) { suggestion in
                        Button(suggestion) {
                            text = suggestion
                        }
                    }
                } label: {
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(.os1Secondary)
                .fixedSize()
                .help(L10n.string("Pick a discovered assignee"))
            }
        }
    }
}

private struct KanbanIDGroup: View {
    let title: String
    let ids: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(L10n.string(title))
                .font(.os1SmallCaps)
                .foregroundStyle(.os1OnCoralSecondary)

            if ids.isEmpty {
                Text(L10n.string("None"))
                    .font(.os1Body)
                    .foregroundStyle(.os1OnCoralSecondary)
            } else {
                HermesWrappingFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
                    ForEach(ids, id: \.self) { id in
                        HermesBadge(text: id, tint: .secondary, isMonospaced: true)
                    }
                }
            }
        }
    }
}

private struct KanbanCommentRow: View {
    let comment: KanbanComment

    var body: some View {
        HermesInsetSurface {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(comment.author)
                        .font(.subheadline.weight(.semibold))

                    Text(DateFormatters.relativeFormatter().localizedString(for: comment.createdDate, relativeTo: .now))
                        .font(.os1SmallCaps)
                        .foregroundStyle(.os1OnCoralSecondary)
                }

                Text(comment.body)
                    .font(.os1Body)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct KanbanRunRow: View {
    let run: KanbanRun

    var body: some View {
        HermesInsetSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HermesBadge(text: "#\(run.id)", tint: .secondary, isMonospaced: true)
                    HermesBadge(text: run.resolvedOutcome, tint: run.endedAt == nil ? .orange : .secondary)

                    if let profile = run.profile {
                        HermesBadge(text: "@\(profile)", tint: .accentColor, isMonospaced: true)
                    }
                }

                Text(DateFormatters.shortDateTimeFormatter().string(from: run.startedDate))
                    .font(.os1SmallCaps)
                    .foregroundStyle(.os1OnCoralSecondary)

                if let summary = run.summary {
                    Text(summary)
                        .font(.os1Body)
                        .textSelection(.enabled)
                }

                if let error = run.error {
                    Text(error)
                        .font(.os1Body)
                        .foregroundStyle(.os1OnCoralPrimary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

private struct KanbanEventRow: View {
    let event: KanbanEvent

    var body: some View {
        HermesInsetSurface {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    HermesBadge(text: event.kind, tint: .secondary)

                    if let runID = event.runID {
                        HermesBadge(text: "run \(runID)", tint: .secondary, isMonospaced: true)
                    }

                    Spacer(minLength: 8)

                    Text(DateFormatters.relativeFormatter().localizedString(for: event.createdDate, relativeTo: .now))
                        .font(.os1SmallCaps)
                        .foregroundStyle(.os1OnCoralSecondary)
                }

                if let payload = event.displayPayload {
                    Text(payload)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.os1OnCoralSecondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}
