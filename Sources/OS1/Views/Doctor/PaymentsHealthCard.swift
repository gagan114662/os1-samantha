import SwiftUI

struct PaymentsHealthSnapshot: Codable, Hashable, Sendable {
    struct Row: Codable, Hashable, Identifiable, Sendable {
        var id: String { provider }
        var provider: String
        var endpoint: String
        var lastEvent: String
        var reconciliation: String
        var replayStoreSize: Int
    }

    var rows: [Row]

    static let empty = PaymentsHealthSnapshot(rows: [])

    static func fixture(rows: [Row]) -> PaymentsHealthSnapshot {
        PaymentsHealthSnapshot(rows: rows)
    }
}

struct PaymentsHealthCard: View {
    @Environment(\.os1Theme) private var theme
    let snapshot: PaymentsHealthSnapshot

    var body: some View {
        HermesSurfacePanel {
            VStack(alignment: .leading, spacing: 12) {
                Text(L10n.string("Payments"))
                    .os1Style(theme.typography.titlePanel)
                    .foregroundStyle(theme.palette.onCoralPrimary)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                    GridRow {
                        header("Provider")
                        header("Endpoint")
                        header("Last event")
                        header("Reconciliation")
                        header("Replay store size")
                    }
                    ForEach(snapshot.rows) { row in
                        GridRow {
                            cell(row.provider)
                            cell(row.endpoint)
                            cell(row.lastEvent)
                            cell(row.reconciliation)
                            cell("\(row.replayStoreSize)")
                        }
                    }
                }
            }
        }
    }

    static func renderedRows(snapshot: PaymentsHealthSnapshot) -> [String] {
        snapshot.rows.map {
            "\($0.provider)|\($0.endpoint)|\($0.lastEvent)|\($0.reconciliation)|\($0.replayStoreSize)"
        }
    }

    private func header(_ key: String) -> some View {
        Text(L10n.string(key))
            .os1Style(theme.typography.smallCaps)
            .foregroundStyle(theme.palette.onCoralMuted)
            .lineLimit(1)
    }

    private func cell(_ value: String) -> some View {
        Text(value)
            .os1Style(theme.typography.body)
            .foregroundStyle(theme.palette.onCoralSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
