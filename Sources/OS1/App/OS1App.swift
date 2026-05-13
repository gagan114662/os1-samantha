import AppKit
import SwiftUI

@main
struct OS1App: App {
    @NSApplicationDelegateAdaptor(HermesApplicationDelegate.self) private var appDelegate
    @StateObject private var appState = AppState()

    init() {
        // Register bundled DM Sans TTFs with Core Text so SwiftUI's
        // Font.custom resolves them. Must run before any view materializes.
        OS1FontRegistry.registerBundledFonts()
    }

    var body: some Scene {
        WindowGroup("OS1") {
            BootGate {
                RootView()
                    .environmentObject(appState)
            }
            .os1Theme()
            .foregroundStyle(.os1OnCoralPrimary)
            .tint(.os1OnCoralPrimary)
            .preferredColorScheme(.dark)
            .frame(minWidth: 940, minHeight: 520)
            .onOpenURL { url in
                // Provider OAuth callbacks (today: OpenRouter PKCE)
                // come back as os1://oauth/<provider>. The Providers
                // view-model owns the in-flight verifier; route to it
                // first and let it decide whether to consume the URL.
                appState.providersViewModel.handleOAuthCallback(url)
            }
        }
        .defaultSize(width: 1360, height: 860)
        .windowStyle(.hiddenTitleBar)
        .commands {
            OS1Commands(appState: appState)
        }

        Settings {
            HermesSettingsView()
                .environmentObject(appState)
                .os1Theme()
                .foregroundStyle(.os1OnCoralPrimary)
                .tint(.os1OnCoralPrimary)
                .preferredColorScheme(.dark)
        }
    }
}
