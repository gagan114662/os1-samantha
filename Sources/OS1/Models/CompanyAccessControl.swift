import Foundation

enum CompanyActorRole: String, Codable, CaseIterable, Hashable {
    case owner
    case samantha
    case companyAgent
    case auditorAgent
    case supportAgent
    case contractor
    case readOnlyObserver
}

enum CompanyPermission: String, Codable, CaseIterable, Hashable {
    case companiesRead
    case companiesWrite
    case credentialsRead
    case credentialsWrite
    case approvalsRequest
    case approvalsReview
    case paymentsManage
    case deploymentsManage
    case crmRead
    case crmWrite
    case supportRead
    case supportRespond
    case logsRead
    case toolExecute
}

enum CompanyPermissionScope: Codable, Hashable {
    case all
    case specific(Set<String>)

    func contains(_ value: String?) -> Bool {
        switch self {
        case .all:
            return true
        case .specific(let allowed):
            guard let value else { return false }
            return allowed.contains(value)
        }
    }
}

struct CompanyRoleAssignment: Codable, Hashable, Identifiable {
    let id: String
    let principalID: String
    var role: CompanyActorRole
    var companyScope: CompanyPermissionScope
    var toolScope: CompanyPermissionScope
    var additionalPermissions: Set<CompanyPermission>
    var deniedPermissions: Set<CompanyPermission>
    var delegatedBy: String?
    var validFrom: Date
    var expiresAt: Date?
    var revokedAt: Date?

    init(
        id: String = UUID().uuidString,
        principalID: String,
        role: CompanyActorRole,
        companyScope: CompanyPermissionScope = .all,
        toolScope: CompanyPermissionScope = .all,
        additionalPermissions: Set<CompanyPermission> = [],
        deniedPermissions: Set<CompanyPermission> = [],
        delegatedBy: String? = nil,
        validFrom: Date = Date(),
        expiresAt: Date? = nil,
        revokedAt: Date? = nil
    ) {
        self.id = id
        self.principalID = principalID
        self.role = role
        self.companyScope = companyScope
        self.toolScope = toolScope
        self.additionalPermissions = additionalPermissions
        self.deniedPermissions = deniedPermissions
        self.delegatedBy = delegatedBy
        self.validFrom = validFrom
        self.expiresAt = expiresAt
        self.revokedAt = revokedAt
    }

    func isActive(at date: Date = Date()) -> Bool {
        if revokedAt != nil { return false }
        if date < validFrom { return false }
        if let expiresAt, date >= expiresAt { return false }
        return true
    }

    func permissions(at date: Date = Date()) -> Set<CompanyPermission> {
        guard isActive(at: date) else { return [] }
        return Self.basePermissions(for: role)
            .union(additionalPermissions)
            .subtracting(deniedPermissions)
    }

    static func basePermissions(for role: CompanyActorRole) -> Set<CompanyPermission> {
        switch role {
        case .owner:
            return Set(CompanyPermission.allCases)
        case .samantha:
            return [
                .companiesRead,
                .companiesWrite,
                .credentialsRead,
                .approvalsRequest,
                .paymentsManage,
                .deploymentsManage,
                .crmRead,
                .crmWrite,
                .supportRead,
                .supportRespond,
                .logsRead,
                .toolExecute
            ]
        case .companyAgent:
            return [.companiesRead, .companiesWrite, .approvalsRequest, .crmRead, .crmWrite, .toolExecute]
        case .auditorAgent:
            return [.companiesRead, .approvalsReview, .logsRead]
        case .supportAgent:
            return [.companiesRead, .crmRead, .supportRead, .supportRespond, .logsRead, .toolExecute]
        case .contractor:
            return []
        case .readOnlyObserver:
            return [.companiesRead, .logsRead]
        }
    }
}

enum CompanyActionCategory: String, Codable, CaseIterable, Hashable {
    case company
    case credential
    case approval
    case payment
    case deployment
    case crm
    case support
    case log
    case tool
}

struct CompanyPermissionedAction: Codable, Hashable, Identifiable {
    let id: String
    let companyID: String?
    let toolID: String?
    let category: CompanyActionCategory
    let requiredPermission: CompanyPermission
    let proposedAction: String
    let estimatedCostUSD: Double?

    init(
        id: String = UUID().uuidString,
        companyID: String? = nil,
        toolID: String? = nil,
        category: CompanyActionCategory,
        requiredPermission: CompanyPermission,
        proposedAction: String,
        estimatedCostUSD: Double? = nil
    ) {
        self.id = id
        self.companyID = companyID
        self.toolID = toolID
        self.category = category
        self.requiredPermission = requiredPermission
        self.proposedAction = CompanyEvent.redact(proposedAction)
        self.estimatedCostUSD = estimatedCostUSD
    }
}

struct CompanyPermissionDecision: Codable, Hashable {
    enum Status: String, Codable, Hashable {
        case allowed
        case denied
    }

    let status: Status
    let reason: String
    let requiresApproval: Bool
    let auditEvents: [CompanyEvent]

    var isAllowed: Bool { status == .allowed }
}

enum CompanyPermissionGate {
    static func authorize(
        actor: CompanyRoleAssignment,
        action: CompanyPermissionedAction,
        at date: Date = Date()
    ) -> CompanyPermissionDecision {
        guard actor.isActive(at: date) else {
            return denied(actor: actor, action: action, reason: "role assignment is inactive")
        }
        guard actor.companyScope.contains(action.companyID) else {
            return denied(actor: actor, action: action, reason: "company is outside assigned scope")
        }
        guard actor.toolScope.contains(action.toolID) else {
            return denied(actor: actor, action: action, reason: "tool is outside assigned scope")
        }
        guard actor.permissions(at: date).contains(action.requiredPermission) else {
            return denied(actor: actor, action: action, reason: "role lacks required permission")
        }

        let requiresApproval = CompanyApprovalPolicy.requiresApproval(
            proposedAction: action.proposedAction,
            estimatedCostUSD: action.estimatedCostUSD
        )
        let events = requiresApproval ? [escalationEvent(actor: actor, action: action)] : []
        return CompanyPermissionDecision(
            status: .allowed,
            reason: "allowed",
            requiresApproval: requiresApproval,
            auditEvents: events
        )
    }

    static func grantDelegation(
        to actor: CompanyRoleAssignment,
        permissions: Set<CompanyPermission>,
        delegatedBy: String,
        expiresAt: Date,
        at date: Date = Date()
    ) -> (assignment: CompanyRoleAssignment, auditEvent: CompanyEvent) {
        var updated = actor
        updated.additionalPermissions.formUnion(permissions)
        updated.delegatedBy = delegatedBy
        updated.validFrom = date
        updated.expiresAt = expiresAt
        updated.revokedAt = nil
        return (
            updated,
            changeEvent(actor: updated, changedBy: delegatedBy, action: "delegated", permissions: permissions)
        )
    }

    static func revokeDelegation(
        from actor: CompanyRoleAssignment,
        revokedBy: String,
        at date: Date = Date()
    ) -> (assignment: CompanyRoleAssignment, auditEvent: CompanyEvent) {
        var updated = actor
        updated.revokedAt = date
        return (
            updated,
            changeEvent(
                actor: updated,
                changedBy: revokedBy,
                action: "revoked",
                permissions: actor.additionalPermissions
            )
        )
    }

    private static func denied(
        actor: CompanyRoleAssignment,
        action: CompanyPermissionedAction,
        reason: String
    ) -> CompanyPermissionDecision {
        CompanyPermissionDecision(
            status: .denied,
            reason: reason,
            requiresApproval: false,
            auditEvents: [denialEvent(actor: actor, action: action, reason: reason)]
        )
    }

    private static func denialEvent(
        actor: CompanyRoleAssignment,
        action: CompanyPermissionedAction,
        reason: String
    ) -> CompanyEvent {
        CompanyEvent(
            companyID: action.companyID,
            actor: actor.principalID,
            kind: .permissionDenied,
            summary: "Permission denied for \(action.proposedAction)",
            tool: action.toolID,
            riskTier: action.category.rawValue,
            approvalState: "permission-denied",
            metadata: [
                "actionID": action.id,
                "role": actor.role.rawValue,
                "permission": action.requiredPermission.rawValue,
                "reason": reason
            ]
        )
    }

    private static func escalationEvent(
        actor: CompanyRoleAssignment,
        action: CompanyPermissionedAction
    ) -> CompanyEvent {
        CompanyEvent(
            companyID: action.companyID,
            actor: actor.principalID,
            kind: .permissionEscalated,
            summary: "Permission allowed but approval required for \(action.proposedAction)",
            tool: action.toolID,
            costUSD: action.estimatedCostUSD,
            riskTier: action.category.rawValue,
            approvalState: "approval-required",
            metadata: [
                "actionID": action.id,
                "role": actor.role.rawValue,
                "permission": action.requiredPermission.rawValue
            ]
        )
    }

    private static func changeEvent(
        actor: CompanyRoleAssignment,
        changedBy: String,
        action: String,
        permissions: Set<CompanyPermission>
    ) -> CompanyEvent {
        CompanyEvent(
            actor: changedBy,
            kind: .permissionChanged,
            summary: "Permissions \(action) for \(actor.principalID)",
            approvalState: "permission-change",
            metadata: [
                "targetPrincipalID": actor.principalID,
                "role": actor.role.rawValue,
                "permissions": permissions.map(\.rawValue).sorted().joined(separator: ","),
                "delegatedBy": actor.delegatedBy ?? "",
                "expiresAt": actor.expiresAt.map { ISO8601DateFormatter().string(from: $0) } ?? "",
                "revokedAt": actor.revokedAt.map { ISO8601DateFormatter().string(from: $0) } ?? ""
            ]
        )
    }
}

struct CompanyAccessControl: Codable, Hashable {
    enum Capability: String, Codable, CaseIterable, Hashable {
        case payments
    }

    struct ToolkitAccessDecision: Codable, Hashable {
        enum Status: String, Codable, Hashable {
            case denied
            case approvalRequired = "approval_required"
            case allowed
        }

        var status: Status
        var reason: String
        var riskTier: ComposioToolkitMeta.RiskTier

        var requiresApproval: Bool { status == .approvalRequired }
    }

    var companyID: String
    var mediaProviderAllowlist: Set<String>
    var seoProviderAllowlist: Set<String>
    var composioToolkitAllowlist: Set<String> = []
    var embeddingProviderAllowlist: Set<String>
    var analyticsSourceAllowlist: Set<String> = []
    var paymentProviderAllowlist: Set<String> = []
    var espProviderAllowlist: Set<String> = []
    var marketplaceAllowlist: Set<String> = []
    var hostingProviderAllowlist: Set<String> = []
    var registrarAllowlist: Set<String> = []
    var crmProviderAllowlist: Set<String> = []
    var supportProviderAllowlist: Set<String> = []
    var storageProviderAllowlist: Set<String> = []
    var adProviderAllowlist: Set<String> = []
    var enrichmentProviderAllowlist: Set<String> = []
    var bookingProviderAllowlist: Set<String> = []
    var voiceProviderAllowlist: Set<String> = []
    var courseCommunityProviderAllowlist: Set<String> = []
    var reviewProviderAllowlist: Set<String> = []
    var referralPayoutProviderAllowlist: Set<String> = []
    var entityProviderAllowlist: Set<String> = []
    var bankingProviderAllowlist: Set<String> = []
    var clientDataAccessAllowlist: Set<String> = []
    var experimentationEnabled: Bool

    static func lockedDown(companyID: String) -> CompanyAccessControl {
        CompanyAccessControl(
            companyID: companyID,
            mediaProviderAllowlist: [],
            seoProviderAllowlist: [],
            embeddingProviderAllowlist: [],
            experimentationEnabled: false
        )
    }

    func allowsMediaProvider(_ slug: String, modality: ProviderCatalogEntry.Modality? = nil) -> Bool {
        guard mediaProviderAllowlist.contains(slug) else { return false }
        if let modality, let entry = ProviderCatalog.entry(for: slug) {
            return entry.modality == modality
        }
        return true
    }

    func composioToolkitAccess(
        for toolkit: ComposioToolkitMeta,
        cleanHistoryDays: Int
    ) -> ToolkitAccessDecision {
        guard composioToolkitAllowlist.contains(toolkit.slug) else {
            return ToolkitAccessDecision(
                status: .denied,
                reason: "toolkit not granted to company",
                riskTier: toolkit.riskTier
            )
        }

        if toolkit.requiresEarlyApproval(cleanHistoryDays: cleanHistoryDays) {
            return ToolkitAccessDecision(
                status: .approvalRequired,
                reason: "social/community toolkit requires approval until 7 clean-history days",
                riskTier: toolkit.riskTier
            )
        }

        return ToolkitAccessDecision(
            status: .allowed,
            reason: "toolkit granted",
            riskTier: toolkit.riskTier
        )
    }

    static func grantCapabilities(_ capabilities: Set<Capability>, companyID: String) {
        CompanyAccessControlCapabilityRegistry.shared.set(capabilities: capabilities, companyID: companyID)
    }

    static func canUse(companyID: String, capability: Capability) -> Bool {
        CompanyAccessControlCapabilityRegistry.shared.canUse(companyID: companyID, capability: capability)
    }
}

private final class CompanyAccessControlCapabilityRegistry: @unchecked Sendable {
    static let shared = CompanyAccessControlCapabilityRegistry()

    private let lock = NSLock()
    private var grants: [String: Set<CompanyAccessControl.Capability>] = [:]

    func set(capabilities: Set<CompanyAccessControl.Capability>, companyID: String) {
        lock.lock()
        grants[companyID] = capabilities
        lock.unlock()
    }

    func canUse(companyID: String, capability: CompanyAccessControl.Capability) -> Bool {
        lock.lock()
        let allowed = grants[companyID]?.contains(capability) ?? false
        lock.unlock()
        return allowed
    }
}
