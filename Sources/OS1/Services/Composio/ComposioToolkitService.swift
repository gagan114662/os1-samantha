import Foundation

/// High-level Composio operations the Connectors UI needs, backed by
/// the MCP server at `connect.composio.dev/mcp`. The same server, the
/// same key, the same protocol the agent on the VM uses — so users
/// only ever have to manage one credential.
struct ComposioToolkitService: Sendable {
    let mcp: ComposioMCPClient

    init(mcp: ComposioMCPClient) {
        self.mcp = mcp
    }

    // MARK: - Curated toolkit list
    //
    // Composio supports 1,000+ apps. We surface a small popular subset
    // up-front; everything else stays accessible through the agent's
    // own meta-tools when it needs them. Slugs match Composio's
    // canonical names (note `agent_mail` with an underscore).

    static let curatedToolkits: [ComposioToolkitMeta] = [
        .init(slug: "agent_mail",     name: "AgentMail",       description: "Per-agent email inboxes with full send/receive.", tag: .productivity, riskTier: .medium, requiredScopes: ["email:send", "email:read"]),
        .init(slug: "gmail",          name: "Gmail",            description: "Send, read, label, and search Gmail.", tag: .productivity, riskTier: .medium, requiredScopes: ["gmail.send", "gmail.readonly"]),
        .init(slug: "slack",          name: "Slack",            description: "Post messages, manage channels, search history.", tag: .community, riskTier: .medium, requiredScopes: ["chat:write", "channels:read"]),
        .init(slug: "notion",         name: "Notion",           description: "Pages, databases, and rich-text content.", tag: .productivity, riskTier: .low, requiredScopes: ["read_content", "insert_content"]),
        .init(slug: "linear",         name: "Linear",           description: "Issues, projects, and team workflows.", tag: .productivity, riskTier: .low, requiredScopes: ["read", "write"]),
        .init(slug: "github",         name: "GitHub",           description: "Repos, PRs, issues, code search.", tag: .productivity, riskTier: .medium, requiredScopes: ["repo", "issues:write"]),
        .init(slug: "googlecalendar", name: "Google Calendar",  description: "Events, scheduling, availability.", tag: .productivity, riskTier: .medium, requiredScopes: ["calendar.events"]),
        .init(slug: "googledrive",    name: "Google Drive",     description: "Files, folders, and document operations.", tag: .productivity, riskTier: .medium, requiredScopes: ["drive.file"]),
        .init(slug: "twitter",        name: "X / Twitter",      description: "Publish posts, threads, replies, and read account activity.", tag: .social, riskTier: .high, requiredScopes: ["tweet.read", "tweet.write", "users.read"]),
        .init(slug: "linkedin",       name: "LinkedIn",         description: "Publish company or member posts and manage B2B outreach workflows.", tag: .social, riskTier: .high, requiredScopes: ["w_member_social", "r_liteprofile"]),
        .init(slug: "instagram",      name: "Instagram",        description: "Publish media and read Meta Graph account insights.", tag: .social, riskTier: .high, requiredScopes: ["instagram_basic", "instagram_content_publish"]),
        .init(slug: "tiktok",         name: "TikTok",           description: "Upload and schedule TikTok creator or business content.", tag: .video, riskTier: .high, requiredScopes: ["video.upload", "user.info.basic"]),
        .init(slug: "youtube",        name: "YouTube",          description: "Upload videos, manage metadata, and read channel analytics.", tag: .video, riskTier: .high, requiredScopes: ["youtube.upload", "youtube.readonly"]),
        .init(slug: "reddit",         name: "Reddit",           description: "Submit posts, comment, and read subreddit context.", tag: .community, riskTier: .high, requiredScopes: ["submit", "read", "identity"]),
        .init(slug: "pinterest",      name: "Pinterest",        description: "Create pins and boards with destination links.", tag: .marketing, riskTier: .high, requiredScopes: ["pins:write", "boards:read"]),
        .init(slug: "discord",        name: "Discord",          description: "Manage community messages and channel workflows.", tag: .community, riskTier: .high, requiredScopes: ["bot", "messages.write"]),
        .init(slug: "telegram",       name: "Telegram",         description: "Send bot messages and manage community notifications.", tag: .community, riskTier: .high, requiredScopes: ["bot:send_message"]),
        .init(slug: "threads",        name: "Threads",          description: "Publish Threads posts when the API account is available.", tag: .social, riskTier: .high, requiredScopes: ["threads_basic", "threads_content_publish"]),
        .init(slug: "substack",       name: "Substack",         description: "Manage newsletter publishing where account capabilities allow it.", tag: .marketing, riskTier: .medium, requiredScopes: ["publication:write"]),
        .init(slug: "hubspot",        name: "HubSpot",          description: "Sync contacts, deals, and sales activities.", tag: .crm, riskTier: .medium, requiredScopes: ["crm.objects.contacts.read", "crm.objects.contacts.write", "crm.objects.deals.write"]),
        .init(slug: "pipedrive",      name: "Pipedrive",        description: "Sync people, organizations, deals, and activities.", tag: .crm, riskTier: .medium, requiredScopes: ["deals:read", "deals:write", "contacts:write"]),
        .init(slug: "salesforce",     name: "Salesforce",       description: "Sync leads, accounts, contacts, opportunities, and activities.", tag: .crm, riskTier: .high, requiredScopes: ["api", "refresh_token"]),
        .init(slug: "close",          name: "Close",            description: "Manage leads, contacts, opportunities, and tasks.", tag: .crm, riskTier: .medium, requiredScopes: ["leads:read", "leads:write"]),
        .init(slug: "attio",          name: "Attio",            description: "Sync modern CRM records, lists, and notes.", tag: .crm, riskTier: .medium, requiredScopes: ["record_permission:read-write"]),
        .init(slug: "folk",           name: "Folk",             description: "Sync contacts, companies, and relationship notes.", tag: .crm, riskTier: .medium, requiredScopes: ["contacts:read", "contacts:write"]),
        .init(slug: "salesflare",     name: "Salesflare",       description: "Sync contacts, opportunities, and automated activity timelines.", tag: .crm, riskTier: .medium, requiredScopes: ["contacts", "opportunities"]),
    ]

    // MARK: - Tool wrappers

    /// Lists all connected accounts across the curated toolkit set in
    /// a single batched call. Composio's MANAGE_CONNECTIONS handles
    /// multiple toolkits per request, returning per-toolkit status +
    /// per-account details.
    func listConnections(slugs: [String] = curatedToolkits.map(\.slug)) async throws -> ComposioManageConnectionsPayload {
        struct Args: Encodable {
            let toolkits: [Operation]
            struct Operation: Encodable {
                let name: String
                let action: String
            }
        }
        let args = Args(toolkits: slugs.map { Args.Operation(name: $0, action: "list") })
        let envelope: ComposioMCPEnvelope<ComposioManageConnectionsPayload> = try await mcp.callTool(
            name: "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: args,
            responseType: ComposioMCPEnvelope<ComposioManageConnectionsPayload>.self
        )
        return envelope.payload
    }

    /// Initiates an OAuth flow for one toolkit. The response includes a
    /// redirect URL that OS1 opens in the browser; the user authorizes,
    /// and the next refresh of `listConnections` reflects the new
    /// active account. Optional alias becomes the human-readable label
    /// (e.g. "personal", "work").
    func initiateConnection(slug: String, alias: String? = nil) async throws -> ComposioInitiateConnectionPayload {
        struct Args: Encodable {
            let toolkits: [Operation]
            struct Operation: Encodable {
                let name: String
                let action: String
                let alias: String?
            }
        }
        let args = Args(toolkits: [Args.Operation(name: slug, action: "add", alias: alias)])
        let envelope: ComposioMCPEnvelope<ComposioInitiatePayloadWrapper> = try await mcp.callTool(
            name: "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: args,
            responseType: ComposioMCPEnvelope<ComposioInitiatePayloadWrapper>.self
        )
        // The "add" response shape mirrors `list` but with one toolkit
        // and a redirect URL embedded somewhere on the account or at
        // the toolkit level. We unwrap defensively.
        if let toolkitResult = envelope.payload.results?[slug] ?? envelope.payload.results?.values.first {
            return ComposioInitiateConnectionPayload(
                toolkit: toolkitResult.toolkit ?? slug,
                connected_account_id: toolkitResult.accounts?.first?.id,
                redirect_url: toolkitResult.redirect_url,
                auth_link: toolkitResult.auth_link
            )
        }
        return ComposioInitiateConnectionPayload(toolkit: slug, connected_account_id: nil, redirect_url: nil, auth_link: nil)
    }

    /// Removes a connected account by id.
    func removeConnection(slug: String, accountId: String) async throws {
        struct Args: Encodable {
            let toolkits: [Operation]
            struct Operation: Encodable {
                let name: String
                let action: String
                let account_id: String
            }
        }
        let args = Args(toolkits: [Args.Operation(name: slug, action: "remove", account_id: accountId)])
        let _: ComposioMCPEnvelope<ComposioGenericPayload> = try await mcp.callTool(
            name: "COMPOSIO_MANAGE_CONNECTIONS",
            arguments: args,
            responseType: ComposioMCPEnvelope<ComposioGenericPayload>.self
        )
    }

    /// Polls until the freshly-initiated connection becomes ACTIVE or
    /// the timeout elapses. Used right after `initiateConnection` once
    /// the user is in the browser.
    func waitForActiveConnection(
        slug: String,
        accountId: String?,
        timeoutSeconds: TimeInterval = 300
    ) async throws -> ComposioConnectedAccountSummary {
        let deadline = Date().addingTimeInterval(timeoutSeconds)
        var pollIntervalNS: UInt64 = 2_000_000_000
        while Date() < deadline {
            try Task.checkCancellation()
            let payload = try await listConnections(slugs: [slug])
            if let toolkitResult = payload.results?[slug] {
                if let target = toolkitResult.accounts?.first(where: { acct in
                    if let accountId { return acct.id == accountId }
                    return acct.status?.lowercased() == "active"
                }), target.status?.lowercased() == "active" {
                    return target
                }
            }
            try await Task.sleep(nanoseconds: pollIntervalNS)
            pollIntervalNS = min(pollIntervalNS + 500_000_000, 5_000_000_000)
        }
        throw ComposioMCPError.transport("Timed out waiting for OAuth completion.")
    }
}

// MARK: - Internal payload helpers

/// `add`-action variant of the per-toolkit result that also includes
/// the redirect URL Composio returns alongside the new connection
/// record.
private struct ComposioInitiatePayloadWrapper: Decodable {
    let message: String?
    let results: [String: AddedToolkitResult]?
    let summary: ComposioConnectionsSummary?

    struct AddedToolkitResult: Decodable {
        let toolkit: String?
        let status: String?
        let accounts: [ComposioConnectedAccountSummary]?
        let redirect_url: String?
        let auth_link: String?
    }
}

/// Used when we don't care about the response shape (e.g. `remove`).
private struct ComposioGenericPayload: Decodable {
    let message: String?
}
