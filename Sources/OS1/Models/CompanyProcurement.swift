import Foundation

struct CompanyProcurementPolicy: Codable, Hashable {
    var coveredCategories: Set<CompanyProcurementRequest.Category>
    var autoApprovalLimitUSD: Double
    var highRiskApprovalLimitUSD: Double
    var renewalWarningDays: Int
    var unusedSubscriptionWarningDays: Int

    static let productionDefault = CompanyProcurementPolicy(
        coveredCategories: Set(CompanyProcurementRequest.Category.allCases),
        autoApprovalLimitUSD: 0,
        highRiskApprovalLimitUSD: 0,
        renewalWarningDays: 14,
        unusedSubscriptionWarningDays: 30
    )
}

struct CompanyProcurementRequest: Codable, Hashable, Identifiable {
    enum Category: String, Codable, CaseIterable, Hashable {
        case domain
        case saasTool
        case apiPlan
        case ads
        case cloudResource
        case contractor
        case marketplaceListing
    }

    enum RenewalTerm: String, Codable, CaseIterable, Hashable {
        case oneTime
        case monthly
        case annual
    }

    var id: String
    var companyID: String
    var requestedAt: Date
    var category: Category
    var vendor: String
    var vendorOwner: String
    var amountUSD: Double
    var renewalTerm: RenewalTerm
    var nextRenewalAt: Date?
    var cancellationDeadline: Date?
    var riskTier: CompanyIdea.RiskTier
    var expectedROI: String
    var sourceEventID: UUID?
}

struct CompanyProcurementDecision: Codable, Hashable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case blocked
        case approvalRequired
        case approved
    }

    var requestID: String
    var status: Status
    var reasons: [String]
    var requiresApprover: Bool

    var canProvision: Bool {
        status == .approved
    }
}

struct CompanyProcurementApproval: Codable, Hashable, Identifiable {
    var id: String
    var requestID: String
    var companyID: String
    var approverID: String
    var approvedAt: Date
    var expiresAt: Date?
    var note: String
}

struct CompanyProcurementAuditLog: Codable, Hashable, Identifiable {
    enum Action: String, Codable, CaseIterable, Hashable {
        case requested
        case evaluated
        case approved
        case blocked
        case renewalWarning
        case unusedWarning
    }

    var id: String
    var occurredAt: Date
    var companyID: String
    var requestID: String
    var action: Action
    var actor: String
    var approverID: String?
    var expectedROI: String
    var metadata: [String: String]
}

struct CompanyProcurementSubscriptionState: Codable, Hashable {
    var request: CompanyProcurementRequest
    var approved: Bool
    var lastUsedAt: Date?
}

enum CompanyProcurementEngine {
    static func evaluate(
        _ request: CompanyProcurementRequest,
        policy: CompanyProcurementPolicy = .productionDefault,
        budgetReport: CompanyBudgetReport? = nil,
        approval: CompanyProcurementApproval? = nil
    ) -> CompanyProcurementDecision {
        var reasons: [String] = []
        guard policy.coveredCategories.contains(request.category) else {
            return CompanyProcurementDecision(
                requestID: request.id,
                status: .blocked,
                reasons: ["category has no approval policy coverage"],
                requiresApprover: true
            )
        }
        if let budgetReport, budgetReport.shouldBlockHeartbeat || budgetReport.isNearLimit {
            reasons.append("budget guard requires review")
        }
        if request.amountUSD > policy.autoApprovalLimitUSD {
            reasons.append("amount requires approval")
        }
        if request.renewalTerm != .oneTime {
            reasons.append("recurring renewal requires approval")
        }
        if request.riskTier == .high || request.riskTier == .critical {
            reasons.append("high-risk vendor/resource requires approval")
        }
        if let approval, approval.requestID == request.id {
            return CompanyProcurementDecision(
                requestID: request.id,
                status: .approved,
                reasons: ["approved by \(approval.approverID)"],
                requiresApprover: false
            )
        }
        return CompanyProcurementDecision(
            requestID: request.id,
            status: reasons.isEmpty ? .approved : .approvalRequired,
            reasons: reasons.isEmpty ? ["covered by procurement policy"] : reasons,
            requiresApprover: !reasons.isEmpty
        )
    }

    static func approve(
        _ request: CompanyProcurementRequest,
        approverID: String,
        now: Date,
        note: String
    ) -> CompanyProcurementApproval {
        CompanyProcurementApproval(
            id: "procurement-approval-\(request.id)",
            requestID: request.id,
            companyID: request.companyID,
            approverID: approverID,
            approvedAt: now,
            expiresAt: request.nextRenewalAt,
            note: note
        )
    }

    static func auditLog(
        request: CompanyProcurementRequest,
        decision: CompanyProcurementDecision,
        actor: String,
        now: Date
    ) -> CompanyProcurementAuditLog {
        CompanyProcurementAuditLog(
            id: "procurement-audit-\(request.id)-\(Int(now.timeIntervalSince1970))",
            occurredAt: now,
            companyID: request.companyID,
            requestID: request.id,
            action: decision.canProvision ? .approved : (decision.status == .blocked ? .blocked : .evaluated),
            actor: actor,
            approverID: decision.canProvision ? actor : nil,
            expectedROI: request.expectedROI,
            metadata: [
                "category": request.category.rawValue,
                "vendor": request.vendor,
                "amountUSD": "\(request.amountUSD)",
                "decision": decision.status.rawValue
            ]
        )
    }

    static func recurringLedgerEntries(
        subscriptions: [CompanyProcurementSubscriptionState],
        now: Date
    ) -> [CompanyLedgerEntry] {
        subscriptions.compactMap { state in
            guard state.approved,
                  state.request.renewalTerm != .oneTime,
                  let renewal = state.request.nextRenewalAt,
                  renewal <= now
            else { return nil }
            return CompanyLedgerEntry(
                id: "procurement-\(state.request.id)-\(Int(renewal.timeIntervalSince1970))",
                companyID: state.request.companyID,
                occurredAt: renewal,
                kind: .cost,
                category: ledgerCategory(for: state.request.category),
                amountUSD: state.request.amountUSD,
                source: "procurement",
                sourceReference: state.request.id,
                confidence: .verified,
                note: "Recurring \(state.request.vendor) \(state.request.renewalTerm.rawValue) renewal"
            )
        }
    }

    static func warnings(
        subscriptions: [CompanyProcurementSubscriptionState],
        policy: CompanyProcurementPolicy = .productionDefault,
        now: Date
    ) -> [CompanyProcurementAuditLog] {
        subscriptions.flatMap { state -> [CompanyProcurementAuditLog] in
            var logs: [CompanyProcurementAuditLog] = []
            if let renewal = state.request.nextRenewalAt,
               renewal.timeIntervalSince(now) <= Double(policy.renewalWarningDays) * 86_400,
               renewal >= now {
                logs.append(warningLog(state, action: .renewalWarning, now: now))
            }
            if let lastUsedAt = state.lastUsedAt,
               now.timeIntervalSince(lastUsedAt) >= Double(policy.unusedSubscriptionWarningDays) * 86_400 {
                logs.append(warningLog(state, action: .unusedWarning, now: now))
            }
            return logs
        }
    }

    private static func warningLog(
        _ state: CompanyProcurementSubscriptionState,
        action: CompanyProcurementAuditLog.Action,
        now: Date
    ) -> CompanyProcurementAuditLog {
        CompanyProcurementAuditLog(
            id: "\(action.rawValue)-\(state.request.id)-\(Int(now.timeIntervalSince1970))",
            occurredAt: now,
            companyID: state.request.companyID,
            requestID: state.request.id,
            action: action,
            actor: "os1",
            approverID: nil,
            expectedROI: state.request.expectedROI,
            metadata: ["vendor": state.request.vendor]
        )
    }

    private static func ledgerCategory(
        for category: CompanyProcurementRequest.Category
    ) -> CompanyLedgerEntry.Category {
        switch category {
        case .ads: return .ads
        case .cloudResource: return .cloudCompute
        case .apiPlan, .saasTool: return .tools
        case .domain, .contractor, .marketplaceListing: return .other
        }
    }
}
