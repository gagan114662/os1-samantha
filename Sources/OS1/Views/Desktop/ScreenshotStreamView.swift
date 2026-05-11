import SwiftUI
import AppKit

/// Polls `/api/computers/{id}/screenshot` every 2.5s and renders the resulting
/// JPEG. Replaces the older noVNC-over-`/websockify` path which returns 404
/// on current Orgo VMs (their gateway no longer exposes the inner port).
///
/// Single source of truth — both `DesktopView` (one big stream) and `TilesView`
/// (grid of small streams) use this view, so the rendering can't drift between
/// the two surfaces.
///
/// Exposes a `Status` enum + optional `onStatusChange` callback so the host
/// view can show an accurate header badge instead of hard-coding "Streaming".
struct ScreenshotStreamView: View {

    /// Coarse-grained state for the host view to display. The view never
    /// shows a status badge itself — that's the host's job.
    enum Status: Equatable {
        case loading             // initial, before first response
        case live                // last success ≤ 10s ago
        case stale(secondsAgo: Int)   // last success > 10s ago, but the previous one is still on screen
        case failed(String)      // auth missing or last fetch errored before any success
    }

    let computerId: String
    /// When false, the view is decoration only (no click/keyboard forwarding).
    /// Tiles use this for compact grid cells; Desktop sets it true.
    var interactive: Bool = false
    /// Fires whenever the stream's coarse status transitions. Host views use
    /// this to keep their header badge in sync (live → stale → failed etc).
    var onStatusChange: ((Status) -> Void)? = nil

    @EnvironmentObject private var appState: AppState
    /// The currently-displayed frame. Held as a decoded NSImage so the next
    /// frame replaces it atomically — no flicker, no empty/loading flash.
    @State private var displayedImage: NSImage?
    @State private var lastSuccessAt: Date?
    @State private var status: Status = .loading
    @State private var pollTask: Task<Void, Never>?
    @FocusState private var keyboardFocused: Bool

    private let pollIntervalNanos: UInt64 = 2_500_000_000     // 2.5s
    private let staleThresholdSeconds: TimeInterval = 10
    /// Orgo VMs default to this resolution unless we override at create time.
    /// All clicks/types we forward must be in this coordinate space.
    private let vmWidth: CGFloat = 1280
    private let vmHeight: CGFloat = 720

    var body: some View {
        GeometryReader { geo in
            ZStack {
                if let image = displayedImage {
                    // Image swap is atomic via @State — the old frame stays on
                    // screen until the next decoded frame replaces it. No
                    // ProgressView interstitial, no flicker.
                    Image(nsImage: image)
                        .resizable()
                        .interpolation(.medium)
                        .aspectRatio(contentMode: .fit)
                } else if case .failed(let reason) = status {
                    Text(reason)
                        .foregroundStyle(.white.opacity(0.7))
                        .font(.caption)
                        .multilineTextAlignment(.center)
                        .padding(8)
                } else {
                    ProgressView().controlSize(.small).tint(.white.opacity(0.6))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(.rect)
            // Click + keyboard forwarding to the VM. Only enabled on the big
            // Desktop view; tile grid stays decoration-only.
            .modifier(InteractiveInputModifier(
                enabled: interactive,
                viewSize: geo.size,
                onTap: { local in tapOnVM(at: local, in: geo.size, double: false) },
                onDoubleTap: { local in tapOnVM(at: local, in: geo.size, double: true) },
                onKey: { sendKey($0) },
                onType: { sendType($0) },
                focused: $keyboardFocused
            ))
        }
        .onAppear { startPolling() }
        .onDisappear { stopPolling() }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        let computerId = self.computerId
        let apiKeyProvider: () -> String? = { [weak appState] in
            appState?.orgoCredentialStore.loadAPIKey()
                ?? ProcessInfo.processInfo.environment["ORGO_API_KEY"]
        }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                guard let apiKey = apiKeyProvider(), !apiKey.isEmpty else {
                    setStatus(.failed("No Orgo API key"))
                    return
                }
                // Fetch URL → fetch bytes → decode off-MainActor → set State.
                // Decoding off-MainActor keeps the UI responsive and prevents
                // a frame drop while the JPEG (~600KB) is being unpacked.
                if let url = await fetchScreenshotURL(computerId: computerId, apiKey: apiKey),
                   let image = await Self.decode(url: url) {
                    self.displayedImage = image
                    self.lastSuccessAt = Date()
                    setStatus(.live)
                } else if let last = self.lastSuccessAt {
                    let age = Int(Date().timeIntervalSince(last))
                    setStatus(age > Int(staleThresholdSeconds)
                              ? .stale(secondsAgo: age)
                              : .live)
                }
                try? await Task.sleep(nanoseconds: pollIntervalNanos)
            }
        }
    }

    /// Download the JPEG bytes off-actor, then decode to NSImage on the
    /// main actor. NSImage isn't Sendable so we hop back to main for the
    /// decode step. Returns nil on any failure so the previous frame stays
    /// on screen (avoids the flicker we had with AsyncImage placeholders).
    private static func decode(url: URL) async -> NSImage? {
        guard let data = await fetchBytes(url: url) else { return nil }
        return NSImage(data: data)
    }

    private static func fetchBytes(url: URL) async -> Data? {
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return (200..<300).contains(code) ? data : nil
        } catch {
            return nil
        }
    }

    private func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func setStatus(_ new: Status) {
        guard new != status else { return }
        status = new
        onStatusChange?(new)
    }

    // MARK: - VM input forwarding

    /// Map a tap in the view's coordinate space onto VM pixel coordinates,
    /// then POST `/click`. AsyncImage uses `.aspectRatio(.fit)` so the image
    /// is centered and letterboxed inside the view — we compute the actual
    /// image rect, drop taps that miss the image, and scale the rest.
    private func tapOnVM(at point: CGPoint, in viewSize: CGSize, double: Bool) {
        guard let rect = imageRect(in: viewSize), rect.contains(point) else { return }
        let xRatio = (point.x - rect.minX) / rect.width
        let yRatio = (point.y - rect.minY) / rect.height
        let vmX = Int(xRatio * vmWidth)
        let vmY = Int(yRatio * vmHeight)
        Task { await postOrgo("click", body: ["x": vmX, "y": vmY, "button": "left", "double": double]) }
    }

    private func sendKey(_ key: String) {
        guard !key.isEmpty else { return }
        Task { await postOrgo("key", body: ["key": key]) }
    }

    private func sendType(_ text: String) {
        guard !text.isEmpty else { return }
        Task { await postOrgo("type", body: ["text": text]) }
    }

    /// Rect that the actual image occupies inside the view (after `.aspectRatio(.fit)`).
    private func imageRect(in viewSize: CGSize) -> CGRect? {
        guard viewSize.width > 0 && viewSize.height > 0 else { return nil }
        let imageAspect = vmWidth / vmHeight
        let viewAspect = viewSize.width / viewSize.height
        var rect = CGRect.zero
        if viewAspect > imageAspect {
            // view is wider — letterboxes on the sides
            rect.size.height = viewSize.height
            rect.size.width = viewSize.height * imageAspect
            rect.origin.x = (viewSize.width - rect.size.width) / 2
        } else {
            // view is taller — letterboxes top/bottom
            rect.size.width = viewSize.width
            rect.size.height = viewSize.width / imageAspect
            rect.origin.y = (viewSize.height - rect.size.height) / 2
        }
        return rect
    }

    private func postOrgo(_ endpoint: String, body: [String: Any]) async {
        let apiKey = appState.orgoCredentialStore.loadAPIKey()
            ?? ProcessInfo.processInfo.environment["ORGO_API_KEY"]
            ?? ""
        guard !apiKey.isEmpty else { return }
        guard let url = URL(string: "https://www.orgo.ai/api/computers/\(computerId)/\(endpoint)") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 6
        _ = try? await URLSession.shared.data(for: req)
    }

    private func fetchScreenshotURL(computerId: String, apiKey: String) async -> URL? {
        guard let url = URL(string: "https://www.orgo.ai/api/computers/\(computerId)/screenshot") else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 8
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(code) else { return nil }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
            if let urlString = json["image"] as? String, urlString.hasPrefix("http") {
                return URL(string: urlString)
            }
            return nil
        } catch {
            return nil
        }
    }
}

// MARK: - Interactive input modifier

/// Conditionally attaches tap + keyboard forwarding to the stream view.
/// When `enabled` is false (e.g. for tile thumbnails) it's a no-op so
/// users don't accidentally click into a tile they only meant to look at.
///
/// The keyboard pipe: `.focusable() + .focused(...) + .onKeyPress(...)`.
/// Single visible characters route to `/type`; named keys (Return, Escape,
/// arrows, modifier combos via NSEvent.flags) route to `/key`.
private struct InteractiveInputModifier: ViewModifier {
    let enabled: Bool
    let viewSize: CGSize
    let onTap: (CGPoint) -> Void
    let onDoubleTap: (CGPoint) -> Void
    let onKey: (String) -> Void
    let onType: (String) -> Void
    @FocusState.Binding var focused: Bool

    func body(content: Content) -> some View {
        if enabled {
            content
                .onTapGesture(count: 2, coordinateSpace: .local) { p in
                    focused = true
                    onDoubleTap(p)
                }
                .onTapGesture(count: 1, coordinateSpace: .local) { p in
                    focused = true
                    onTap(p)
                }
                .focusable()
                .focused($focused)
                .focusEffectDisabled()
                .onKeyPress(phases: .down) { press in
                    Self.routeKey(press: press, onKey: onKey, onType: onType)
                }
        } else {
            content
        }
    }

    /// Map a SwiftUI `KeyPress` event onto the right Orgo endpoint:
    /// - Plain printable chars (with no modifiers) → `/type`
    /// - Anything with Cmd / Ctrl / Alt or a non-printable key → `/key` with xdotool-style name
    private static func routeKey(
        press: KeyPress,
        onKey: (String) -> Void,
        onType: (String) -> Void
    ) -> KeyPress.Result {
        let mods = press.modifiers
        let combo = comboString(modifiers: mods)
        if let name = namedKey(from: press.key) {
            onKey(combo.isEmpty ? name : "\(combo)+\(name)")
            return .handled
        }
        if mods.contains(.command) || mods.contains(.control) || mods.contains(.option) {
            // It's a chord on a printable key — route as keystroke (e.g. ctrl+c)
            let ch = press.characters.lowercased()
            if !ch.isEmpty {
                onKey("\(combo)+\(ch)")
                return .handled
            }
        }
        // Plain printable text — type it
        if !press.characters.isEmpty {
            onType(press.characters)
            return .handled
        }
        return .ignored
    }

    private static func comboString(modifiers: EventModifiers) -> String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("ctrl") }   // Linux side has no cmd; treat as ctrl
        if modifiers.contains(.control) { parts.append("ctrl") }
        if modifiers.contains(.option)  { parts.append("alt") }
        if modifiers.contains(.shift)   { parts.append("shift") }
        // Dedup (cmd+ctrl both map to ctrl on Linux)
        var seen = Set<String>()
        return parts.filter { seen.insert($0).inserted }.joined(separator: "+")
    }

    private static func namedKey(from key: KeyEquivalent) -> String? {
        switch key {
        case .return:        return "Return"
        case .tab:           return "Tab"
        case .escape:        return "Escape"
        case .delete:        return "BackSpace"
        case .deleteForward: return "Delete"
        case .space:         return "space"
        case .upArrow:       return "Up"
        case .downArrow:     return "Down"
        case .leftArrow:     return "Left"
        case .rightArrow:    return "Right"
        case .home:          return "Home"
        case .end:           return "End"
        case .pageUp:        return "Page_Up"
        case .pageDown:      return "Page_Down"
        default:             return nil
        }
    }
}
