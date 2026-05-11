import Foundation

/// Endpoints that bridge Samantha's `orgo_*` tool calls into either the
/// Orgo MCP runtime (default, multi-tool) or directly into the Orgo
/// platform API (special-cased for tools where MCP is broken, e.g.
/// `orgo_create_computer` whose name→workspace_id resolution is buggy
/// in the bundled MCP version).
extension RealtimeVoiceSessionServer {

    /// `GET /tools` — list MCP tools available to the realtime agent.
    func listToolsResponse() async -> HTTPResponse {
        guard orgoMCPBridge.isConfigured else {
            return .json(RealtimeToolsResponse(
                tools: [],
                orgo: RealtimeOrgoStatus(enabled: false, status: "Orgo MCP unavailable: missing API key or Node runtime")
            ))
        }
        do {
            let tools = try await orgoMCPBridge.listRealtimeTools()
            return .json(RealtimeToolsResponse(
                tools: tools,
                orgo: RealtimeOrgoStatus(enabled: true, status: "Orgo MCP ready: \(tools.count) tools")
            ))
        } catch {
            return .json(
                RealtimeToolsResponse(
                    tools: [],
                    orgo: RealtimeOrgoStatus(enabled: false, status: error.localizedDescription)
                ),
                status: 502
            )
        }
    }

    /// `POST /tool` — generic orgo_* tool invocation. Falls back to direct
    /// platform-API call when the tool is `orgo_create_computer`.
    func callToolResponse(name: String, arguments: [String: Any]) async -> HTTPResponse {
        do {
            let result = try await orgoMCPBridge.callTool(name: name, arguments: arguments)
            return .json(result)
        } catch {
            return .json(
                RealtimeOrgoMCPCallResult(
                    isError: true,
                    content: AnyEncodable([["type": "text", "text": error.localizedDescription]])
                ),
                status: 502
            )
        }
    }

    /// Bypass for `orgo_create_computer`: the MCP version doesn't resolve
    /// workspace-name → workspace-id, so platform 4xx's even on valid args.
    /// We call `POST /api/computers` directly with plan-tier-safe defaults.
    func createComputerDirect(arguments: [String: Any]) async -> HTTPResponse {
        guard let apiKey = ProcessInfo.processInfo.environment["ORGO_API_KEY"]
            ?? KeychainSecret.read(service: "ai.orgo.mac.api-key"),
              !apiKey.isEmpty else {
            return .json(
                RealtimeOrgoMCPCallResult(isError: true, content: AnyEncodable([["type": "text", "text": "ORGO_API_KEY not set"]])),
                status: 500
            )
        }

        var workspaceID = (arguments["workspace_id"] as? String) ?? ""
        if workspaceID.isEmpty {
            let workspaceName = (arguments["workspace"] as? String) ?? ""
            if let resolved = await resolveWorkspaceID(name: workspaceName, apiKey: apiKey) {
                workspaceID = resolved
            }
        }
        if workspaceID.isEmpty {
            return .json(
                RealtimeOrgoMCPCallResult(isError: true, content: AnyEncodable([["type": "text", "text": "Could not resolve workspace; pass workspace_id or workspace name."]])),
                status: 400
            )
        }

        let suggestedName = (arguments["name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? "samantha-\(Int(Date().timeIntervalSince1970) % 100000)"
        let ram = Self.parseInt(arguments["ram"]) ?? 4
        let cpu = Self.parseInt(arguments["cpu"]) ?? 1
        let disk = Self.parseInt(arguments["disk_size_gb"]) ?? 20

        let body: [String: Any] = [
            "workspace_id": workspaceID,
            "name": suggestedName,
            "os": "linux",
            "ram": ram,
            "cpu": cpu,
            "gpu": (arguments["gpu"] as? String) ?? "none",
            "disk_size_gb": disk,
            "resolution": (arguments["resolution"] as? String) ?? "1280x720x24",
        ]

        guard let url = URL(string: "https://www.orgo.ai/api/computers") else {
            return .json(RealtimeOrgoMCPCallResult(isError: true, content: AnyEncodable([["type": "text", "text": "bad URL"]])), status: 500)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 502
            let bodyString = String(data: data, encoding: .utf8) ?? ""
            if (200..<300).contains(status) {
                return .json(RealtimeOrgoMCPCallResult(
                    isError: false,
                    content: AnyEncodable([["type": "text", "text": "Created computer. " + bodyString.prefix(400).description]])
                ), status: 200)
            }
            return .json(
                RealtimeOrgoMCPCallResult(
                    isError: true,
                    content: AnyEncodable([["type": "text", "text": "Orgo API \(status): \(bodyString.prefix(400))"]])
                ),
                status: status
            )
        } catch {
            return .json(
                RealtimeOrgoMCPCallResult(isError: true, content: AnyEncodable([["type": "text", "text": error.localizedDescription]])),
                status: 502
            )
        }
    }

    /// Best-effort workspace name → UUID lookup against `/api/projects`.
    /// Falls back to "the only workspace" if there's just one, regardless of name.
    func resolveWorkspaceID(name: String, apiKey: String) async -> String? {
        guard let url = URL(string: "https://www.orgo.ai/api/projects") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let projects = json["projects"] as? [[String: Any]] else { return nil }

        if projects.count == 1 {
            return projects[0]["id"] as? String
        }
        let target = name.lowercased()
        for project in projects {
            if let projectName = project["name"] as? String, projectName.lowercased() == target {
                return project["id"] as? String
            }
        }
        for project in projects {
            if let projectName = project["name"] as? String,
               !target.isEmpty,
               projectName.lowercased().contains(target) || target.contains(projectName.lowercased()) {
                return project["id"] as? String
            }
        }
        return nil
    }

    /// Lenient int coercion — accepts Int, Double, or numeric String.
    /// Used because the JS tool-arg pipeline can deliver either form
    /// depending on the LLM's quirks.
    static func parseInt(_ value: Any?) -> Int? {
        if let i = value as? Int { return i }
        if let s = value as? String { return Int(s) }
        if let d = value as? Double { return Int(d) }
        return nil
    }
}
