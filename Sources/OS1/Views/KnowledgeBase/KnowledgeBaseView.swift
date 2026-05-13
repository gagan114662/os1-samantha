import AppKit
import SwiftUI

struct KnowledgeBaseView: View {
    @EnvironmentObject private var appState: AppState
    @Binding var splitLayout: HermesSplitLayout

    var body: some View {
        HermesPersistentHSplitView(layout: $splitLayout, detailMinWidth: 380) {
            VStack(alignment: .leading, spacing: 18) {
                HermesPageHeader(
                    title: "Knowledge Base",
                    subtitle: "Sync an Obsidian vault — or any markdown folder — to ground Hermes in your own notes."
                ) {
                    HermesRefreshButton(isRefreshing: appState.isRefreshingKnowledgeBase) {
                        Task { await appState.refreshKnowledgeBase() }
                    }
                    .disabled(appState.isLoadingKnowledgeBase || appState.isUploadingKnowledgeBase)
                }

                toolbar
                content
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 20)
            .padding(.vertical, 20)
            .safeAreaPadding(.top, 8)
        } detail: {
            detailColumn
                .hermesSplitDetailColumn(minWidth: 380, idealWidth: 520)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .task(id: appState.activeConnectionID) {
            await appState.loadKnowledgeBase()
        }
    }

    @ViewBuilder
    private var toolbar: some View {
        HStack(spacing: 10) {
            HermesCreateActionButton(appState.knowledgeVault == nil ? "Add Vault" : "Re-sync Vault") {
                pickAndUpload()
            }
            .disabled(appState.isUploadingKnowledgeBase || appState.isRemovingKnowledgeBase)

            if appState.knowledgeVault != nil {
                Button(role: .destructive) {
                    Task { await appState.removeKnowledgeBase() }
                } label: {
                    Text(L10n.string("Remove"))
                        .font(.os1SmallCaps)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.os1OnCoralSecondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(Capsule().strokeBorder(Color.os1OnCoralSecondary.opacity(0.3), lineWidth: 1))
                .disabled(appState.isUploadingKnowledgeBase || appState.isRemovingKnowledgeBase)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private var content: some View {
        if appState.isLoadingKnowledgeBase && appState.knowledgeVault == nil {
            HermesSurfacePanel {
                HermesLoadingState(label: "Loading knowledge base…", minHeight: 240)
            }
        } else if let error = appState.knowledgeBaseError, appState.knowledgeVault == nil {
            HermesSurfacePanel {
                ContentUnavailableView(
                    L10n.string("Unable to load the knowledge base"),
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        } else if let vault = appState.knowledgeVault {
            HermesSurfacePanel(
                title: vault.manifest.name,
                subtitle: "Last synced \(vault.manifest.displayLastSynced)"
            ) {
                vaultRow(vault)
            }
        } else {
            HermesSurfacePanel {
                ContentUnavailableView(
                    L10n.string("No knowledge base yet"),
                    systemImage: "books.vertical",
                    description: Text(L10n.string("Pick an Obsidian vault folder (or any folder of markdown notes) to sync it as Hermes' grounded context."))
                )
                .frame(maxWidth: .infinity, minHeight: 240)
            }
        }
    }

    @ViewBuilder
    private func vaultRow(_ vault: KnowledgeVaultSummary) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 16) {
                metric(label: "Files", value: "\(vault.manifest.fileCount)")
                metric(label: "Size", value: vault.manifest.displaySize)
                metric(label: "Mounted", value: vault.rootPath, isMonospaced: true)
            }

            if let source = vault.manifest.source, !source.isEmpty {
                Text(L10n.string("Source: %@", source))
                    .font(.os1SmallCaps)
                    .foregroundStyle(.os1OnCoralSecondary)
                    .textSelection(.enabled)
            }

            if appState.knowledgeSkillInstalled {
                HermesBadge(text: "Skill installed", tint: .accentColor, systemImage: "checkmark.seal.fill")
            } else {
                HermesBadge(text: "Skill missing", tint: .secondary, systemImage: "exclamationmark.triangle")
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func metric(label: String, value: String, isMonospaced: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(L10n.string(label))
                .font(.os1SmallCaps)
                .foregroundStyle(.os1OnCoralSecondary)
            Text(value)
                .font(isMonospaced ? .system(.body, design: .monospaced) : .os1Body)
                .foregroundStyle(.os1OnCoralPrimary)
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private var detailColumn: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(L10n.string("How Hermes uses your vault"))
                    .font(.os1TitlePanel)
                    .foregroundStyle(.os1OnCoralPrimary)

                bulletParagraph(
                    title: "Where it lives",
                    body: "The vault is mounted at $HERMES_HOME/knowledge on the agent's host. The agent reads it directly via shell tools (cat, rg)."
                )
                bulletParagraph(
                    title: "Auto-installed skill",
                    body: "On the first sync, an SKILL.md is written to $HERMES_HOME/skills/knowledge-base/. It tells Hermes to read INDEX.md first, ripgrep for keywords, and cite files in [[wikilinks]] when answering."
                )
                bulletParagraph(
                    title: "What gets synced",
                    body: "Markdown files and most text content. Excluded by default: .DS_Store, .git, .obsidian/workspace.json, .obsidian/cache, .trash, node_modules. The compressed payload is capped at 64 MB."
                )
                bulletParagraph(
                    title: "Re-sync to update",
                    body: "Click Re-sync Vault after you edit notes locally. Each upload is staged and atomically swapped, so the agent never reads a half-written vault."
                )

                if let error = appState.knowledgeBaseError {
                    HermesSurfacePanel {
                        Text(error)
                            .font(.os1Body)
                            .foregroundStyle(.os1OnCoralPrimary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private func bulletParagraph(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(title))
                .font(.os1SmallCaps)
                .foregroundStyle(.os1OnCoralSecondary)
            Text(L10n.string(body))
                .font(.os1Body)
                .foregroundStyle(.os1OnCoralPrimary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func pickAndUpload() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.title = L10n.string("Choose a vault folder")
        panel.message = L10n.string("Pick the root of your Obsidian vault (or any folder of markdown notes).")
        panel.prompt = L10n.string("Sync")

        guard panel.runModal() == .OK, let url = panel.url else { return }

        let vaultName = url.lastPathComponent
        Task {
            _ = await appState.uploadKnowledgeBase(localFolder: url, vaultName: vaultName)
        }
    }
}
