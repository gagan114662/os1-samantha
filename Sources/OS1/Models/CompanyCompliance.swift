import Foundation

enum CompanyComplianceChannel: String, Codable, CaseIterable, Hashable {
    case email
    case socialPlatform
    case marketplace
    case browserAutomation
    case payments
    case dataCollection
    case scraping
    case publicContent
    case unknown
}

struct CompanyComplianceMetadata: Codable, Hashable {
    var legalBasis: String?
    var unsubscribePath: String?
    var disclosureText: String?
    var targetAudience: String?
    var contactSource: String?
    var dataRetentionPolicy: String?

    var hasRequiredOutboundFields: Bool {
        hasValue(legalBasis)
            && hasValue(unsubscribePath)
            && hasValue(disclosureText)
            && hasValue(targetAudience)
            && hasValue(contactSource)
            && hasValue(dataRetentionPolicy)
    }

    var hasPrivacyFields: Bool {
        hasValue(legalBasis) && hasValue(dataRetentionPolicy) && hasValue(targetAudience)
    }

    private func hasValue(_ value: String?) -> Bool {
        guard let value else { return false }
        return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CompanyBrowserAutomationPolicy: Codable, Hashable {
    var allowedDomains: [String]
    var allowedActions: [String]

    static let empty = CompanyBrowserAutomationPolicy(allowedDomains: [], allowedActions: [])

    func allows(domain: String?, action: String?) -> Bool {
        guard let domain, let action else { return false }
        let normalizedDomain = Self.normalizeDomain(domain)
        let normalizedAction = action.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allowedDomains.map(Self.normalizeDomain).contains(normalizedDomain)
            && allowedActions.map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }.contains(normalizedAction)
    }

    private static func normalizeDomain(_ domain: String) -> String {
        let trimmed = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        return trimmed.split(separator: "/").first.map(String.init) ?? trimmed
    }
}

struct CompanyComplianceAction: Codable, Hashable {
    var companyID: String
    var channel: CompanyComplianceChannel
    var proposedAction: String
    var content: String
    var metadata: CompanyComplianceMetadata?
    var browserPolicy: CompanyBrowserAutomationPolicy?
    var targetDomain: String?
    var browserAction: String?
    var requestedCredential: String?
}

struct CompanyComplianceFinding: Codable, Hashable, Identifiable {
    enum Severity: String, Codable, CaseIterable, Hashable {
        case warning
        case blocked
        case humanReviewRequired
    }

    let id: String
    var severity: Severity
    var message: String
    var fix: String
}

struct CompanyComplianceDecision: Codable, Hashable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case approved
        case blocked
        case humanReviewRequired
    }

    var status: Status
    var findings: [CompanyComplianceFinding]

    var canRun: Bool {
        status == .approved
    }

    var fixes: [String] {
        findings.map(\.fix)
    }

    static let approved = CompanyComplianceDecision(status: .approved, findings: [])
}

enum CompanyComplianceEngine {
    static func evaluate(
        action: CompanyComplianceAction,
        allowedCredentialNames: [String] = []
    ) -> CompanyComplianceDecision {
        let normalized = "\(action.proposedAction) \(action.content)".lowercased()
        let metadata = action.metadata
        var findings: [CompanyComplianceFinding] = []

        if requiresOutboundMetadata(action.channel), metadata?.hasRequiredOutboundFields != true {
            findings.append(.blocked(
                "missing-outbound-metadata",
                "Outbound campaigns need legal basis, unsubscribe, disclosure, audience, contact source, and retention metadata.",
                "Add complete complianceMetadata before sending, posting, or publishing."
            ))
        }

        if action.channel == .browserAutomation {
            if action.browserPolicy?.allowedDomains.isEmpty != false || action.browserPolicy?.allowedActions.isEmpty != false {
                findings.append(.blocked(
                    "missing-browser-policy",
                    "Browser automation has no explicit allowed domains/actions.",
                    "Add browserAutomationPolicy.allowedDomains and allowedActions for this company."
                ))
            } else if action.browserPolicy?.allows(domain: action.targetDomain, action: action.browserAction) != true {
                findings.append(.blocked(
                    "browser-policy-denied",
                    "Browser automation target is outside the approved policy.",
                    "Limit automation to an allowed domain/action or request a policy update."
                ))
            }
        }

        if containsAny(normalized, ["bought list", "harvest", "scrape emails", "mass email", "bulk dm", "blast "])
            || containsAny(metadata?.contactSource?.lowercased() ?? "", ["bought", "scraped", "harvested"]) {
            findings.append(.blocked(
                "spam-risk",
                "The action looks like spam or contact-list harvesting.",
                "Use opt-in, warm, or directly sourced contacts with a suppression list and unsubscribe path."
            ))
        }

        if containsAny(normalized, ["api key", "secret", "password", "private token", "customer credential", "borrow credential"]) {
            findings.append(.blocked(
                "credential-misuse",
                "The action may expose or misuse credentials.",
                "Remove secrets from the action and request only a named, scoped credential grant."
            ))
        }

        if let credential = action.requestedCredential,
           !allowedCredentialNames.map({ $0.lowercased() }).contains(credential.lowercased()) {
            findings.append(.blocked(
                "credential-not-allowed",
                "The requested credential is not on this company's allowlist.",
                "Ask the operator to grant the credential by name before using it."
            ))
        }

        if containsAny(normalized, ["pii", "personal data", "customer list", "email list", "phone numbers", "ssn", "health records"]),
           metadata?.hasPrivacyFields != true {
            findings.append(.blocked(
                "privacy-leak-risk",
                "The action touches personal data without a legal basis and retention policy.",
                "Define the legal basis, target audience, minimization scope, and retention/deletion policy."
            ))
        }

        if containsAny(normalized, ["fake review", "impersonate", "pretend to be", "undisclosed affiliate"]) {
            findings.append(.blocked(
                "deceptive-flow",
                "The action contains deceptive identity, review, or disclosure behavior.",
                "Rewrite the action with truthful identity, real reviews only, and clear disclosures."
            ))
        }

        if containsAny(normalized, ["guaranteed income", "guaranteed roi", "risk-free investment", "instant approval"]) {
            findings.append(.blocked(
                "risky-claim",
                "The action uses an unsafe guarantee or regulated performance claim.",
                "Replace guarantees with qualified, evidence-backed claims and cite proof."
            ))
        }

        if containsAny(normalized, ["medical", "health", "hipaa", "legal advice", "law firm", "tax", "credit", "loan", "insurance", "real estate", "fair housing", "investment"]) {
            findings.append(.humanReview(
                "regulated-industry-review",
                "The action touches a regulated or high-risk industry.",
                "Get human review and keep the action draft-only until approved."
            ))
        }

        if containsAny(normalized, ["bypass captcha", "avoid rate limit", "rotate proxies", "create accounts", "terms of service"]) {
            findings.append(.humanReview(
                "platform-tos-review",
                "The action may conflict with platform terms or anti-abuse controls.",
                "Use a supported API/connector or get human approval for a compliant manual workflow."
            ))
        }

        if findings.contains(where: { $0.severity == .blocked }) {
            return CompanyComplianceDecision(status: .blocked, findings: findings)
        }
        if findings.contains(where: { $0.severity == .humanReviewRequired }) {
            return CompanyComplianceDecision(status: .humanReviewRequired, findings: findings)
        }
        return CompanyComplianceDecision(status: .approved, findings: findings)
    }

    static func evaluate(
        request: CompanyApprovalRequest,
        allowedCredentialNames: [String] = []
    ) -> CompanyComplianceDecision {
        evaluate(
            action: CompanyComplianceAction(
                companyID: request.companyID,
                channel: inferChannel(from: request.proposedAction),
                proposedAction: request.proposedAction,
                content: "\(request.expectedEffect) \(request.rollbackPlan)",
                metadata: request.complianceMetadata,
                browserPolicy: request.browserAutomationPolicy,
                targetDomain: request.targetDomain,
                browserAction: request.browserAction,
                requestedCredential: request.requestedCredential
            ),
            allowedCredentialNames: allowedCredentialNames
        )
    }

    static func inferChannel(from action: String) -> CompanyComplianceChannel {
        let normalized = action.lowercased()
        if containsAny(normalized, ["email", "newsletter"]) { return .email }
        if containsAny(normalized, ["tweet", "post", "dm ", "social", "linkedin", "x.com"]) { return .socialPlatform }
        if containsAny(normalized, ["etsy", "amazon", "marketplace", "listing"]) { return .marketplace }
        if containsAny(normalized, ["browser", "click", "scrape", "crawl"]) { return .browserAutomation }
        if containsAny(normalized, ["stripe", "charge", "refund", "payment", "checkout"]) { return .payments }
        if containsAny(normalized, ["collect", "import contacts", "customer list", "pii"]) { return .dataCollection }
        if containsAny(normalized, ["publish", "public"]) { return .publicContent }
        return .unknown
    }

    private static func requiresOutboundMetadata(_ channel: CompanyComplianceChannel) -> Bool {
        switch channel {
        case .email, .socialPlatform, .marketplace, .payments, .dataCollection, .scraping, .publicContent:
            return true
        case .browserAutomation, .unknown:
            return false
        }
    }

    private static func containsAny(_ value: String, _ needles: [String]) -> Bool {
        needles.contains { value.contains($0) }
    }
}

private extension CompanyComplianceFinding {
    static func blocked(_ id: String, _ message: String, _ fix: String) -> CompanyComplianceFinding {
        CompanyComplianceFinding(id: id, severity: .blocked, message: message, fix: fix)
    }

    static func humanReview(_ id: String, _ message: String, _ fix: String) -> CompanyComplianceFinding {
        CompanyComplianceFinding(id: id, severity: .humanReviewRequired, message: message, fix: fix)
    }
}
