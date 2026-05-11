import Foundation

/// Reads the user's Orgo workspaces and computers, and creates new computers.
/// Uses the platform API (auth via the global Orgo API key, sourced through
/// the HTTP client's apiKeyProvider closure).
final class OrgoCatalogService: @unchecked Sendable {
    private let httpClient: OrgoHTTPClient

    init(httpClient: OrgoHTTPClient) {
        self.httpClient = httpClient
    }

    /// Returns every workspace the API key has access to, with computers
    /// nested under each. The platform's `/projects` endpoint returns
    /// everything in one round-trip, so the editor doesn't need a separate
    /// list-computers call.
    func listWorkspaces() async throws -> [OrgoWorkspaceSummary] {
        let response: ProjectsListResponse = try await httpClient.get(path: "projects")
        return response.projects.map { project in
            OrgoWorkspaceSummary(
                id: project.id,
                name: project.name,
                computers: (project.desktops ?? []).map {
                    OrgoComputerSummary(
                        id: $0.id,
                        name: ($0.name?.isEmpty == false) ? ($0.name ?? "") : "Untitled",
                        status: $0.status ?? "unknown"
                    )
                }
            )
        }
    }

    /// Creates a new computer in the named workspace. Returns the new
    /// computer's id/name/status. Other specs use sensible defaults; the
    /// inline editor doesn't need to expose the full /computers POST surface
    /// in v1 — power users can use the Orgo dashboard for custom specs.
    func createComputer(workspaceID: String, computerName: String) async throws -> OrgoComputerSummary {
        // 4GB/1CPU/20GB fits the free tier — power users on team/enterprise plans
        // can resize via the Orgo dashboard or use the inline editor's size picker.
        let body = CreateComputerRequest(
            workspace_id: workspaceID,
            name: computerName,
            os: "linux",
            ram: 4,
            cpu: 1,
            gpu: "none",
            disk_size_gb: 20,
            resolution: "1280x720x24"
        )

        let response: CreateComputerResponse = try await httpClient.post(
            path: "computers",
            body: body,
            timeout: 90
        )

        return OrgoComputerSummary(
            id: response.id,
            name: response.name?.isEmpty == false ? (response.name ?? computerName) : computerName,
            status: response.status ?? "creating"
        )
    }
}

// MARK: - Wire formats

private struct ProjectsListResponse: Decodable {
    let projects: [Project]

    struct Project: Decodable {
        let id: String
        let name: String
        let desktops: [Desktop]?
    }

    struct Desktop: Decodable {
        let id: String
        let name: String?
        let status: String?
    }
}

private struct CreateComputerRequest: Encodable {
    let workspace_id: String
    let name: String
    let os: String
    let ram: Int
    let cpu: Int
    let gpu: String
    let disk_size_gb: Int
    let resolution: String
}

private struct CreateComputerResponse: Decodable {
    let id: String
    let name: String?
    let status: String?
}
