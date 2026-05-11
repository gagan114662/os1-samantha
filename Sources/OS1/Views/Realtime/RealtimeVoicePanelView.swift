import SwiftUI
import WebKit

struct RealtimeVoicePanelView: View {
    @Environment(\.os1Theme) private var theme
    @StateObject private var server: RealtimeVoiceSessionServer
    @State private var pageStatus = "idle"

    let onClose: () -> Void

    init(
        elevenLabsAPIKey: String? = nil,
        elevenLabsAgentID: String? = nil,
        orgoAPIKey: String? = nil,
        orgoDefaultComputerID: String? = nil,
        onClose: @escaping () -> Void
    ) {
        _server = StateObject(wrappedValue: RealtimeVoiceSessionServer(
            elevenLabsAPIKeyProvider: { elevenLabsAPIKey ?? ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] },
            agentIDProvider: { elevenLabsAgentID ?? ProcessInfo.processInfo.environment["ELEVENLABS_AGENT_ID"] },
            orgoAPIKeyProvider: { orgoAPIKey ?? ProcessInfo.processInfo.environment["ORGO_API_KEY"] },
            orgoDefaultComputerIDProvider: { orgoDefaultComputerID ?? ProcessInfo.processInfo.environment["ORGO_DEFAULT_COMPUTER_ID"] }
        ))
        self.onClose = onClose
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: "mic.circle.fill")
                    .font(.system(size: 20, weight: .regular))
                VStack(alignment: .leading, spacing: 2) {
                    Text(L10n.string("Realtime Voice"))
                        .os1Style(theme.typography.titlePanel)
                    Text(server.statusText)
                        .os1Style(theme.typography.label)
                        .foregroundStyle(theme.palette.onCoralSecondary)
                }

                Spacer(minLength: 0)

                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.os1Icon)
            }
            .foregroundStyle(theme.palette.onCoralPrimary)

            if let error = server.lastError {
                Text(error)
                    .os1Style(theme.typography.body)
                    .foregroundStyle(theme.palette.onCoralSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .os1GlassSurface(cornerRadius: 8)
            } else if let endpointURL = server.endpointURL {
                RealtimeVoiceWebView(url: endpointURL) { status in
                    pageStatus = status
                }
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(theme.palette.glassBorder, lineWidth: 1)
                }

                HStack {
                    Text(L10n.string("Browser: %@", pageStatus))
                        .os1Style(theme.typography.label)
                        .foregroundStyle(theme.palette.onCoralMuted)
                    Spacer(minLength: 0)
                }
            } else {
                ProgressView()
                    .progressViewStyle(.circular)
                    .tint(theme.palette.onCoralPrimary)
                    .frame(maxWidth: .infinity, minHeight: 160)
            }
        }
        .padding(14)
        .frame(width: 390, height: 560)
        .os1GlassSurface(cornerRadius: 8)
        .shadow(color: .black.opacity(0.20), radius: 24, x: 0, y: 14)
        .task {
            server.start()
        }
        .onDisappear {
            server.stop()
        }
    }
}

struct RealtimeVoiceRuntimeView: View {
    @StateObject private var server: RealtimeVoiceSessionServer

    let onStatus: (String) -> Void

    init(
        elevenLabsAPIKey: String? = nil,
        elevenLabsAgentID: String? = nil,
        orgoAPIKey: String? = nil,
        orgoDefaultComputerID: String? = nil,
        onStatus: @escaping (String) -> Void
    ) {
        _server = StateObject(wrappedValue: RealtimeVoiceSessionServer(
            elevenLabsAPIKeyProvider: { elevenLabsAPIKey ?? ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] },
            agentIDProvider: { elevenLabsAgentID ?? ProcessInfo.processInfo.environment["ELEVENLABS_AGENT_ID"] },
            orgoAPIKeyProvider: { orgoAPIKey ?? ProcessInfo.processInfo.environment["ORGO_API_KEY"] },
            orgoDefaultComputerIDProvider: { orgoDefaultComputerID ?? ProcessInfo.processInfo.environment["ORGO_DEFAULT_COMPUTER_ID"] }
        ))
        self.onStatus = onStatus
    }

    var body: some View {
        Group {
            if let endpointURL = server.endpointURL {
                RealtimeVoiceWebView(url: endpointURL, onStatus: onStatus)
            } else {
                Color.clear
            }
        }
        .task {
            onStatus("starting")
            server.start()
        }
        .onDisappear {
            server.stop()
            onStatus("off")
        }
        .onChange(of: server.statusText) { _, status in
            onStatus(status)
        }
        .onChange(of: server.lastError) { _, error in
            if let error {
                onStatus("error: \(error)")
            }
        }
    }
}

private struct RealtimeVoiceWebView: NSViewRepresentable {
    let url: URL
    let onStatus: (String) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onStatus: onStatus)
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        let userContentController = WKUserContentController()
        userContentController.add(context.coordinator, name: "voiceStatus")
        configuration.userContentController = userContentController
        configuration.mediaTypesRequiringUserActionForPlayback = []

        let pagePreferences = WKWebpagePreferences()
        pagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = pagePreferences

        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        webView.uiDelegate = context.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsMagnification = false
        context.coordinator.url = url
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.onStatus = onStatus
        if context.coordinator.url != url {
            context.coordinator.url = url
            webView.load(URLRequest(url: url))
        }
    }

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKNavigationDelegate, WKUIDelegate {
        var onStatus: (String) -> Void
        var url: URL?

        init(onStatus: @escaping (String) -> Void) {
            self.onStatus = onStatus
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard message.name == "voiceStatus" else { return }
            if let payload = message.body as? [String: Any], let status = payload["status"] as? String {
                onStatus(status)
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            onStatus(error.localizedDescription)
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            onStatus(error.localizedDescription)
        }

        @available(macOS 12.0, *)
        func webView(
            _ webView: WKWebView,
            requestMediaCapturePermissionFor origin: WKSecurityOrigin,
            initiatedByFrame frame: WKFrameInfo,
            type: WKMediaCaptureType,
            decisionHandler: @escaping @MainActor @Sendable (WKPermissionDecision) -> Void
        ) {
            decisionHandler(.grant)
        }
    }
}
