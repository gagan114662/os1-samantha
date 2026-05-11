import Foundation

struct CompanyBrowserSafetyPolicy: Codable, Hashable {
    enum PreferredIntegration: String, Codable, CaseIterable, Hashable {
        case api
        case connector
        case browser
    }

    var companyID: String
    var approvedDomains: [String]
    var allowedActions: [String]
    var preferredIntegrations: [String: PreferredIntegration]

    static func sandboxDefault(companyID: String) -> CompanyBrowserSafetyPolicy {
        CompanyBrowserSafetyPolicy(
            companyID: companyID,
            approvedDomains: [],
            allowedActions: [],
            preferredIntegrations: [:]
        )
    }

    func allows(domain: String, action: String) -> Bool {
        approvedDomains.map(Self.normalizeDomain).contains(Self.normalizeDomain(domain))
            && allowedActions.map(Self.normalizeAction).contains(Self.normalizeAction(action))
    }

    func preferredIntegration(for domain: String) -> PreferredIntegration {
        let normalized = Self.normalizeDomain(domain)
        if let configured = preferredIntegrations[normalized] {
            return configured
        }
        if Self.apiFirstDomains.contains(normalized) {
            return .api
        }
        return .browser
    }

    static func requiresStealth(for domain: String) -> Bool {
        consumerPlatformDomains.contains(normalizeDomain(domain))
    }

    static func normalizeDomain(_ domain: String) -> String {
        let trimmed = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        return trimmed.split(separator: "/").first.map(String.init) ?? trimmed
    }

    static func normalizeAction(_ action: String) -> String {
        action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static let apiFirstDomains: Set<String> = [
        "api.linkedin.com",
        "api.twitter.com",
        "api.github.com",
        "graph.facebook.com",
        "github.com",
        "gmail.com",
        "googleapis.com",
        "linkedin.com",
        "oauth.reddit.com",
        "open.tiktokapis.com",
        "reddit.com",
        "slack.com",
        "stripe.com",
        "shopify.com",
        "twitter.com",
        "x.com",
        "youtube.com",
        "youtubei.googleapis.com",
        "youtube.googleapis.com"
    ]

    private static let consumerPlatformDomains: Set<String> = [
        "x.com",
        "twitter.com",
        "instagram.com",
        "tiktok.com",
        "linkedin.com",
        "pinterest.com",
        "reddit.com"
    ]
}

struct CompanyBrowserStealthProfile: Codable, Hashable {
    enum HumanPaceProfile: String, Codable, CaseIterable, Hashable {
        case fast
        case normal
        case deliberate

        var delayRangeSeconds: ClosedRange<Double> {
            switch self {
            case .fast: return 0.7...1.8
            case .normal: return 1.8...4.5
            case .deliberate: return 4.0...9.0
            }
        }
    }

    enum CaptchaHandoff: String, Codable, CaseIterable, Hashable {
        case abortAndAskOperator
        case manualAnnotate
    }

    var companyID: String
    var userAgentPool: [String]
    var proxyEndpoint: URL?
    var humanPaceProfile: HumanPaceProfile
    var cookieJarPath: URL
    var captchaHandoff: CaptchaHandoff

    func userAgent(forSessionOrdinal ordinal: Int) -> String {
        guard !userAgentPool.isEmpty else {
            return "Mozilla/5.0 (Macintosh; Intel Mac OS X 14_6) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.5 Safari/605.1.15"
        }
        let index = abs(ordinal) % userAgentPool.count
        return userAgentPool[index]
    }
}

struct CompanyBrowserAction: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case readPublicPage
        case fillOwnedForm
        case submitOwnedForm
        case downloadReport
        case publishDraft
        case unknown
    }

    let id: String
    var companyID: String
    var domain: String
    var kind: Kind
    var actionName: String
    var semanticTarget: String
    var selector: String?
    var expectedResult: String
}

struct CompanyBrowserActionPlan: Codable, Hashable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case ready
        case preferAPI
        case blocked
    }

    var status: Status
    var action: CompanyBrowserAction
    var preferredIntegration: CompanyBrowserSafetyPolicy.PreferredIntegration
    var blockers: [String]
    var traceRequirement: CompanyBrowserTraceRequirement
    var recovery: CompanyBrowserRecovery
    var stealthProfileRequired: Bool
    var selectedUserAgent: String?

    var canExecuteWithBrowser: Bool {
        status == .ready && blockers.isEmpty
    }
}

struct CompanyBrowserTraceRequirement: Codable, Hashable {
    var requireScreenshot: Bool
    var requireDOMSnapshot: Bool
    var requireSelectorOrSemanticTarget: Bool

    static let replayable = CompanyBrowserTraceRequirement(
        requireScreenshot: true,
        requireDOMSnapshot: true,
        requireSelectorOrSemanticTarget: true
    )
}

struct CompanyBrowserTrace: Codable, Hashable, Identifiable {
    enum Outcome: String, Codable, CaseIterable, Hashable {
        case succeeded
        case failed
        case blocked
    }

    let id: String
    var companyID: String
    var sessionID: String
    var domain: String
    var actionName: String
    var semanticTarget: String
    var selector: String?
    var screenshotPath: String?
    var domSnapshotPath: String?
    var outcome: Outcome
    var failureKind: CompanyBrowserFailureKind?
    var recovery: CompanyBrowserRecovery
    var occurredAt: Date

    var isReplayable: Bool {
        selector?.isEmpty == false
            && semanticTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            && screenshotPath?.isEmpty == false
            && domSnapshotPath?.isEmpty == false
    }
}

enum CompanyBrowserFailureKind: String, Codable, CaseIterable, Hashable {
    case loginExpired
    case captcha
    case rateLimit
    case popup
    case layoutChanged
    case selectorMissing
    case domainDenied
    case actionDenied
    case unknown
}

struct CompanyBrowserRecovery: Codable, Hashable {
    enum Decision: String, Codable, CaseIterable, Hashable {
        case retry
        case refreshAndRetry
        case closePopupAndRetry
        case blockedNeedsHuman
        case blockedPolicy
    }

    var decision: Decision
    var reason: String
    var nextAction: String
    var requiresHuman: Bool
}

enum CompanyBrowserAutomationEngine {
    static func plan(
        action: CompanyBrowserAction,
        policy: CompanyBrowserSafetyPolicy,
        stealthProfile: CompanyBrowserStealthProfile? = nil,
        sessionOrdinal: Int = 0
    ) -> CompanyBrowserActionPlan {
        var blockers: [String] = []
        if !policy.approvedDomains.map(CompanyBrowserSafetyPolicy.normalizeDomain).contains(CompanyBrowserSafetyPolicy.normalizeDomain(action.domain)) {
            blockers.append("Domain \(action.domain) is not approved for company \(action.companyID).")
        }
        if !policy.allowedActions.map(CompanyBrowserSafetyPolicy.normalizeAction).contains(CompanyBrowserSafetyPolicy.normalizeAction(action.actionName)) {
            blockers.append("Action \(action.actionName) is not allowed by the company browser policy.")
        }
        if (action.selector?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && action.semanticTarget.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            blockers.append("Browser action needs a selector or semantic element target.")
        }
        let normalizedDomain = CompanyBrowserSafetyPolicy.normalizeDomain(action.domain)
        let stealthRequired = CompanyBrowserSafetyPolicy.requiresStealth(for: normalizedDomain)
        if stealthRequired, stealthProfile == nil {
            blockers.append("stealth profile required")
        }

        let preferred = policy.preferredIntegration(for: action.domain)
        let status: CompanyBrowserActionPlan.Status
        if !blockers.isEmpty {
            status = .blocked
        } else if preferred != .browser {
            status = .preferAPI
        } else {
            status = .ready
        }

        return CompanyBrowserActionPlan(
            status: status,
            action: action,
            preferredIntegration: preferred,
            blockers: blockers,
            traceRequirement: .replayable,
            recovery: status == .blocked ? recovery(for: .domainDenied) : recovery(for: .unknown),
            stealthProfileRequired: stealthRequired,
            selectedUserAgent: stealthProfile?.userAgent(forSessionOrdinal: sessionOrdinal)
        )
    }

    static func trace(
        action: CompanyBrowserAction,
        sessionID: String,
        outcome: CompanyBrowserTrace.Outcome,
        screenshotPath: String?,
        domSnapshotPath: String?,
        failureKind: CompanyBrowserFailureKind? = nil,
        occurredAt: Date = Date()
    ) -> CompanyBrowserTrace {
        CompanyBrowserTrace(
            id: "\(sessionID)-\(action.id)",
            companyID: action.companyID,
            sessionID: sessionID,
            domain: CompanyBrowserSafetyPolicy.normalizeDomain(action.domain),
            actionName: action.actionName,
            semanticTarget: action.semanticTarget,
            selector: action.selector,
            screenshotPath: screenshotPath,
            domSnapshotPath: domSnapshotPath,
            outcome: outcome,
            failureKind: failureKind,
            recovery: recovery(for: failureKind ?? (outcome == .blocked ? .domainDenied : .unknown)),
            occurredAt: occurredAt
        )
    }

    static func recovery(for failure: CompanyBrowserFailureKind) -> CompanyBrowserRecovery {
        switch failure {
        case .loginExpired:
            return .init(decision: .blockedNeedsHuman, reason: "Login expired", nextAction: "Ask operator to refresh the login, then retry from the saved trace.", requiresHuman: true)
        case .captcha:
            return .init(decision: .blockedNeedsHuman, reason: "Captcha or bot challenge detected", nextAction: "Stop automation and request human completion.", requiresHuman: true)
        case .rateLimit:
            return .init(decision: .retry, reason: "Rate limit detected", nextAction: "Back off before retrying the same selector.", requiresHuman: false)
        case .popup:
            return .init(decision: .closePopupAndRetry, reason: "Blocking popup detected", nextAction: "Close known popup, capture a new screenshot, and retry once.", requiresHuman: false)
        case .layoutChanged, .selectorMissing:
            return .init(decision: .refreshAndRetry, reason: "Selector or layout changed", nextAction: "Refresh DOM snapshot and find a semantic replacement selector.", requiresHuman: false)
        case .domainDenied, .actionDenied:
            return .init(decision: .blockedPolicy, reason: "Browser policy denied the action", nextAction: "Request a policy update or use an approved API/connector.", requiresHuman: true)
        case .unknown:
            return .init(decision: .blockedNeedsHuman, reason: "Unknown browser failure", nextAction: "Attach screenshot and DOM context before asking for review.", requiresHuman: true)
        }
    }

    static func captchaHandoff(
        trace: CompanyBrowserTrace,
        approvalsDirectory: URL,
        now: Date = Date()
    ) throws -> (approvalFile: URL, event: CompanyEvent) {
        try FileManager.default.createDirectory(at: approvalsDirectory, withIntermediateDirectories: true)
        let approvalFile = approvalsDirectory.appendingPathComponent("captcha-\(trace.sessionID).json")
        let payload = CaptchaApprovalRequest(
            id: "captcha-\(trace.sessionID)",
            companyID: trace.companyID,
            sessionID: trace.sessionID,
            domain: trace.domain,
            screenshotPath: trace.screenshotPath,
            domSnapshotPath: trace.domSnapshotPath,
            createdAt: now,
            status: "paused"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: approvalFile, options: .atomic)
        let event = CompanyEvent(
            occurredAt: now,
            companyID: trace.companyID,
            kind: .companyPaused,
            summary: "Company paused for captcha handoff on \(trace.domain)",
            tool: "browser-automation",
            approvalState: "captcha-handoff",
            metadata: [
                "sessionID": trace.sessionID,
                "domain": trace.domain,
                "approvalFile": approvalFile.path
            ]
        )
        return (approvalFile, event)
    }
}

struct CaptchaApprovalRequest: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var sessionID: String
    var domain: String
    var screenshotPath: String?
    var domSnapshotPath: String?
    var createdAt: Date
    var status: String
}
