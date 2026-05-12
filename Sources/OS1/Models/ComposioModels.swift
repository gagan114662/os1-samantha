import Foundation

// MARK: - Toolkits (canonical curated list)

/// One of Composio's supported apps. We don't fetch the full catalog
/// from MCP — instead we ship a small curated list with display
/// metadata, then ask Composio for connection status per slug. Power
/// users can browse the full catalog via dashboard.composio.dev.
struct ComposioToolkitMeta: Equatable, Identifiable {
    enum Tag: String, Codable, CaseIterable, Hashable {
        case productivity
        case social
        case marketing
        case video
        case community
        case crm
    }

    enum RiskTier: String, Codable, CaseIterable, Hashable {
        case low
        case medium
        case high
    }

    let slug: String
    let name: String
    let description: String?
    let tag: Tag
    let riskTier: RiskTier
    let requiredScopes: [String]

    var id: String { slug }

    func requiresEarlyApproval(cleanHistoryDays: Int) -> Bool {
        guard cleanHistoryDays < 7 else { return false }
        switch tag {
        case .social, .video, .marketing, .community:
            return true
        case .productivity, .crm:
            return riskTier == .high
        }
    }

    init(
        slug: String,
        name: String,
        description: String?,
        tag: Tag = .productivity,
        riskTier: RiskTier = .medium,
        requiredScopes: [String] = []
    ) {
        self.slug = slug
        self.name = name
        self.description = description
        self.tag = tag
        self.riskTier = riskTier
        self.requiredScopes = requiredScopes
    }
}

// MARK: - MANAGE_CONNECTIONS response shape

/// Composio's MCP tool-call results are JSON-stringified into a single
/// MCP text block. The JSON payload may be wrapped in an envelope
/// (`{ data: { ... }, error: null, log_id: "..." }`) OR be flat (the
/// data fields directly). `ComposioMCPEnvelope` handles both — try
/// envelope first, fall back to flat.
struct ComposioManageConnectionsPayload: Decodable {
    let message: String?
    let results: [String: ComposioToolkitConnectionResult]?
    let summary: ComposioConnectionsSummary?
}

struct ComposioToolkitConnectionResult: Decodable {
    let toolkit: String?
    let status: String?
    let accounts: [ComposioConnectedAccountSummary]?

    /// True if the toolkit has at least one ACTIVE connection.
    var hasActiveAccount: Bool {
        accounts?.contains(where: { $0.status?.lowercased() == "active" }) ?? false
    }

    var activeAccountCount: Int {
        accounts?.filter { $0.status?.lowercased() == "active" }.count ?? 0
    }
}

struct ComposioConnectedAccountSummary: Decodable, Equatable, Identifiable {
    let id: String
    let alias: String?
    let status: String?
    let is_default: Bool?
}

struct ComposioConnectionsSummary: Decodable {
    let total_toolkits: Int?
    let active_connections: Int?
    let initiated_connections: Int?
    let failed_connections: Int?
}

// MARK: - Initiate / wait connection

struct ComposioInitiateConnectionPayload: Decodable {
    let toolkit: String?
    let connected_account_id: String?
    let redirect_url: String?
    let auth_link: String?

    var resolvedRedirectURL: URL? {
        let raw = redirect_url ?? auth_link
        return raw.flatMap { URL(string: $0) }
    }
}

// MARK: - Generic envelope

/// Decoder that tolerates two response shapes from Composio MCP tools:
/// either the payload is at the top level, or wrapped in `{ data: ... }`.
/// Try both.
struct ComposioMCPEnvelope<Payload: Decodable>: Decodable {
    let payload: Payload

    init(from decoder: Decoder) throws {
        // Try envelope first.
        if let outer = try? decoder.container(keyedBy: EnvelopeKeys.self),
           let nested = try? outer.decode(Payload.self, forKey: .data) {
            self.payload = nested
            return
        }
        // Fall back to flat.
        self.payload = try Payload(from: decoder)
    }

    private enum EnvelopeKeys: String, CodingKey { case data }
}
