import SwiftUI

/// Voice-spawnable Codex Tasks. Each task runs through a generated sandbox profile
/// in its own git worktree under ~/.os1/codex-tasks/sessions/<id>.
struct CodexTasksView: View {
    @Environment(\.os1Theme) private var theme
    @StateObject private var manager = CodexSessionManager.shared

    @State private var newTaskText: String = ""
    @State private var newCompanyName: String = ""
    @State private var newCadenceMinutes: Int = 15
    @State private var templateSearchText: String = ""
    @State private var selectedTemplatePlatform: String = "all"
    @State private var selectedTemplateID: String = CompanyTemplateCatalog.all.first?.id ?? ""
    @State private var bulkLaunchLimit: Int = 10
    @State private var bulkLaunchStartPaused: Bool = true
    @State private var bulkCadenceOverride: Int = 0
    @State private var spawnError: String = ""
    @State private var selectedID: String?
    @State private var interveneTexts: [String: String] = [:]
    @State private var approvalChangeTexts: [String: String] = [:]
    @State private var ledgerAmounts: [String: String] = [:]
    @State private var ledgerNotes: [String: String] = [:]
    @State private var nowTick: Date = Date()  // drives countdown labels

    private let columns = [GridItem(.adaptive(minimum: 320), spacing: 12)]

    var body: some View {
        VStack(spacing: 0) {
            header
            spawnBar
            templateBar
            ideaBacklog
            portfolioDashboard
            fleetSection
            reputationConsole
            approvalConsole
            eventConsole
            metricsStrip
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
        let status = manager.fleetStatus()
        let budget = manager.fleetBudgetReport()
        return HStack(spacing: 10) {
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
            Button(L10n.string("Backup state")) {
                createBackup()
            }
            .buttonStyle(.os1Secondary)
            .disabled(manager.sessions.isEmpty)

            Button(L10n.string("Pause fleet")) {
                manager.pauseAll()
            }
            .buttonStyle(.os1Secondary)
            .disabled(manager.sessions.isEmpty)

            Button(L10n.string("Resume fleet")) {
                manager.resumeAllPaused()
            }
            .buttonStyle(.os1Secondary)
            .disabled(!manager.sessions.contains(where: { $0.status == .paused }))

            Text(L10n.string("running %lld", status.active))
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralMuted)
            if status.queued > 0 {
                Text(L10n.string("queued %lld", status.queued))
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.onCoralMuted)
            }
            if status.blocked > 0 {
                Text("blocked \(status.blocked)")
                    .os1Style(theme.typography.label)
                    .foregroundStyle(.orange)
            }
            if status.failed > 0 {
                Text("failed \(status.failed)")
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.danger)
            }
            Text("budget \(moneyLabel(budget.globalSpendUSD))/\(moneyLabel(budget.globalHardLimitUSD))")
                .os1Style(theme.typography.label)
                .foregroundStyle(budget.status == .healthy ? theme.palette.onCoralMuted : theme.palette.danger)
            if status.profitable > 0 {
                Text("profitable \(status.profitable)")
                    .os1Style(theme.typography.label)
                    .foregroundStyle(.green)
            }
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

    private var templateBar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Label(L10n.string("Company templates"), systemImage: "building.2")
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.onCoralPrimary)

                TextField(L10n.string("Search 100 templates"), text: $templateSearchText)
                    .textFieldStyle(.plain)
                    .frame(width: 180)
                    .padding(.vertical, 8)
                    .padding(.horizontal, 10)
                    .background(theme.palette.glassFill)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))

                Picker("Platform", selection: $selectedTemplatePlatform) {
                    Text("All").tag("all")
                    ForEach(CompanyTemplate.Platform.allCases, id: \.self) { platform in
                        Text(platform.rawValue).tag(platform.rawValue)
                    }
                }
                .frame(width: 130)

                Picker(L10n.string("Template"), selection: $selectedTemplateID) {
                    ForEach(filteredTemplates) { template in
                        Text(template.title).tag(template.id)
                    }
                }
                .frame(maxWidth: 420)

                Button(L10n.string("Use template")) { applySelectedTemplate() }
                    .buttonStyle(.os1Secondary)
                    .disabled(selectedTemplate == nil)

                Button(L10n.string("Hire from template")) { spawnSelectedTemplate() }
                    .buttonStyle(.os1Primary)
                    .disabled(selectedTemplate == nil)

                Spacer()

                Text(L10n.string("%lld templates", CompanyTemplateCatalog.all.count))
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.onCoralMuted)
            }

            if let template = selectedTemplate {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 8) {
                        Text(template.category.rawValue)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(theme.palette.onCoralMuted)
                        Text(template.channel)
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(theme.palette.onCoralMuted)
                        Text("every \(template.suggestedCadenceMinutes)m")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                    Text(template.mission)
                        .os1Style(theme.typography.label)
                        .foregroundStyle(theme.palette.onCoralSecondary)
                        .lineLimit(2)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.palette.glassFill.opacity(0.72))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            HStack(spacing: 10) {
                Picker(L10n.string("Batch"), selection: $bulkLaunchLimit) {
                    Text("5").tag(5)
                    Text("10").tag(10)
                    Text("25").tag(25)
                    Text("50").tag(50)
                    Text("100").tag(100)
                }
                .frame(width: 92)

                Picker(L10n.string("Cadence"), selection: $bulkCadenceOverride) {
                    Text(L10n.string("template")).tag(0)
                    Text("30m").tag(30)
                    Text("1h").tag(60)
                    Text("4h").tag(240)
                    Text("12h").tag(720)
                }
                .frame(width: 124)

                Toggle(L10n.string("Start paused"), isOn: $bulkLaunchStartPaused)
                    .toggleStyle(.checkbox)
                    .foregroundStyle(theme.palette.onCoralSecondary)

                Button(L10n.string("Launch batch")) { launchTemplateBatch() }
                    .buttonStyle(.os1Secondary)
                    .disabled(batchTemplates.isEmpty)

                Text(L10n.string("will create %lld", batchTemplates.count))
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.onCoralMuted)

                Spacer()
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private var filteredTemplates: [CompanyTemplate] {
        let query = templateSearchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return CompanyTemplateCatalog.all.filter { template in
            let platformMatches = selectedTemplatePlatform == "all" || template.platform?.rawValue == selectedTemplatePlatform
            let queryMatches = query.isEmpty || template.searchText.contains(query)
            return platformMatches && queryMatches
        }
    }

    private var selectedTemplate: CompanyTemplate? {
        CompanyTemplateCatalog.template(id: selectedTemplateID) ?? filteredTemplates.first
    }

    private var batchTemplates: [CompanyTemplate] {
        Array(filteredTemplates.prefix(bulkLaunchLimit))
    }

    private var rankedIdeas: [CompanyIdea] {
        CompanyIdeaEngine.topIdeas(
            count: 10,
            from: CompanyIdeaEngine.candidates(limit: 50),
            preservedLearnings: manager.portfolioDashboard().preservedLearnings
        )
    }

    private var rankedIdeaPlans: [(idea: CompanyIdea, plan: CompanyValidationPlan)] {
        rankedIdeas.map { ($0, CompanyValidationEngine.plan(for: $0)) }
    }

    private var fleetSnapshot: CompanyFleetHealthSnapshot {
        CompanyFleetHealthSnapshot.make(
            sessions: manager.sessions,
            driftFlaggedCompanyIDs: CompanyFleetHealthSnapshot.driftFlaggedCompanyIDs(
                from: manager.recentEvents(limit: 10_000)
            ),
            now: nowTick
        )
    }

    private var ideaBacklog: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label("Idea backlog", systemImage: "lightbulb")
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text("50 candidates · top 10 ranked")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(rankedIdeaPlans, id: \.idea.id) { item in
                        ideaCard(item.idea, validationPlan: item.plan)
                    }
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.bottom, 10)
    }

    private func ideaCard(_ idea: CompanyIdea, validationPlan: CompanyValidationPlan) -> some View {
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("#\(idea.score)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
                Spacer()
                Text(idea.status.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
            }
            Text(idea.title)
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralPrimary)
                .lineLimit(2)
            Text(idea.icp)
                .font(.caption2)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .lineLimit(2)
            HStack(spacing: 6) {
                Label(idea.riskTier.rawValue, systemImage: "shield.lefthalf.filled")
                Label("\(idea.evidenceLinks.count) evidence", systemImage: "link")
            }
            .font(.caption2)
            .foregroundStyle(theme.palette.onCoralMuted)
            HStack(spacing: 6) {
                Label("\(validationPlan.experiments.count) tests", systemImage: "checklist")
                if validationPlan.experiments.contains(where: \.draftOnly) {
                    Label("draft-only outreach", systemImage: "hand.raised")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption2)
            .foregroundStyle(theme.palette.onCoralMuted)
            Text(idea.nextAction)
                .font(.caption2)
                .foregroundStyle(theme.palette.onCoralMuted)
                .lineLimit(2)
            Button("Validate") {
                validateIdea(idea)
            }
            .buttonStyle(.os1Secondary)
            .disabled(!idea.canAdvanceToValidation)
        }
        .frame(width: 260, alignment: .leading)
        .padding(10)
        .background(theme.palette.glassFill.opacity(0.72))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Portfolio dashboard

    @ViewBuilder
    private var portfolioDashboard: some View {
        let dashboard = manager.portfolioDashboard()
        if dashboard.totalCompanies > 0 {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Portfolio", systemImage: "chart.pie")
                        .os1Style(theme.typography.label)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                    Text("EV \(moneyLabel(dashboard.expectedValueUSD))")
                    Text("channels \(dashboard.channelCount)")
                    Text("risks \(dashboard.concentrationRisks.count)")
                    Text("learnings \(dashboard.preservedLearnings.count)")
                    Spacer()
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.palette.onCoralMuted)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(dashboard.allocations.prefix(8)) { allocation in
                            portfolioAllocationCard(allocation)
                        }
                        ForEach(dashboard.concentrationRisks.prefix(6)) { risk in
                            portfolioRiskCard(risk)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    private func portfolioAllocationCard(_ allocation: CompanyPortfolioAllocation) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("#\(allocation.rank)")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.green)
                Text(allocation.companyID.prefix(8))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
                Spacer()
                Image(systemName: allocation.canStartHeartbeat ? "play.circle.fill" : "pause.circle.fill")
                    .foregroundStyle(allocation.canStartHeartbeat ? .green : .orange)
            }
            Text("score \(allocation.priorityScore, specifier: "%.1f")")
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralPrimary)
            HStack(spacing: 6) {
                Label(moneyLabel(allocation.recommendedBudgetUSD), systemImage: "banknote")
                Label("\(allocation.computeSlots)x", systemImage: "cpu")
            }
            .font(.caption2)
            .foregroundStyle(theme.palette.onCoralMuted)
            Text(allocation.reasons.joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(width: 210, alignment: .leading)
        .background(theme.palette.glassFill.opacity(0.78))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func portfolioRiskCard(_ risk: CompanyPortfolioConcentrationRisk) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(risk.dimension.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.orange)
                Spacer()
            }
            Text(risk.value)
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralPrimary)
                .lineLimit(1)
            Text("\(risk.count)/\(risk.limit) companies")
                .font(.caption2)
                .foregroundStyle(theme.palette.onCoralMuted)
            Text(risk.companyIDs.prefix(4).joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .lineLimit(2)
        }
        .padding(10)
        .frame(width: 210, alignment: .leading)
        .background(Color.orange.opacity(0.16))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Fleet scheduler

    @ViewBuilder
    private var fleetSection: some View {
        if !manager.sessions.isEmpty {
            FleetSection(snapshot: fleetSnapshot)
                .padding(.horizontal, 18)
                .padding(.bottom, 10)
        }
    }

    // MARK: - Reputation console

    @ViewBuilder
    private var reputationConsole: some View {
        let dashboard = manager.reputationDashboard()
        let risky = dashboard.allHealth.filter { $0.risk == .high || $0.risk == .critical }
        if !dashboard.allHealth.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label("Reputation", systemImage: "person.badge.shield.checkmark")
                        .os1Style(theme.typography.label)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                    Text("\(dashboard.allHealth.count) assets")
                    Text("\(dashboard.sharedAssetHealth.count) shared")
                    Text("\(risky.count) risky")
                    Text("\(dashboard.escalationTasks.count) escalations")
                    Spacer()
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.palette.onCoralMuted)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 8) {
                        ForEach(dashboard.allHealth.prefix(10)) { health in
                            reputationCard(health)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    private func reputationCard(_ health: CompanyReputationHealth) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: reputationIcon(health))
                    .foregroundStyle(reputationColor(health))
                Text(health.kind.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(reputationColor(health))
                Spacer()
                Text(health.status.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
            }
            Text(health.label)
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralPrimary)
                .lineLimit(1)
            HStack(spacing: 6) {
                Text("bounce \(percentLabel(health.bounceRate))")
                Text("complaint \(percentLabel(health.complaintRate))")
            }
            .font(.caption2)
            .foregroundStyle(theme.palette.onCoralMuted)
            if let review = health.reviewAverage {
                Text("reviews \(review, specifier: "%.1f")")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.onCoralMuted)
            }
            Text(health.warnings.prefix(2).joined(separator: ", "))
                .font(.caption2)
                .foregroundStyle(health.warnings.isEmpty ? theme.palette.onCoralMuted : .orange)
                .lineLimit(2)
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
        .background(theme.palette.glassFill.opacity(0.78))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(reputationColor(health).opacity(0.55), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    // MARK: - Approval console

    @ViewBuilder
    private var approvalConsole: some View {
        let requests = manager.approvalRequests(status: .pending)
        let plan = manager.approvalQueuePlan()
        if !requests.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(L10n.string("Approvals"), systemImage: "checkmark.shield")
                        .os1Style(theme.typography.label)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                    Text(L10n.string("%lld pending", requests.count))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.palette.onCoralMuted)
                    Spacer()
                }

                if !plan.batches.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(plan.batches.keys.sorted(), id: \.self) { key in
                                if let ids = plan.batches[key], !ids.isEmpty {
                                    Button {
                                        _ = manager.approveBatch(batchKey: key, hours: 4)
                                    } label: {
                                        Label(
                                            L10n.string("Approve %lld %@", ids.count, approvalBatchTitle(key)),
                                            systemImage: "checkmark.circle"
                                        )
                                    }
                                    .buttonStyle(.os1Secondary)
                                }
                            }
                        }
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(requests) { request in
                            approvalCard(request)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    private func approvalCard(_ request: CompanyApprovalRequest) -> some View {
        let compliance = manager.complianceDecision(for: request)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.shield")
                    .foregroundStyle(approvalColor(request.riskTier))
                Text(request.riskTier.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(approvalColor(request.riskTier))
                Spacer()
                Text(relativeAge(request.requestedAt))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
            }

            Text(request.proposedAction)
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralPrimary)
                .lineLimit(2)

            Text(request.expectedEffect)
                .font(.caption2)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .lineLimit(2)

            HStack(spacing: 8) {
                Text(request.companyID)
                if let cost = request.estimatedCostUSD {
                    Text(moneyLabel(cost))
                }
                if let destination = request.destinationAccount {
                    Text(destination)
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(theme.palette.onCoralMuted)
            .lineLimit(1)

            if compliance.status != .approved {
                VStack(alignment: .leading, spacing: 4) {
                    Label(compliance.status.rawValue, systemImage: "shield.lefthalf.filled.badge.checkmark")
                        .foregroundStyle(compliance.status == .blocked ? theme.palette.danger : .orange)
                    ForEach(compliance.findings.prefix(2)) { finding in
                        Text(finding.fix)
                            .font(.caption2)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                            .lineLimit(2)
                    }
                }
            }

            HStack(spacing: 6) {
                Button(L10n.string("Once")) {
                    manager.approveOnce(request: request)
                }
                .buttonStyle(.os1Secondary)

                Button(L10n.string("4h")) {
                    manager.approve(request: request, hours: 4)
                }
                .buttonStyle(.os1Primary)
                .disabled(compliance.status == .blocked)

                Button(L10n.string("Budget")) {
                    manager.approveWithinBudget(request: request, hours: 4)
                }
                .buttonStyle(.os1Secondary)
                .disabled(request.estimatedCostUSD == nil)
            }

            HStack(spacing: 6) {
                Button(L10n.string("Deny")) {
                    manager.deny(request: request)
                }
                .buttonStyle(.os1Secondary)

                Button(L10n.string("Always ask")) {
                    manager.alwaysRequireApproval(request: request)
                }
                .buttonStyle(.os1Secondary)
            }

            HStack(spacing: 6) {
                TextField(
                    L10n.string("Request changes"),
                    text: Binding(
                        get: { approvalChangeTexts[request.id] ?? "" },
                        set: { approvalChangeTexts[request.id] = $0 }
                    )
                )
                .textFieldStyle(.plain)
                .padding(.vertical, 6)
                .padding(.horizontal, 8)
                .background(theme.palette.glassFill)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .onSubmit { requestApprovalChanges(request) }

                Button {
                    requestApprovalChanges(request)
                } label: {
                    Image(systemName: "arrow.uturn.left.circle.fill")
                        .font(.system(size: 16))
                }
                .buttonStyle(.os1Icon)
            }
        }
        .padding(10)
        .frame(width: 330, alignment: .leading)
        .background(theme.palette.glassFill.opacity(0.86))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(approvalColor(request.riskTier).opacity(0.6), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func approvalBatchTitle(_ key: String) -> String {
        key.replacingOccurrences(of: "|", with: " ")
            .replacingOccurrences(of: "_", with: " ")
    }

    // MARK: - Event console

    @ViewBuilder
    private var eventConsole: some View {
        let events = manager.recentEvents(limit: 8)
        if !events.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Label(L10n.string("Event log"), systemImage: "list.bullet.rectangle")
                        .os1Style(theme.typography.label)
                        .foregroundStyle(theme.palette.onCoralPrimary)
                    Text(L10n.string("last %lld", events.count))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.palette.onCoralMuted)
                    Spacer()
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(events) { event in
                            eventPill(event)
                        }
                    }
                }
            }
            .padding(.horizontal, 18)
            .padding(.bottom, 10)
        }
    }

    private func eventPill(_ event: CompanyEvent) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: eventIcon(event.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(eventColor(event.kind))
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.summary)
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Text(event.kind.rawValue)
                    if let companyID = event.companyID {
                        Text(companyID)
                    }
                    Text(relativeAge(event.occurredAt))
                }
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.palette.onCoralMuted)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .frame(width: 280, alignment: .leading)
        .background(theme.palette.glassFill.opacity(0.82))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var metricsStrip: some View {
        let metrics = manager.metricsSnapshot()
        let plan = manager.schedulerPlan()
        let topPortfolio = manager.portfolioRanks().first
        return HStack(spacing: 10) {
            Label("observability", systemImage: "chart.xyaxis.line")
            Text("events \(metrics.eventCount)")
            Text("success \(percentLabel(metrics.successRate))")
            Text("errors \(percentLabel(metrics.errorRate))")
            Text("avg \(latencyLabel(metrics.averageLatencyMS))")
            Text("manual \(metrics.manualInterventionCount)")
            Text("profit \(moneyLabel(metrics.profitUSD))")
            Text("scheduler start \(plan.startNowIDs.count)")
            Text("queue \(plan.queuedIDs.count)")
            if let topPortfolio {
                Text("top \(topPortfolio.companyID.prefix(6)) score \(topPortfolio.evidenceScore)")
            }
            if !plan.backpressureReasons.isEmpty {
                Text("backpressure \(plan.backpressureReasons.joined(separator: ","))")
                    .foregroundStyle(.orange)
            }
            Spacer()
        }
        .font(.system(.caption2, design: .monospaced))
        .foregroundStyle(theme.palette.onCoralMuted)
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
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
                Text(session.lifecycleStage.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
            }

            Text(session.task)
                .os1Style(theme.typography.label)
                .foregroundStyle(theme.palette.onCoralSecondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                let budgetReport = manager.budgetReport(id: session.id)
                Label("hb #\(session.heartbeatCount)", systemImage: "waveform.path.ecg")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.onCoralMuted)
                Label("every \(session.cadenceMinutes)m", systemImage: "clock")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.onCoralMuted)
                Label(session.sandboxMode.rawValue, systemImage: "lock.shield")
                    .font(.caption2)
                    .foregroundStyle(theme.palette.onCoralMuted)
                if let budget = session.budget {
                    Label("\(budget.dailyHeartbeatCount)/\(budget.maxDailyHeartbeats) today", systemImage: "gauge.with.dots.needle.33percent")
                        .font(.caption2)
                        .foregroundStyle(theme.palette.onCoralMuted)
                }
                Label("\(moneyLabel(budgetReport.companySpendUSD))/\(moneyLabel(budgetReport.companyHardLimitUSD))", systemImage: "creditcard.trianglebadge.exclamationmark")
                    .font(.caption2)
                    .foregroundStyle(budgetReport.status == .healthy ? theme.palette.onCoralMuted : theme.palette.danger)
                let ledger = manager.ledgerSummary(id: session.id)
                Label(moneyLabel(ledger.netUSD), systemImage: "dollarsign.circle")
                    .font(.caption2)
                    .foregroundStyle(ledger.netUSD >= 0 ? theme.palette.onCoralMuted : theme.palette.danger)
                Spacer()
                if session.status == .idle, let next = session.nextHeartbeatAt {
                    Label("next \(countdown(to: next))", systemImage: "arrow.right.circle")
                        .font(.caption2)
                        .foregroundStyle(theme.palette.onCoralMuted)
                } else if session.status == .running {
                    Label("running", systemImage: "circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                } else if session.status == .queued {
                    Label("queued", systemImage: "line.3.horizontal.decrease.circle")
                        .font(.caption2)
                        .foregroundStyle(.purple)
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
                    if session.status == .running {
                        Button(L10n.string("Kill heartbeat"), role: .destructive) {
                            manager.kill(id: session.id)
                        }
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
                Label(session.lifecycleStage.rawValue, systemImage: "flag.checkered")
                    .font(.caption)
                Label(session.sandboxMode.rawValue, systemImage: "lock.shield")
                    .font(.caption)
                Label(session.assignedRunnerID, systemImage: "cpu")
                    .font(.caption)
            }
            .foregroundStyle(theme.palette.onCoralMuted)

            if session.sandboxMode != .sandbox {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .foregroundStyle(theme.palette.danger)
                    Text(
                        "Codex heartbeat sandbox: OFF. This local-development company is not wrapped by macOS "
                            + "sandbox-exec, so Codex can read or write outside its company worktree. Do not use "
                            + "this mode for revenue companies."
                    )
                        .os1Style(theme.typography.label)
                        .foregroundStyle(theme.palette.danger)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.palette.danger.opacity(0.16))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(theme.palette.danger.opacity(0.65), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
            }

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

            let events = manager.eventTimeline(companyID: session.id, limit: 12)
            HStack {
                Text("Run timeline")
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.onCoralMuted)
                Spacer()
                let metrics = manager.metricsSnapshot(companyID: session.id)
                Text("success \(percentLabel(metrics.successRate)) · errors \(percentLabel(metrics.errorRate)) · avg \(latencyLabel(metrics.averageLatencyMS))")
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if events.isEmpty {
                        Text("No events yet")
                            .font(.caption)
                            .foregroundStyle(theme.palette.onCoralMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        ForEach(events) { event in
                            eventTimelineRow(event)
                        }
                    }
                }
                .padding(8)
            }
            .frame(maxHeight: 150)
            .background(theme.palette.glassFill)
            .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            Text(session.worktreePath)
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(theme.palette.onCoralMuted)

            let ledger = manager.ledgerSummary(id: session.id)
            let budget = manager.budgetReport(id: session.id)
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Budget")
                        .os1Style(theme.typography.label)
                        .foregroundStyle(theme.palette.onCoralMuted)
                    Spacer()
                    Label(budget.status.rawValue, systemImage: budget.status == .healthy ? "checkmark.seal" : "exclamationmark.triangle")
                        .foregroundStyle(budget.status == .healthy ? .green : .orange)
                }
                HStack(spacing: 12) {
                    Label("spend \(moneyLabel(budget.companySpendUSD))", systemImage: "creditcard")
                    Label("actual \(moneyLabel(budget.companyActualSpendUSD))", systemImage: "checkmark.circle")
                    Label("estimated \(moneyLabel(budget.companyEstimatedSpendUSD))", systemImage: "questionmark.circle")
                    Label("hard \(moneyLabel(budget.companyHardLimitUSD))", systemImage: "gauge.with.dots.needle.67percent")
                    Label("global \(moneyLabel(budget.globalSpendUSD))/\(moneyLabel(budget.globalHardLimitUSD))", systemImage: "globe")
                }
                HStack(spacing: 12) {
                    ForEach(budget.channelUsage.filter { $0.totalUSD > 0 }.prefix(5), id: \.category) { channel in
                        Label("\(channel.category.rawValue) \(moneyLabel(channel.totalUSD))", systemImage: "chart.bar")
                    }
                    if budget.channelUsage.filter({ $0.totalUSD > 0 }).isEmpty {
                        Label("no tracked spend", systemImage: "checkmark.circle")
                    }
                }
                if !budget.reasons.isEmpty {
                    Text(budget.reasons.joined(separator: ", "))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.palette.danger)
                }
            }
            .font(.caption)
            .foregroundStyle(theme.palette.onCoralMuted)

            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("P&L")
                        .os1Style(theme.typography.label)
                        .foregroundStyle(theme.palette.onCoralMuted)
                    Spacer()
                    if ledger.canMarkProfitable {
                        Label("profit qualified", systemImage: "checkmark.seal")
                            .foregroundStyle(.green)
                    } else if ledger.netUSD > 0 {
                        Label("unverified profit", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 12) {
                    Label("gross \(moneyLabel(ledger.revenueUSD))", systemImage: "arrow.down.circle")
                    Label("refunds \(moneyLabel(ledger.refundUSD))", systemImage: "arrow.uturn.left.circle")
                    Label("net rev \(moneyLabel(ledger.netRevenueUSD))", systemImage: "sum")
                    Label("cost \(moneyLabel(ledger.costUSD))", systemImage: "arrow.up.circle")
                    Label("profit \(moneyLabel(ledger.netUSD))", systemImage: "dollarsign.circle")
                }
                HStack(spacing: 12) {
                    Label("margin \(optionalPercentLabel(ledger.contributionMargin))", systemImage: "chart.line.uptrend.xyaxis")
                    Label("ROI \(optionalPercentLabel(ledger.roi))", systemImage: "percent")
                    Label("payback \(optionalDaysLabel(ledger.paybackPeriodDays))", systemImage: "calendar.badge.clock")
                    Label("runway \(optionalDaysLabel(ledger.runwayDays))", systemImage: "fuelpump")
                }
                HStack(spacing: 12) {
                    Label("verified \(ledger.verifiedEntryCount)", systemImage: "checkmark.seal")
                    Label("estimated \(ledger.estimatedEntryCount)", systemImage: "questionmark.circle")
                    Label("traced \(ledger.tracedEntryCount)/\(ledger.entries.count)", systemImage: "point.topleft.down.curvedto.point.bottomright.up")
                    if !ledger.untracedEntries.isEmpty {
                        Label("untraced \(ledger.untracedEntries.count)", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.orange)
                    }
                }
                HStack(spacing: 8) {
                    TextField("Amount", text: Binding(
                        get: { ledgerAmounts[session.id] ?? "" },
                        set: { ledgerAmounts[session.id] = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .frame(width: 82)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(theme.palette.glassFill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    TextField("Ledger note", text: Binding(
                        get: { ledgerNotes[session.id] ?? "" },
                        set: { ledgerNotes[session.id] = $0 }
                    ))
                    .textFieldStyle(.plain)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 8)
                    .background(theme.palette.glassFill)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                    Button("Revenue") { recordLedger(session.id, kind: .revenue) }
                        .buttonStyle(.os1Secondary)
                    Button("Cost") { recordLedger(session.id, kind: .cost) }
                        .buttonStyle(.os1Secondary)
                    Button("Refund") { recordLedger(session.id, kind: .refund) }
                        .buttonStyle(.os1Secondary)
                }
            }
            .font(.caption)
            .foregroundStyle(theme.palette.onCoralMuted)

            if let manifest = manager.factoryManifest(id: session.id) {
                let campaigns = CompanyDistributionEngine.proposedCampaigns(companyID: session.id, manifest: manifest)
                let distribution = CompanyDistributionEngine.summarize(campaigns: campaigns, results: [])
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Factory assets")
                            .os1Style(theme.typography.label)
                            .foregroundStyle(theme.palette.onCoralMuted)
                        Spacer()
                        Label(manifest.canLaunch ? "launch gates passed" : "launch gated", systemImage: manifest.canLaunch ? "checkmark.seal" : "lock.shield")
                            .foregroundStyle(manifest.canLaunch ? .green : .orange)
                    }
                    ForEach(manifest.assets.prefix(6)) { asset in
                        HStack {
                            Label(asset.title, systemImage: asset.sandboxTestable ? "testtube.2" : "doc")
                            Spacer()
                            Text(URL(fileURLWithPath: asset.path).lastPathComponent)
                                .font(.system(.caption2, design: .monospaced))
                        }
                    }
                    HStack(spacing: 8) {
                        ForEach(manifest.gates) { gate in
                            Label(gate.kind.rawValue, systemImage: gate.passed ? "checkmark.circle" : "xmark.circle")
                                .foregroundStyle(gate.passed ? .green : .orange)
                        }
                    }
                }
                .font(.caption)
                .foregroundStyle(theme.palette.onCoralMuted)

                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Distribution")
                            .os1Style(theme.typography.label)
                            .foregroundStyle(theme.palette.onCoralMuted)
                        Spacer()
                        Text("active \(distribution.active.count) · blocked \(distribution.blocked.count)")
                            .font(.system(.caption2, design: .monospaced))
                            .foregroundStyle(theme.palette.onCoralMuted)
                    }
                    ForEach(campaigns.prefix(4)) { campaign in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Label(campaign.channel.rawValue, systemImage: campaign.canExecute ? "paperplane.circle" : "lock.circle")
                                Spacer()
                                Text(campaign.complianceDecision.status.rawValue)
                                    .font(.system(.caption2, design: .monospaced))
                                    .foregroundStyle(campaign.canExecute ? .green : .orange)
                            }
                            if let fix = campaign.complianceDecision.fixes.first {
                                Text(fix)
                                    .font(.caption2)
                                    .foregroundStyle(theme.palette.onCoralSecondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    Text(distribution.nextRecommendedAction)
                        .font(.caption2)
                        .foregroundStyle(theme.palette.onCoralMuted)
                }
                .font(.caption)
                .foregroundStyle(theme.palette.onCoralMuted)
            }

            let credentialNames = CodexSessionManager.loadCredentialNames()
            if !credentialNames.isEmpty {
                Text("Credential grants")
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.onCoralMuted)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(credentialNames, id: \.self) { name in
                            let granted = session.credentialAllowlist.contains(name)
                            Button {
                                if granted {
                                    manager.revokeCredential(id: session.id, name: name)
                                } else {
                                    manager.grantCredential(id: session.id, name: name)
                                }
                            } label: {
                                Label(name, systemImage: granted ? "checkmark.circle.fill" : "circle")
                                    .font(.caption2)
                            }
                            .buttonStyle(.os1Secondary)
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 760, height: 640)
    }

    private func eventTimelineRow(_ event: CompanyEvent) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: eventIcon(event.kind))
                    .foregroundStyle(eventColor(event.kind))
                    .frame(width: 16)
                Text(event.kind.rawValue)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
                Text(relativeAge(event.occurredAt))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
                if let tool = event.tool {
                    Text(tool)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.palette.onCoralMuted)
                }
                Spacer()
                if let latency = event.latencyMS {
                    Text(latencyLabel(latency))
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(theme.palette.onCoralMuted)
                }
            }
            Text(event.summary)
                .font(.caption)
                .foregroundStyle(theme.palette.onCoralPrimary)
                .lineLimit(2)
            if let command = event.metadata["command"] {
                Text(command)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .lineLimit(2)
            } else if let output = event.outputSummary, !output.isEmpty {
                Text(output)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .lineLimit(2)
            }
            HStack(spacing: 8) {
                if let inputHash = event.inputHash {
                    Text("input \(String(inputHash.prefix(10)))")
                }
                if let approvalState = event.approvalState {
                    Text("approval \(approvalState)")
                }
                if let logFile = event.metadata["logFile"], !logFile.isEmpty {
                    Text(URL(fileURLWithPath: logFile).lastPathComponent)
                }
            }
            .font(.system(.caption2, design: .monospaced))
            .foregroundStyle(theme.palette.onCoralMuted)
        }
        .padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
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

    private func applySelectedTemplate() {
        guard let template = selectedTemplate else { return }
        selectedTemplateID = template.id
        newCompanyName = template.companyName
        newTaskText = template.missionPrompt
        newCadenceMinutes = template.suggestedCadenceMinutes
        spawnError = ""
    }

    private func spawnSelectedTemplate() {
        applySelectedTemplate()
        guard let template = selectedTemplate else { return }
        do {
            _ = try manager.createCompany(
                name: template.companyName,
                mission: template.missionPrompt,
                cadenceMinutes: template.suggestedCadenceMinutes,
                templateID: template.id
            )
            newTaskText = ""
            newCompanyName = ""
            spawnError = ""
        } catch {
            spawnError = (error as NSError).localizedDescription
        }
    }

    private func launchTemplateBatch() {
        let templates = batchTemplates
        guard !templates.isEmpty else { return }
        do {
            _ = try manager.createCompanies(
                from: templates,
                cadenceMinutes: bulkCadenceOverride == 0 ? nil : bulkCadenceOverride,
                startPaused: bulkLaunchStartPaused,
                firstHeartbeatSpacingSeconds: 90
            )
            spawnError = ""
        } catch {
            spawnError = (error as NSError).localizedDescription
        }
    }

    private func validateIdea(_ idea: CompanyIdea) {
        guard let advanced = CompanyIdeaEngine.advanceToValidation(idea),
              let templateID = advanced.sourceTemplateID,
              let template = CompanyTemplateCatalog.template(id: templateID)
        else { return }
        let validationPlan = CompanyValidationEngine.plan(for: advanced)
        selectedTemplateID = template.id
        newCompanyName = template.companyName
        newTaskText = """
        \(template.missionPrompt)

        IDEA SCORE: \(advanced.score)/70
        ICP: \(advanced.icp)
        OFFER: \(advanced.offer)
        CHANNEL: \(advanced.channel)
        RISK TIER: \(advanced.riskTier.rawValue)
        FIRST EXPERIMENT: \(advanced.expectedFirstExperiment)
        EVIDENCE:
        \(advanced.evidenceLinks.map { "- \($0)" }.joined(separator: "\n"))

        VALIDATION PLAN:
        \(validationPlan.experiments.map { "- \($0.kind.rawValue): \($0.action) Threshold: \($0.measurableThreshold)\($0.draftOnly ? " Draft only until approved." : "")" }.joined(separator: "\n"))

        Start in validation mode. Do not build until the first experiment has real evidence.
        """
        newCadenceMinutes = template.suggestedCadenceMinutes
        spawnError = ""
    }

    private func createBackup() {
        do {
            _ = try manager.createStateBackup()
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

    private func requestApprovalChanges(_ request: CompanyApprovalRequest) {
        let note = (approvalChangeTexts[request.id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !note.isEmpty else { return }
        manager.requestChanges(request: request, note: note)
        approvalChangeTexts[request.id] = ""
    }

    private func recordLedger(_ id: String, kind: CompanyLedgerEntry.Kind) {
        let rawAmount = (ledgerAmounts[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let note = (ledgerNotes[id] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let amount = Double(rawAmount.replacingOccurrences(of: "$", with: "")),
              amount > 0,
              !note.isEmpty
        else { return }
        try? manager.recordManualLedgerEntry(
            id: id,
            kind: kind,
            amountUSD: amount,
            note: note,
            confidence: .manual,
            category: kind == .revenue ? .sales : kind == .refund ? .refund : .other
        )
        ledgerAmounts[id] = ""
        ledgerNotes[id] = ""
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
        case .queued:    return .purple
        case .blocked:   return .orange
        case .paused:    return .gray
        case .completed: return .green
        case .failed:    return .red
        case .killed:    return .gray
        }
    }

    private func reputationIcon(_ health: CompanyReputationHealth) -> String {
        if health.status == .retired { return "archivebox" }
        if health.status == .quarantined || health.status == .banned { return "exclamationmark.octagon" }
        switch health.kind {
        case .senderDomain, .emailAccount: return "envelope.badge.shield.half.filled"
        case .socialAccount: return "person.2"
        case .marketplaceAccount: return "storefront"
        case .brandProfile: return "person.text.rectangle"
        }
    }

    private func reputationColor(_ health: CompanyReputationHealth) -> Color {
        switch health.risk {
        case .low: return .green
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return theme.palette.danger
        }
    }

    private func moneyLabel(_ amount: Double) -> String {
        let sign = amount < 0 ? "-" : ""
        return "\(sign)$\(String(format: "%.2f", abs(amount)))"
    }

    private func percentLabel(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }

    private func optionalPercentLabel(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return percentLabel(value)
    }

    private func optionalDaysLabel(_ value: Double?) -> String {
        guard let value else { return "n/a" }
        return "\(Int(value.rounded()))d"
    }

    private func latencyLabel(_ value: Int?) -> String {
        guard let value else { return "n/a" }
        if value < 1000 { return "\(value)ms" }
        return String(format: "%.1fs", Double(value) / 1000.0)
    }

    private func latencyLabel(_ value: Int) -> String {
        latencyLabel(Optional(value))
    }

    private func eventIcon(_ kind: CompanyEvent.Kind) -> String {
        switch kind {
        case .companyCreated: return "building.2"
        case .externalSideEffect: return "arrow.up.right.square"
        case .heartbeatStarted: return "play.circle"
        case .heartbeatFinished: return "checkmark.circle"
        case .heartbeatQueued: return "line.3.horizontal.decrease.circle"
        case .budgetBlocked: return "gauge.with.dots.needle.67percent"
        case .lifecycleChanged: return "flag.checkered"
        case .userInstruction: return "person.crop.circle.badge.checkmark"
        case .companyPaused, .fleetPaused: return "pause.circle"
        case .companyResumed, .fleetResumed: return "arrow.clockwise.circle"
        case .companyKilled: return "xmark.octagon"
        case .secretAccessed: return "key"
        case .complianceChecked: return "shield.checkered"
        case .complianceBlocked: return "shield.slash"
        case .approvalRequested: return "checkmark.shield"
        case .approvalApproved: return "checkmark.seal"
        case .approvalDenied: return "xmark.shield"
        case .approvalChangesRequested: return "arrow.uturn.left.circle"
        case .permissionChanged: return "person.crop.circle.badge.gearshape"
        case .permissionDenied: return "lock.shield"
        case .permissionEscalated: return "exclamationmark.shield"
        case .governanceDecisionRecorded: return "doc.badge.clock"
        case .stateBackupCreated: return "externaldrive.badge.checkmark"
        case .ledgerEntryRecorded: return "dollarsign.circle"
        case .untrustedContentInfluencedDecision: return "exclamationmark.shield"
        case .driftDetected: return "point.3.connected.trianglepath.dotted"
        case .experimentDecided: return "chart.line.uptrend.xyaxis"
        }
    }

    private func eventColor(_ kind: CompanyEvent.Kind) -> Color {
        switch kind {
        case .budgetBlocked, .companyKilled, .approvalDenied, .complianceBlocked, .permissionDenied:
            return theme.palette.danger
        case .heartbeatQueued, .externalSideEffect, .permissionChanged, .governanceDecisionRecorded:
            return .purple
        case .companyPaused, .fleetPaused, .approvalRequested, .approvalChangesRequested,
             .untrustedContentInfluencedDecision, .permissionEscalated, .driftDetected:
            return .orange
        case .heartbeatStarted:
            return .yellow
        case .heartbeatFinished, .lifecycleChanged, .companyResumed, .fleetResumed, .approvalApproved,
             .stateBackupCreated, .ledgerEntryRecorded, .complianceChecked:
            return .green
        case .experimentDecided:
            return .blue
        case .companyCreated, .userInstruction, .secretAccessed:
            return theme.palette.onCoralMuted
        }
    }

    private func approvalColor(_ riskTier: CompanyApprovalRequest.RiskTier) -> Color {
        switch riskTier {
        case .low: return theme.palette.onCoralMuted
        case .medium: return .yellow
        case .high: return .orange
        case .critical: return theme.palette.danger
        }
    }
}

struct FleetSection: View {
    @Environment(\.os1Theme) private var theme
    let snapshot: CompanyFleetHealthSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Label(L10n.string("Fleet"), systemImage: "cpu")
                    .os1Style(theme.typography.label)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(L10n.string("Queue depth %lld", snapshot.queueDepth))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralMuted)
                Text(L10n.string("Drifting %lld", snapshot.driftingCompanyCount))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(snapshot.driftingCompanyCount > 0 ? .orange : theme.palette.onCoralMuted)
                Spacer()
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(snapshot.workers) { worker in
                        workerCard(worker)
                    }
                }
            }
        }
    }

    static func renderedRows(snapshot: CompanyFleetHealthSnapshot) -> [String] {
        var rows = [
            "queueDepth=\(snapshot.queueDepth)",
            "drifting=\(snapshot.driftingCompanyCount)"
        ]
        rows.append(contentsOf: snapshot.workers.map { worker in
            let active = worker.activeCompanies
                .map { "\($0.companyID):\($0.lastHeartbeatLatencySeconds.map(String.init) ?? "n/a")" }
                .joined(separator: ",")
            return "\(worker.workerID)|\(worker.kind)|\(worker.runningCount)/\(worker.cap)|\(active)"
        })
        return rows
    }

    private func workerCard(_ worker: CompanyFleetHealthSnapshot.Worker) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: worker.kind == "local" ? "desktopcomputer" : "server.rack")
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Text(worker.workerID)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(theme.palette.onCoralPrimary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
            }

            Grid(alignment: .leading, horizontalSpacing: 10, verticalSpacing: 5) {
                GridRow {
                    header("Kind")
                    cell(L10n.string(worker.kind))
                }
                GridRow {
                    header("Running")
                    cell(L10n.string("%lld/%lld", worker.runningCount, worker.cap))
                }
            }

            HStack {
                Text(L10n.string("Active companies"))
                Spacer()
                Text(L10n.string("Last heartbeat"))
            }
            .os1Style(theme.typography.smallCaps)
            .foregroundStyle(theme.palette.onCoralMuted)

            if worker.activeCompanies.isEmpty {
                Text(L10n.string("No active companies"))
                    .font(.caption2)
                    .foregroundStyle(theme.palette.onCoralMuted)
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(worker.activeCompanies) { company in
                        HStack(spacing: 6) {
                            Text(company.title)
                                .font(.caption2)
                                .foregroundStyle(theme.palette.onCoralSecondary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(latencyLabel(company.lastHeartbeatLatencySeconds))
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(theme.palette.onCoralMuted)
                                .lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(10)
        .frame(width: 260, alignment: .leading)
        .background(theme.palette.glassFill.opacity(0.78))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func header(_ key: String) -> some View {
        Text(L10n.string(key))
            .os1Style(theme.typography.smallCaps)
            .foregroundStyle(theme.palette.onCoralMuted)
    }

    private func cell(_ value: String) -> some View {
        Text(value)
            .os1Style(theme.typography.label)
            .foregroundStyle(theme.palette.onCoralSecondary)
            .lineLimit(1)
    }

    private func latencyLabel(_ seconds: Int?) -> String {
        guard let seconds else { return L10n.string("n/a") }
        if seconds < 60 { return L10n.string("%llds", seconds) }
        if seconds < 3_600 { return L10n.string("%lldm", seconds / 60) }
        return L10n.string("%lldh", seconds / 3_600)
    }
}
