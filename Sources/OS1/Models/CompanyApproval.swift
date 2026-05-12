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

struct CompanyApprovalAutoPolicy: Codable, Hashable, Identifiable {
    var id: String
    var createdBy: String
    var companyPattern: String
    var actionType: String
    var riskTier: CompanyApprovalRequest.RiskTier
    var createdAt: Date
    var thresholdCount: Int
    var windowDays: Int
    var revokedAt: Date?
    var revocationReason: String?

    var isRevoked: Bool { revokedAt != nil }

    func matches(_ request: CompanyApprovalRequest, now: Date) -> Bool {
        guard !isRevoked else { return false }
        guard riskTier == request.riskTier else { return false }
        guard actionType == CompanyApprovalQueueEngine.actionType(for: request.proposedAction) else { return false }
        if companyPattern == "*" { return true }
        if companyPattern.hasSuffix("*") {
            return request.companyID.hasPrefix(String(companyPattern.dropLast()))
        }
        return request.companyID == companyPattern
    }
}

struct CompanyApprovalQueueItem: Codable, Hashable, Identifiable {
    var id: String { requestID }
    var requestID: String
    var companyID: String
    var route: String
    var batchKey: String
    var status: CompanyApprovalRequest.Status
    var approvalMode: String
    var releasesLeaseBy: Date?
    var companyState: String?
    var event: CompanyEvent?
}

struct CompanyApprovalQueuePlan: Codable, Hashable {
    var items: [CompanyApprovalQueueItem]
    var batches: [String: [String]]
    var estimatedClearSeconds: Int
}

enum CompanyApprovalQueueEngine {
    static func actionType(for proposedAction: String) -> String {
        let normalized = CompanyApprovalPolicy.fingerprint(proposedAction)
        if normalized.contains("post tweet") || normalized.contains("post_tweet") { return "post_tweet" }
        if normalized.contains("refund") { return "refund" }
        if normalized.contains("publish") || normalized.contains("post ") { return "publish" }
        if normalized.contains("email") || normalized.contains("message") || normalized.contains("dm ") { return "outbound_message" }
        if normalized.contains("charge") || normalized.contains("checkout") || normalized.contains("payment") { return "payment" }
        return normalized.split(separator: " ").prefix(2).joined(separator: "_")
    }

    static func appendOnlyPolicy(
        id: String,
        createdBy: String,
        companyPattern: String,
        actionType: String,
        riskTier: CompanyApprovalRequest.RiskTier,
        createdAt: Date,
        thresholdCount: Int = 3,
        windowDays: Int = 14
    ) -> CompanyApprovalAutoPolicy {
        CompanyApprovalAutoPolicy(
            id: id,
            createdBy: createdBy,
            companyPattern: companyPattern,
            actionType: actionType,
            riskTier: riskTier,
            createdAt: createdAt,
            thresholdCount: thresholdCount,
            windowDays: windowDays,
            revokedAt: nil,
            revocationReason: nil
        )
    }

    static func revoke(
        _ policy: CompanyApprovalAutoPolicy,
        at date: Date,
        reason: String
    ) -> CompanyApprovalAutoPolicy {
        var copy = policy
        copy.revokedAt = date
        copy.revocationReason = CompanyEvent.redact(reason)
        return copy
    }

    static func plan(
        requests: [CompanyApprovalRequest],
        policies: [CompanyApprovalAutoPolicy],
        now: Date,
        expirySeconds: TimeInterval = 86_400
    ) -> CompanyApprovalQueuePlan {
        let items = requests.map { request in
            item(for: request, policies: policies, now: now, expirySeconds: expirySeconds)
        }
        let pendingBatches = Dictionary(grouping: items.filter { $0.status == .pending }) { $0.batchKey }
            .mapValues { $0.map(\.requestID).sorted() }
        let estimated = min(300, pendingBatches.count * 20 + items.filter { $0.status == .pending }.count)
        return CompanyApprovalQueuePlan(
            items: items,
            batches: pendingBatches,
            estimatedClearSeconds: estimated
        )
    }

    static func autoPolicyEligible(
        request: CompanyApprovalRequest,
        priorApprovals: [CompanyApprovalRequest],
        revocationCount: Int,
        threshold: Int,
        since: Date
    ) -> Bool {
        guard revocationCount == 0 else { return false }
        let action = actionType(for: request.proposedAction)
        let matches = priorApprovals.filter {
            $0.status == .approved &&
                $0.requestedAt >= since &&
                $0.riskTier == request.riskTier &&
                actionType(for: $0.proposedAction) == action
        }
        return matches.count >= threshold
    }

    static func event(for request: CompanyApprovalRequest, approvalMode: String, now: Date) -> CompanyEvent {
        CompanyEvent(
            occurredAt: now,
            companyID: request.companyID,
            actor: "approval-queue",
            kind: .approvalApproved,
            summary: "Approval queue approved \(request.proposedAction)",
            riskTier: request.riskTier.rawValue,
            approvalState: "approved",
            metadata: [
                "approval_mode": approvalMode,
                "requestID": request.id,
                "actionType": actionType(for: request.proposedAction)
            ]
        )
    }

    private static func item(
        for request: CompanyApprovalRequest,
        policies: [CompanyApprovalAutoPolicy],
        now: Date,
        expirySeconds: TimeInterval
    ) -> CompanyApprovalQueueItem {
        let action = actionType(for: request.proposedAction)
        let batchKey = "\(action)|\(request.riskTier.rawValue)"
        let expiresAt = request.expiresAt ?? request.requestedAt.addingTimeInterval(expirySeconds)
        if request.status == .pending && now >= expiresAt {
            return CompanyApprovalQueueItem(
                requestID: request.id,
                companyID: request.companyID,
                route: "expired",
                batchKey: batchKey,
                status: .expired,
                approvalMode: "expired",
                releasesLeaseBy: now.addingTimeInterval(60),
                companyState: "paused_awaiting_review",
                event: nil
            )
        }
        if policies.contains(where: { $0.matches(request, now: now) }) {
            return CompanyApprovalQueueItem(
                requestID: request.id,
                companyID: request.companyID,
                route: "auto",
                batchKey: batchKey,
                status: .approved,
                approvalMode: "auto",
                releasesLeaseBy: nil,
                companyState: nil,
                event: event(for: request, approvalMode: "auto", now: now)
            )
        }
        return CompanyApprovalQueueItem(
            requestID: request.id,
            companyID: request.companyID,
            route: route(for: request.riskTier),
            batchKey: batchKey,
            status: request.status,
            approvalMode: "manual",
            releasesLeaseBy: nil,
            companyState: nil,
            event: nil
        )
    }

    private static func route(for riskTier: CompanyApprovalRequest.RiskTier) -> String {
        switch riskTier {
        case .critical, .high: return "immediate"
        case .medium: return "hourly_digest"
        case .low: return "daily_digest"
        }
    }
}
