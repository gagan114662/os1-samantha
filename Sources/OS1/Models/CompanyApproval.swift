import Foundation

struct CompanyApprovalRequest: Codable, Hashable, Identifiable {
    enum RiskTier: String, Codable, CaseIterable, Hashable {
        case low
        case medium
        case high
        case critical
    }

    enum Status: String, Codable, CaseIterable, Hashable {
        case pending
        case approved
        case denied
        case changesRequested
        case alwaysRequireApproval
        case expired
    }

    let id: String
    let companyID: String
    var requestedAt: Date
    var actor: String
    var riskTier: RiskTier
    var proposedAction: String
    var expectedEffect: String
    var estimatedCostUSD: Double?
    var destinationAccount: String?
    var complianceMetadata: CompanyComplianceMetadata?
    var browserAutomationPolicy: CompanyBrowserAutomationPolicy?
    var targetDomain: String?
    var browserAction: String?
    var requestedCredential: String?
    var rollbackPlan: String
    var status: Status
    var decisionNote: String?
    var decidedAt: Date?
    var expiresAt: Date?

    init(
        id: String = UUID().uuidString,
        companyID: String,
        requestedAt: Date = Date(),
        actor: String = "codex",
        riskTier: RiskTier,
        proposedAction: String,
        expectedEffect: String,
        estimatedCostUSD: Double? = nil,
        destinationAccount: String? = nil,
        complianceMetadata: CompanyComplianceMetadata? = nil,
        browserAutomationPolicy: CompanyBrowserAutomationPolicy? = nil,
        targetDomain: String? = nil,
        browserAction: String? = nil,
        requestedCredential: String? = nil,
        rollbackPlan: String,
        status: Status = .pending,
        decisionNote: String? = nil,
        decidedAt: Date? = nil,
        expiresAt: Date? = nil
    ) {
        self.id = id
        self.companyID = companyID
        self.requestedAt = requestedAt
        self.actor = actor
        self.riskTier = riskTier
        self.proposedAction = CompanyEvent.redact(proposedAction)
        self.expectedEffect = CompanyEvent.redact(expectedEffect)
        self.estimatedCostUSD = estimatedCostUSD
        self.destinationAccount = destinationAccount.map(CompanyEvent.redact)
        self.complianceMetadata = complianceMetadata
        self.browserAutomationPolicy = browserAutomationPolicy
        self.targetDomain = targetDomain.map(CompanyEvent.redact)
        self.browserAction = browserAction.map(CompanyEvent.redact)
        self.requestedCredential = requestedCredential.map(CompanyEvent.redact)
        self.rollbackPlan = CompanyEvent.redact(rollbackPlan)
        self.status = status
        self.decisionNote = decisionNote.map(CompanyEvent.redact)
        self.decidedAt = decidedAt
        self.expiresAt = expiresAt
    }
}

struct CompanyApprovalGrant: Codable, Hashable, Identifiable {
    let id: String
    let requestID: String
    let companyID: String
    var approvedActionFingerprint: String
    var grantedAt: Date
    var expiresAt: Date?
    var maxCostUSD: Double?
    var remainingUses: Int?
    var destinationAccount: String?
    var decisionNote: String?

    init(
        id: String = UUID().uuidString,
        requestID: String,
        companyID: String,
        approvedActionFingerprint: String,
        grantedAt: Date,
        expiresAt: Date? = nil,
        maxCostUSD: Double? = nil,
        remainingUses: Int? = nil,
        destinationAccount: String? = nil,
        decisionNote: String? = nil
    ) {
        self.id = id
        self.requestID = requestID
        self.companyID = companyID
        self.approvedActionFingerprint = approvedActionFingerprint
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.maxCostUSD = maxCostUSD
        self.remainingUses = remainingUses
        self.destinationAccount = destinationAccount.map(CompanyEvent.redact)
        self.decisionNote = decisionNote.map(CompanyEvent.redact)
    }

    init(request: CompanyApprovalRequest, grantedAt: Date, expiresAt: Date?, remainingUses: Int?) {
        self.init(
            requestID: request.id,
            companyID: request.companyID,
            approvedActionFingerprint: CompanyApprovalPolicy.fingerprint(request.proposedAction),
            grantedAt: grantedAt,
            expiresAt: expiresAt,
            maxCostUSD: request.estimatedCostUSD,
            remainingUses: remainingUses,
            destinationAccount: request.destinationAccount,
            decisionNote: request.decisionNote
        )
    }

    func matches(
        companyID: String,
        proposedAction: String,
        estimatedCostUSD: Double?,
        destinationAccount: String?,
        now: Date
    ) -> Bool {
        guard self.companyID == companyID else { return false }
        guard approvedActionFingerprint == CompanyApprovalPolicy.fingerprint(proposedAction) else { return false }
        if let expiresAt, now >= expiresAt { return false }
        if let remainingUses, remainingUses <= 0 { return false }
        if let maxCostUSD, let estimatedCostUSD, estimatedCostUSD > maxCostUSD { return false }
        if let destination = self.destinationAccount, let proposedDestination = destinationAccount {
            return destination == CompanyEvent.redact(proposedDestination)
        }
        return true
    }
}

struct CompanyApprovalPolicy: Hashable {
    static let highRiskTerms = [
        "charge",
        "checkout",
        "contract",
        "delete",
        "dm ",
        "email ",
        "message ",
        "outreach",
        "payment",
        "post ",
        "publish",
        "purchase",
        "refund",
        "send ",
        "spend",
        "stripe",
        "wire"
    ]

    static func requiresApproval(proposedAction: String, estimatedCostUSD: Double?) -> Bool {
        if let estimatedCostUSD, estimatedCostUSD > 0 {
            return true
        }
        let normalized = " \(proposedAction.lowercased()) "
        return highRiskTerms.contains { normalized.contains($0) }
    }

    static func fingerprint(_ proposedAction: String) -> String {
        proposedAction
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
            .joined(separator: " ")
    }
}

enum CompanyApprovalGate {
    enum Status: String, Codable, CaseIterable, Hashable {
        case allowed
        case approvalRequired
        case denied
        case changesRequested
        case alwaysRequiresApproval
    }

    struct Evaluation: Codable, Hashable {
        var status: Status
        var matchingGrantID: String?
        var reason: String
        var followUpPlan: String?
    }

    static func evaluate(
        companyID: String,
        proposedAction: String,
        estimatedCostUSD: Double?,
        destinationAccount: String? = nil,
        now: Date = Date(),
        requests: [CompanyApprovalRequest] = [],
        grants: [CompanyApprovalGrant] = [],
        alwaysRequireApproval: Bool = false
    ) -> Evaluation {
        let needsApproval = alwaysRequireApproval ||
            CompanyApprovalPolicy.requiresApproval(
                proposedAction: proposedAction,
                estimatedCostUSD: estimatedCostUSD
            )
        guard needsApproval else {
            return .init(status: .allowed, reason: "Action is low-risk and does not require approval.")
        }

        let latest = latestRequest(
            companyID: companyID,
            proposedAction: proposedAction,
            requests: requests
        )
        switch latest?.status {
        case .denied:
            return .init(
                status: .denied,
                reason: latest?.decisionNote ?? "Operator denied this action.",
                followUpPlan: "Do not execute the denied action. Draft a safer alternative."
            )
        case .changesRequested:
            return .init(
                status: .changesRequested,
                reason: latest?.decisionNote ?? "Operator requested changes.",
                followUpPlan: "Revise the action, rollback plan, and limits before submitting a new request."
            )
        case .alwaysRequireApproval:
            return .init(
                status: .alwaysRequiresApproval,
                reason: latest?.decisionNote ?? "Operator requires explicit approval every time.",
                followUpPlan: "Submit a fresh approval request for each execution attempt."
            )
        case .pending, .approved, .expired, nil:
            break
        }

        if let grant = grants.first(where: {
            $0.matches(
                companyID: companyID,
                proposedAction: proposedAction,
                estimatedCostUSD: estimatedCostUSD,
                destinationAccount: destinationAccount,
                now: now
            )
        }) {
            return .init(
                status: .allowed,
                matchingGrantID: grant.id,
                reason: "Matching approval grant is active."
            )
        }

        return .init(
            status: .approvalRequired,
            reason: "High-risk action has no matching active approval grant.",
            followUpPlan: "Write APPROVAL_REQUEST.json and block until the operator decides."
        )
    }

    private static func latestRequest(
        companyID: String,
        proposedAction: String,
        requests: [CompanyApprovalRequest]
    ) -> CompanyApprovalRequest? {
        let fingerprint = CompanyApprovalPolicy.fingerprint(proposedAction)
        return requests
            .filter {
                $0.companyID == companyID &&
                    CompanyApprovalPolicy.fingerprint($0.proposedAction) == fingerprint
            }
            .sorted { $0.requestedAt > $1.requestedAt }
            .first
    }
}
