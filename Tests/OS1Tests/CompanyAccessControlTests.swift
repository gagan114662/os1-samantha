import Foundation
import Testing
@testable import OS1

struct CompanyAccessControlTests {
    @Test
    func highRiskActionsCheckRolePermissionBeforeApprovalPolicy() {
        let contractor = CompanyRoleAssignment(
            principalID: "contractor-1",
            role: .contractor,
            companyScope: .specific(["co-1"]),
            toolScope: .specific(["stripe"])
        )
        let action = CompanyPermissionedAction(
            id: "pay-1",
            companyID: "co-1",
            toolID: "stripe",
            category: .payment,
            requiredPermission: .paymentsManage,
            proposedAction: "Create Stripe checkout link",
            estimatedCostUSD: 1
        )

        let denied = CompanyPermissionGate.authorize(actor: contractor, action: action)

        #expect(!denied.isAllowed)
        #expect(!denied.requiresApproval)
        #expect(denied.auditEvents.first?.kind == .permissionDenied)
        #expect(denied.auditEvents.first?.approvalState == "permission-denied")

        let owner = CompanyRoleAssignment(principalID: "owner", role: .owner)
        let allowed = CompanyPermissionGate.authorize(actor: owner, action: action)

        #expect(allowed.isAllowed)
        #expect(allowed.requiresApproval)
        #expect(allowed.auditEvents.first?.kind == .permissionEscalated)
    }

    @Test
    func contractorsAndAgentsCanBeScopedToSpecificCompaniesAndTools() {
        let companyAgent = CompanyRoleAssignment(
            principalID: "agent-1",
            role: .companyAgent,
            companyScope: .specific(["co-1"]),
            toolScope: .specific(["crm"])
        )
        let crmAction = CompanyPermissionedAction(
            companyID: "co-1",
            toolID: "crm",
            category: .crm,
            requiredPermission: .crmWrite,
            proposedAction: "Update CRM lifecycle stage"
        )
        let outOfScopeCompany = CompanyPermissionedAction(
            companyID: "co-2",
            toolID: "crm",
            category: .crm,
            requiredPermission: .crmWrite,
            proposedAction: "Update CRM lifecycle stage"
        )
        let outOfScopeTool = CompanyPermissionedAction(
            companyID: "co-1",
            toolID: "stripe",
            category: .payment,
            requiredPermission: .paymentsManage,
            proposedAction: "Refund customer payment"
        )

        #expect(CompanyPermissionGate.authorize(actor: companyAgent, action: crmAction).isAllowed)
        #expect(!CompanyPermissionGate.authorize(actor: companyAgent, action: outOfScopeCompany).isAllowed)
        #expect(!CompanyPermissionGate.authorize(actor: companyAgent, action: outOfScopeTool).isAllowed)
    }

    @Test
    func permissionChangesAreAuditableAndRevocationStopsAccess() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let contractor = CompanyRoleAssignment(
            principalID: "contractor-1",
            role: .contractor,
            companyScope: .specific(["co-1"]),
            toolScope: .specific(["support"])
        )
        let grant = CompanyPermissionGate.grantDelegation(
            to: contractor,
            permissions: [.supportRespond, .toolExecute],
            delegatedBy: "owner",
            expiresAt: now.addingTimeInterval(3_600),
            at: now
        )

        #expect(grant.auditEvent.kind == .permissionChanged)
        #expect(grant.auditEvent.metadata["targetPrincipalID"] == "contractor-1")
        #expect(grant.assignment.permissions(at: now).contains(.supportRespond))

        let revoke = CompanyPermissionGate.revokeDelegation(from: grant.assignment, revokedBy: "owner", at: now)
        let action = CompanyPermissionedAction(
            companyID: "co-1",
            toolID: "support",
            category: .support,
            requiredPermission: .supportRespond,
            proposedAction: "Reply to support ticket"
        )

        #expect(revoke.auditEvent.metadata["revokedAt"]?.isEmpty == false)
        #expect(!CompanyPermissionGate.authorize(actor: revoke.assignment, action: action, at: now).isAllowed)
    }

    @Test
    func allowedAndDeniedActionsAreCoveredForEachRole() {
        let cases: [(CompanyActorRole, CompanyPermission, Bool)] = [
            (.owner, .credentialsWrite, true),
            (.samantha, .deploymentsManage, true),
            (.companyAgent, .paymentsManage, false),
            (.auditorAgent, .logsRead, true),
            (.supportAgent, .supportRespond, true),
            (.contractor, .toolExecute, false),
            (.readOnlyObserver, .companiesWrite, false)
        ]

        for (role, permission, shouldAllow) in cases {
            let actor = CompanyRoleAssignment(principalID: role.rawValue, role: role)
            let action = CompanyPermissionedAction(
                companyID: "co-1",
                toolID: "tool",
                category: .tool,
                requiredPermission: permission,
                proposedAction: "Execute \(permission.rawValue)"
            )

            #expect(CompanyPermissionGate.authorize(actor: actor, action: action).isAllowed == shouldAllow)
        }
    }

    @Test
    func mediaProviderAllowlistBlocksUnapprovedModalities() {
        let locked = CompanyAccessControl.lockedDown(companyID: "co-1")
        #expect(!locked.allowsMediaProvider("elevenlabs-tts", modality: .tts))

        let allowed = CompanyAccessControl(
            companyID: "co-1",
            mediaProviderAllowlist: ["elevenlabs-tts"],
            seoProviderAllowlist: [],
            embeddingProviderAllowlist: [],
            experimentationEnabled: false
        )

        #expect(allowed.allowsMediaProvider("elevenlabs-tts", modality: .tts))
        #expect(!allowed.allowsMediaProvider("elevenlabs-tts", modality: .video))
    }
}
