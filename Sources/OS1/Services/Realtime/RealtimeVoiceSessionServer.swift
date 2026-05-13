import Foundation
import Network

final class RealtimeVoiceSessionServer: ObservableObject, @unchecked Sendable {
    @Published private(set) var endpointURL: URL?
    @Published private(set) var statusText: String = "Stopped"
    @Published private(set) var lastError: String?

    private let queue = DispatchQueue(label: "com.elementsoftware.os1.realtime-voice")
    private var listener: NWListener?
    static let localServerPortFileName = "local-server-port"
    static let legacyVoicePortFileName = "voice-port"

    // Internal — extensions in the same module use these to implement
    // their endpoint handlers (RealtimeVoiceSessionServer+Orgo.swift, etc).
    var apiKey: String?
    var agentID: String?
    let elevenLabsAPIKeyProvider: @Sendable () -> String?
    let agentIDProvider: @Sendable () -> String?
    let runtimeDirectoryProvider: @Sendable () -> URL
    let orgoMCPBridge: RealtimeOrgoMCPBridge

    init(
        // Each provider: env var first (overrides for dev/test), then Keychain
        // (production path — launchd plists can drop the inline secrets).
        elevenLabsAPIKeyProvider: @escaping @Sendable () -> String? = {
            ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"]
                ?? KeychainSecret.read(service: "io.elevenlabs.api-key")
        },
        agentIDProvider: @escaping @Sendable () -> String? = {
            ProcessInfo.processInfo.environment["ELEVENLABS_AGENT_ID"]
                ?? KeychainSecret.read(service: "io.elevenlabs.agent-id")
        },
        orgoAPIKeyProvider: @escaping @Sendable () -> String? = {
            ProcessInfo.processInfo.environment["ORGO_API_KEY"]
                ?? KeychainSecret.read(service: "ai.orgo.mac.api-key")
        },
        orgoDefaultComputerIDProvider: @escaping @Sendable () -> String? = {
            ProcessInfo.processInfo.environment["ORGO_DEFAULT_COMPUTER_ID"]
        },
        runtimeDirectoryProvider: @escaping @Sendable () -> URL = {
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".os1", isDirectory: true)
        }
    ) {
        self.elevenLabsAPIKeyProvider = elevenLabsAPIKeyProvider
        self.agentIDProvider = agentIDProvider
        self.runtimeDirectoryProvider = runtimeDirectoryProvider
        self.orgoMCPBridge = RealtimeOrgoMCPBridge(
            apiKeyProvider: orgoAPIKeyProvider,
            defaultComputerIDProvider: orgoDefaultComputerIDProvider
        )
    }

    deinit {
        listener?.cancel()
    }

    func start() {
        guard listener == nil else { return }

        self.apiKey = Self.nonEmptyCredential(elevenLabsAPIKeyProvider())
        self.agentID = Self.nonEmptyCredential(agentIDProvider())

        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)

            let listener = try NWListener(using: parameters)
            self.listener = listener
            statusText = "Starting local HTTP endpoint"
            lastError = nil

            listener.stateUpdateHandler = { [weak self] state in
                self?.handleListenerState(state)
            }
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            listener.start(queue: queue)
        } catch {
            statusText = "Failed to start local HTTP endpoint"
            lastError = error.localizedDescription
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        endpointURL = nil
        statusText = "Stopped"
    }

    private func handleListenerState(_ state: NWListener.State) {
        switch state {
        case .ready:
            guard let port = listener?.port else { return }
            Self.writePortFiles(port: port.rawValue, runtimeDirectory: runtimeDirectoryProvider())
            DispatchQueue.main.async { [weak self] in
                self?.endpointURL = URL(string: "http://127.0.0.1:\(port.rawValue)/")
                self?.statusText = self?.apiKey == nil || self?.agentID == nil
                    ? "Local HTTP endpoint ready; voice credentials missing"
                    : "Voice endpoint ready"
                self?.lastError = nil
            }
        case .failed(let error):
            DispatchQueue.main.async { [weak self] in
                self?.endpointURL = nil
                self?.statusText = "Local HTTP endpoint failed"
                self?.lastError = error.localizedDescription
                self?.listener?.cancel()
                self?.listener = nil
            }
        case .cancelled:
            DispatchQueue.main.async { [weak self] in
                self?.endpointURL = nil
                self?.statusText = "Stopped"
            }
        default:
            break
        }
    }

    private static func nonEmptyCredential(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed?.isEmpty == false ? trimmed : nil
    }

    static func writePortFiles(port: UInt16, runtimeDirectory: URL) {
        let localServerPortURL = runtimeDirectory.appendingPathComponent(localServerPortFileName)
        let legacyVoicePortURL = runtimeDirectory.appendingPathComponent(legacyVoicePortFileName)
        let portText = "\(port)"
        try? FileManager.default.createDirectory(
            at: runtimeDirectory,
            withIntermediateDirectories: true
        )
        try? portText.write(to: localServerPortURL, atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(at: legacyVoicePortURL)
        do {
            try FileManager.default.createSymbolicLink(
                atPath: legacyVoicePortURL.path,
                withDestinationPath: localServerPortURL.path
            )
        } catch {
            try? portText.write(to: legacyVoicePortURL, atomically: true, encoding: .utf8)
        }
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(from: connection, buffered: Data())
    }

    private func receive(from connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }

            if let error {
                self.send(.plain(status: 400, body: "Request receive failed: \(error.localizedDescription)"), on: connection)
                return
            }

            var requestData = buffered
            if let data {
                requestData.append(data)
            }

            if requestData.count > 1_000_000 {
                self.send(.plain(status: 413, body: "Request body too large"), on: connection)
                return
            }

            if let request = HTTPRequest(data: requestData) {
                self.route(request, on: connection)
                return
            }

            if isComplete {
                self.send(.plain(status: 400, body: "Incomplete HTTP request"), on: connection)
                return
            }

            self.receive(from: connection, buffered: requestData)
        }
    }

    private func route(_ request: HTTPRequest, on connection: NWConnection) {
        switch (request.method, request.path) {
        case ("GET", "/"), ("GET", "/index.html"):
            send(.html(status: 200, body: RealtimeVoicePage.html), on: connection)
        case ("GET", "/tools"):
            Task { [weak self] in
                let response = await self?.listToolsResponse() ?? .plain(status: 500, body: "Voice server unavailable")
                self?.send(response, on: connection)
            }
        case ("GET", "/signed-url"):
            guard let apiKey, let agentID else {
                send(.plain(status: 500, body: "ElevenLabs credentials not configured"), on: connection)
                return
            }
            Task { [weak self] in
                let response = await self?.fetchSignedURL(apiKey: apiKey, agentID: agentID) ?? .plain(status: 500, body: "Voice server unavailable")
                self?.send(response, on: connection)
            }
        case ("GET", "/api/stripe/status"):
            let response = stripeStatusResponse()
            send(response, on: connection)
        case ("POST", "/webhooks/stripe"):
            Task { @MainActor [weak self] in
                guard let self else { return }
                let response = self.stripeWebhookResponse(request: request)
                self.send(response, on: connection)
            }
        case ("POST", "/codex-spawn"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let task = (payload["task"] as? String) ?? (payload["instruction"] as? String) ?? ""
            let title = payload["title"] as? String
            // Accept cadence_minutes as int OR string OR double; default 15
            let cadenceRaw = payload["cadence_minutes"]
            let cadence: Int = (cadenceRaw as? Int)
                ?? (cadenceRaw as? Double).map(Int.init)
                ?? (cadenceRaw as? String).flatMap(Int.init)
                ?? 15
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let session = try CodexSessionManager.shared.createCompany(name: title ?? "", mission: task, cadenceMinutes: max(1, cadence))
                    self.send(HTTPResponse.jsonDict(["ok": true, "id": session.id, "title": session.title, "branch": session.branch, "cadence_minutes": session.cadenceMinutes]), on: connection)
                } catch {
                    self.send(HTTPResponse.jsonDict(["ok": false, "error": (error as NSError).localizedDescription], status: 502), on: connection)
                }
            }
        case ("GET", "/codex-list"):
            Task { @MainActor [weak self] in
                let sessions = CodexSessionManager.shared.sessions.map { s -> [String: Any] in
                    [
                        "id": s.id,
                        "title": s.title,
                        "status": s.status.rawValue,
                        "branch": s.branch,
                        "started_at": ISO8601DateFormatter().string(from: s.startedAt),
                        "exit_code": s.exitCode as Any,
                    ]
                }
                self?.send(HTTPResponse.jsonDict(["ok": true, "sessions": sessions]), on: connection)
            }
        case ("POST", "/codex-tail"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let id = (payload["id"] as? String) ?? ""
            Task { @MainActor [weak self] in
                let tail = CodexSessionManager.shared.tail(id: id, maxBytes: 4096)
                let session = CodexSessionManager.shared.session(id: id)
                self?.send(HTTPResponse.jsonDict([
                    "ok": session != nil,
                    "id": id,
                    "status": session?.status.rawValue ?? "unknown",
                    "tail": tail,
                ]), on: connection)
            }
        case ("POST", "/codex-kill"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let id = (payload["id"] as? String) ?? ""
            Task { @MainActor [weak self] in
                CodexSessionManager.shared.kill(id: id)
                self?.send(HTTPResponse.jsonDict(["ok": true, "id": id]), on: connection)
            }
        case ("POST", "/codex-intervene"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let id = (payload["id"] as? String) ?? ""
            let instruction = (payload["instruction"] as? String) ?? ""
            Task { @MainActor [weak self] in
                CodexSessionManager.shared.injectInstruction(id: id, instruction: instruction)
                self?.send(HTTPResponse.jsonDict(["ok": true, "id": id, "delivered": true]), on: connection)
            }
        case ("POST", "/codex-pause"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let id = (payload["id"] as? String) ?? ""
            Task { @MainActor [weak self] in
                CodexSessionManager.shared.pause(id: id)
                self?.send(HTTPResponse.jsonDict(["ok": true, "id": id, "paused": true]), on: connection)
            }
        // ─── WUPHF bridge: Samantha calls these; they proxy to localhost:7891 ───
        case ("POST", "/wuphf/post"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let channel = (payload["channel"] as? String) ?? "general"
            let content = (payload["content"] as? String) ?? ""
            let author = (payload["author"] as? String) ?? "samantha"
            Task { [weak self] in
                let body: [String: Any] = ["channel": channel, "author": author, "content": content]
                let response = await self?.proxyToWUPHF(method: "POST", path: "/api/messages", body: body) ?? .plain(status: 502, body: "Voice server unavailable")
                self?.send(response, on: connection)
            }
        case ("POST", "/wuphf/read"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let channel = (payload["channel"] as? String) ?? "general"
            Task { [weak self] in
                let response = await self?.proxyToWUPHF(method: "GET", path: "/api/messages?channel=\(channel)") ?? .plain(status: 502, body: "Voice server unavailable")
                self?.send(response, on: connection)
            }
        case ("GET", "/wuphf/members"), ("POST", "/wuphf/members"):
            Task { [weak self] in
                let response = await self?.proxyToWUPHF(method: "GET", path: "/api/members") ?? .plain(status: 502, body: "Voice server unavailable")
                self?.send(response, on: connection)
            }
        case ("POST", "/wuphf/wiki-search"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let query = (payload["query"] as? String) ?? ""
            let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            Task { [weak self] in
                let response = await self?.proxyToWUPHF(method: "GET", path: "/api/wiki/search?q=\(encoded)") ?? .plain(status: 502, body: "Voice server unavailable")
                self?.send(response, on: connection)
            }
        case ("POST", "/codex-resume"):
            let payload = (try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]) ?? [:]
            let id = (payload["id"] as? String) ?? ""
            Task { @MainActor [weak self] in
                CodexSessionManager.shared.resume(id: id)
                self?.send(HTTPResponse.jsonDict(["ok": true, "id": id, "resumed": true]), on: connection)
            }
        case ("POST", "/tool"):
            guard let payload = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any],
                  let name = payload["name"] as? String,
                  name.hasPrefix("orgo_") else {
                send(.plain(status: 400, body: "Expected Orgo MCP tool call JSON"), on: connection)
                return
            }

            let arguments = payload["arguments"] as? [String: Any] ?? [:]
            Task { [weak self] in
                let response: HTTPResponse
                if name == "orgo_create_computer" {
                    response = await self?.createComputerDirect(arguments: arguments) ?? .plain(status: 500, body: "Voice server unavailable")
                } else {
                    response = await self?.callToolResponse(name: name, arguments: arguments) ?? .plain(status: 500, body: "Voice server unavailable")
                }
                self?.send(response, on: connection)
            }
        default:
            send(.plain(status: 404, body: "Not found"), on: connection)
        }
    }

    /// Write an HTTP response and close the connection. Internal so endpoint
    /// extensions (Codex, WUPHF, Orgo, ElevenLabs) can use it.
    func send(_ response: HTTPResponse, on connection: NWConnection) {
        var payload = Data()
        payload.appendString("HTTP/1.1 \(response.status) \(response.reasonPhrase)\r\n")
        payload.appendString("Content-Length: \(response.body.count)\r\n")
        payload.appendString("Content-Type: \(response.contentType)\r\n")
        payload.appendString("Cache-Control: no-store\r\n")
        payload.appendString("Connection: close\r\n")
        payload.appendString("\r\n")
        payload.append(response.body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
