import SwiftUI

struct HermesSettingsView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.os1Theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(L10n.string("Settings"))
                .os1Style(theme.typography.titleSection)
                .foregroundStyle(theme.palette.onCoralPrimary)

            HermesSurfacePanel(
                title: "Hermes updates",
                subtitle: "Control how OS1 checks for Hermes Agent updates on the active host."
            ) {
                Toggle(isOn: Binding(
                    get: { appState.checkForHermesUpdatesAutomatically },
                    set: { appState.setCheckForHermesUpdatesAutomatically($0) }
                )) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(L10n.string("Check for updates automatically"))
                            .os1Style(theme.typography.bodyEmphasis)
                            .foregroundStyle(theme.palette.onCoralPrimary)
                        Text(L10n.string("When disabled, OS1 will not re-surface the same update on every launch; a banner appears again only after a new offered version is detected."))
                            .os1Style(theme.typography.label)
                            .foregroundStyle(theme.palette.onCoralSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
            }
        }
        .padding(24)
        .frame(width: 520, alignment: .topLeading)
        .background(theme.palette.coral)
    }
}
