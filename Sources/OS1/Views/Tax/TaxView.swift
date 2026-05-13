import SwiftUI

/// One-click per-entity-per-tax-year export action + quarterly tax-estimate
/// panel. Operator picks an entity + year, presses Export, the bundles land
/// in the chosen directory in the layout documented in `docs/tax-export.md`.
struct TaxView: View {
    @ObservedObject var viewModel: TaxViewModel
    @State private var showingFilePicker = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header

                if viewModel.registry.entities.isEmpty {
                    emptyState
                } else {
                    exportPanel
                    quarterlyPanel
                    if let status = viewModel.statusMessage {
                        Text(status)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tax pipeline")
                .font(.title)
                .fontWeight(.semibold)
            Text("Per-entity, per-jurisdiction exports ready for filing. Bundles are deterministic — same inputs → byte-identical bytes.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("No tax entities registered yet.")
                .font(.headline)
            Text("Populate `~/.os1/entities.json` with your entity registry (operator personal, each LLC, each Stripe Connect sub-account). See `docs/tax-export.md` for the schema.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding()
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Export bundle")
                .font(.headline)
            HStack(spacing: 12) {
                Picker("Entity", selection: $viewModel.selectedEntityID) {
                    ForEach(viewModel.registry.entities, id: \.id) { entity in
                        Text("\(entity.legalName) (\(entity.id))").tag(Optional(entity.id))
                    }
                }
                .pickerStyle(.menu)
                .frame(maxWidth: 320)

                Stepper(value: $viewModel.taxYear, in: 2020...2099) {
                    Text("Tax year: \(String(format: "%d", viewModel.taxYear))")
                }
                .frame(maxWidth: 240)

                Button("Export…") {
                    showingFilePicker = true
                }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(viewModel.selectedEntityID == nil)
            }
            if let last = viewModel.lastExport {
                Text("Last export: \(last.bundleCount) bundle(s) for \(last.entityID) (\(last.jurisdictions.joined(separator: ", ")))")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
        .fileImporter(
            isPresented: $showingFilePicker,
            allowedContentTypes: [.folder],
            onCompletion: handleDirectoryPick
        )
        .onChange(of: viewModel.selectedEntityID) { _, _ in
            viewModel.recomputeQuarterlyEstimates()
        }
        .onChange(of: viewModel.taxYear) { _, _ in
            viewModel.recomputeQuarterlyEstimates()
        }
    }

    private var quarterlyPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Quarterly estimated payments")
                .font(.headline)
            if viewModel.quarterlyEstimates.isEmpty {
                Text("No US-FED or US-CA jurisdictions configured for this entity.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(viewModel.quarterlyEstimates) { estimate in
                    HStack {
                        Text(estimate.jurisdiction)
                            .frame(width: 90, alignment: .leading)
                            .monospaced()
                        Text(estimate.quarter)
                            .frame(width: 40, alignment: .leading)
                        Text(estimate.deadline)
                            .frame(width: 140, alignment: .leading)
                            .monospaced()
                        Text(estimate.daysUntilDeadline == 0 ? "due" : "in \(estimate.daysUntilDeadline) day(s)")
                            .foregroundStyle(estimate.daysUntilDeadline <= 14 ? .orange : .secondary)
                    }
                    .font(.callout)
                }
            }
        }
        .padding()
        .background(Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
    }

    private func handleDirectoryPick(_ result: Result<URL, Error>) {
        guard case .success(let url) = result else { return }
        do {
            _ = try viewModel.runExport(
                to: url,
                sourceLedgerCommitHash: "in-app-\(Int(Date().timeIntervalSince1970))"
            )
        } catch {
            viewModel.statusMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}
