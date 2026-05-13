import SwiftUI

struct SkillsView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var splitLayout: HermesSplitLayout
    @State private var searchText = ""
    @State private var selectedTag: String?
    @State private var editorMode: SkillEditorMode?
    @State private var editorDraft = SkillDraft()
    @State private var rawMarkdownContent = ""

    var body: some View {
        HermesPersistentHSplitView(layout: $splitLayout, detailMinWidth: 420) {
            VStack(alignment: .leading, spacing: 18) {
                HermesPageHeader(
                    title: "Skills",
                    subtitle: "Browse the Hermes skill library discovered on the active host."
                ) {
                    HStack(spacing: 10) {
                        HermesRefreshButton(isRefreshing: appState.isRefreshingSkills) {
                            Task { await appState.refreshSkills() }
                        }
                        .disabled(appState.isLoadingSkills || appState.isSavingSkillDraft)

                        skillsSearchField
                    }
                    .fixedSize(horizontal: true, vertical: false)
                }

                skillsToolbar
                skillsContent
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
        } detail: {
            detailContent
                .hermesSplitDetailColumn(minWidth: 420, idealWidth: 560)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: appState.activeConnectionID) {
            if appState.skills.isEmpty {
                await appState.loadSkills(reset: true)
            }
        }
    }

    @ViewBuilder
    private var skillsContent: some View {
        skillsPanel
    }

    @ViewBuilder
    private var skillsPanel: some View {
        if appState.isLoadingSkills && appState.skills.isEmpty {
            HermesSurfacePanel {
                HermesLoadingState(
                    label: "Loading skills…",
                    minHeight: 300
                )
            }
        } else if let error = appState.skillsError, appState.skills.isEmpty {
            HermesSurfacePanel {
                ContentUnavailableView(
                    L10n.string("Unable to load skills"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        } else if appState.skills.isEmpty {
            HermesSurfacePanel {
                ContentUnavailableView(
                    L10n.string("No skills found"),
                    systemImage: "book.closed",
                    description: Text(L10n.string("No readable SKILL.md files were discovered in the Hermes skill roots for this SSH target."))
                )
                .frame(maxWidth: .infinity, minHeight: 300)
            }
        } else {
            HermesSurfacePanel(
                title: panelTitle,
                subtitle: "Select a skill to inspect its metadata, related assets and full SKILL.md content."
            ) {
                VStack(alignment: .leading, spacing: 14) {
                    tagFilterChips

                    if filteredSkills.isEmpty {
                        ContentUnavailableView(
                            L10n.string("No matching skills"),
                            systemImage: "magnifyingglass",
                            description: Text(L10n.string("Try searching by skill name or category."))
                        )
                        .frame(maxWidth: .infinity, minHeight: 300)
                    } else {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 10) {
                                ForEach(filteredSkills) { skill in
                                    SkillCardRow(
                                        skill: skill,
                                        isSelected: skill.id == appState.selectedSkillID
                                    ) {
                                        Task {
                                            await appState.loadSkillDetail(summary: skill)
                                        }
                                    }
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if appState.isLoadingSkills && !appState.isRefreshingSkills && !appState.skills.isEmpty {
                    HermesLoadingOverlay()
                        .padding(18)
                }
            }
        }
    }

    private var skillsToolbar: some View {
        HStack(spacing: 10) {
            HermesCreateActionButton("New Skill") {
                startCreating()
            }
            .disabled(appState.isSavingSkillDraft || appState.isLoadingSkills)
        }
        .fixedSize(horizontal: true, vertical: false)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var skillsSearchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.os1OnCoralMuted)
                .frame(width: 14, height: 14)

            TextField(L10n.string("Search skills"), text: $searchText)
                .textFieldStyle(.plain)
                .font(.os1Body)
                .foregroundStyle(.os1OnCoralPrimary)
                .submitLabel(.search)
                .frame(width: 220, alignment: .leading)

            Button {
                if !searchText.isEmpty {
                    searchText = ""
                }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(.os1OnCoralMuted)
                    .opacity(searchText.isEmpty ? 0 : 1)
            }
            .buttonStyle(.plain)
            .disabled(searchText.isEmpty)
            .accessibilityLabel(L10n.string("Close search"))
        }
        .padding(.horizontal, 10)
        .frame(height: 30, alignment: .leading)
        .background(Color.os1GlassFill)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.os1GlassBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var tagFilterChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                SkillTagFilterChip(
                    title: L10n.string("All"),
                    isSelected: selectedTag == nil
                ) {
                    selectedTag = nil
                }

                ForEach(availableTags, id: \.self) { tag in
                    SkillTagFilterChip(
                        title: tag,
                        isSelected: SkillSummary.normalizedTag(selectedTag ?? "") == SkillSummary.normalizedTag(tag)
                    ) {
                        selectedTag = tag
                    }
                }
            }
            .padding(.bottom, 2)
        }
    }

    private var panelTitle: String {
        let total = appState.skills.count
        let filtered = filteredSkills.count

        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && selectedTag == nil {
            return L10n.string("Discovered Skills (%@)", "\(total)")
        }

        return L10n.string("Discovered Skills (%@ of %@)", "\(filtered)", "\(total)")
    }

    private var filteredSkills: [SkillSummary] {
        appState.skills.filter { skill in
            skill.matchesSearch(searchText) && skill.matchesTag(selectedTag)
        }
    }

    private var availableTags: [String] {
        let tagsByNormalizedValue = Dictionary(
            appState.skills.flatMap(\.tags).compactMap { tag -> (String, String)? in
                let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return nil }
                return (SkillSummary.normalizedTag(trimmed), trimmed)
            },
            uniquingKeysWith: { current, candidate in
                current.localizedStandardCompare(candidate) == .orderedAscending ? current : candidate
            }
        )

        return tagsByNormalizedValue.values.sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }
    }

    private var selectedSkill: SkillSummary? {
        guard let selectedSkillID = appState.selectedSkillID else { return nil }
        return appState.skills.first(where: { $0.id == selectedSkillID })
    }

    @ViewBuilder
    private var detailContent: some View {
        if let editorMode {
            SkillEditorView(
                mode: editorMode,
                draft: $editorDraft,
                rawMarkdownContent: $rawMarkdownContent,
                detail: appState.selectedSkillDetail,
                errorMessage: appState.skillsError,
                isSaving: appState.isSavingSkillDraft,
                onCancel: {
                    self.editorMode = nil
                },
                onSave: {
                    await saveEditor()
                }
            )
        } else {
            SkillDetailView(
                summary: selectedSkill,
                detail: appState.selectedSkillDetail,
                errorMessage: appState.skillsError,
                isLoading: appState.isLoadingSkillDetail,
                onCreate: {
                    startCreating()
                },
                onEdit: {
                    startEditing()
                }
            )
        }
    }
    private func startCreating() {
        var draft = SkillDraft()
        draft.refreshSuggestedSlug()
        editorDraft = draft
        rawMarkdownContent = draft.generatedMarkdown
        editorMode = .create
    }

    private func startEditing() {
        guard let detail = appState.selectedSkillDetail, !detail.isReadOnly else { return }
        editorDraft = SkillDraft.from(detail: detail)
        rawMarkdownContent = detail.markdownContent
        editorMode = .edit
    }

    private func saveEditor() async {
        switch editorMode {
        case .create:
            let didSave = await appState.createSkill(editorDraft)
            if didSave {
                editorMode = nil
            }
        case .edit:
            guard let detail = appState.selectedSkillDetail else { return }
            let didSave = await appState.updateSkill(
                detail,
                markdownContent: rawMarkdownContent,
                ensureReferencesFolder: editorDraft.includeReferencesFolder,
                ensureScriptsFolder: editorDraft.includeScriptsFolder,
                ensureTemplatesFolder: editorDraft.includeTemplatesFolder
            )
            if didSave {
                editorMode = nil
            }
        case nil:
            break
        }
    }
}

private struct SkillTagFilterChip: View {
    let title: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.os1SmallCaps)
                .lineLimit(1)
                .foregroundStyle(isSelected ? .os1Coral : .os1OnCoralSecondary)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(
                    Capsule()
                        .fill(isSelected ? Color.os1OnCoralPrimary : Color.os1OnCoralSecondary.opacity(0.08))
                )
                .overlay {
                    Capsule()
                        .strokeBorder(Color.os1OnCoralPrimary.opacity(isSelected ? 0 : 0.10), lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }
}

private struct SkillCardRow: View {
    let skill: SkillSummary
    let isSelected: Bool
    let onSelect: () -> Void

    private var cardFillColor: Color {
        isSelected ? Color.os1OnCoralPrimary.opacity(0.12) : Color.os1OnCoralSecondary.opacity(0.08)
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(spacing: 8) {
                            Text(skill.resolvedName)
                                .font(.os1TitlePanel)
                                .foregroundStyle(.os1OnCoralPrimary)
                                .multilineTextAlignment(.leading)

                            if !skill.source.isLocal {
                                HermesBadge(text: skill.sourceLabel, tint: .secondary)
                            }
                        }

                        Text(skill.relativePath)
                            .font(.os1SmallCaps)
                            .foregroundStyle(.os1OnCoralSecondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 12)

                    if let category = skill.category {
                        HermesBadge(text: category, tint: .secondary)
                    }
                }

                if let description = skill.trimmedDescription {
                    Text(description)
                        .font(.os1Body)
                        .foregroundStyle(.os1OnCoralSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                } else {
                    Text(L10n.string("No description in frontmatter"))
                        .font(.os1Body)
                        .foregroundStyle(.os1OnCoralSecondary)
                        .italic()
                }

                if !skill.previewBadges.isEmpty {
                    SkillCardBadgeScroller(
                        badges: skill.previewBadges,
                        backgroundColor: cardFillColor
                    )
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(cardFillColor)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .strokeBorder(Color.os1OnCoralPrimary.opacity(isSelected ? 0.12 : 0.06), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
    }
}

private struct SkillCardBadgeScroller: View {
    let badges: [SkillPreviewBadge]
    let backgroundColor: Color

    var body: some View {
        HermesWrappingFlowLayout(horizontalSpacing: 8, verticalSpacing: 8) {
            ForEach(badges) { badge in
                HermesBadge(
                    text: badge.text,
                    tint: badge.tint,
                    isMonospaced: badge.isMonospaced
                )
            }
        }
    }
}

private struct SkillPreviewBadge: Identifiable {
    let id: String
    let text: String
    let tint: Color
    var isMonospaced = false
}

private extension SkillSummary {
    var previewBadges: [SkillPreviewBadge] {
        var badges: [SkillPreviewBadge] = []

        if let version, !version.isEmpty {
            badges.append(
                SkillPreviewBadge(
                    id: "version-\(version)",
                    text: version,
                    tint: .secondary,
                    isMonospaced: true
                )
            )
        }

        for tag in tags {
            badges.append(
                SkillPreviewBadge(
                    id: "tag-\(tag)",
                    text: tag,
                    tint: .accentColor
                )
            )
        }

        for relatedSkill in relatedSkills {
            badges.append(
                SkillPreviewBadge(
                    id: "related-\(relatedSkill)",
                    text: relatedSkill,
                    tint: .secondary,
                    isMonospaced: true
                )
            )
        }

        for feature in featureBadges {
            badges.append(
                SkillPreviewBadge(
                    id: "feature-\(feature.id)",
                    text: feature.title,
                    tint: feature.color
                )
            )
        }

        return badges
    }
}
