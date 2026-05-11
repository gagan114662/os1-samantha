import Foundation

struct CompanySupportInboxConfig: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var supportContact: String
    var escalationPolicy: String
    var refundPolicyURL: URL?
    var cancellationWorkflowURL: URL?
    var slaHoursByPriority: [CompanySupportTicket.Priority: Int]
    var approvalPolicyID: String?

    init(
        id: String = UUID().uuidString,
        companyID: String,
        supportContact: String,
        escalationPolicy: String,
        refundPolicyURL: URL? = nil,
        cancellationWorkflowURL: URL? = nil,
        slaHoursByPriority: [CompanySupportTicket.Priority: Int] = [.low: 72, .normal: 24, .high: 8, .urgent: 2],
        approvalPolicyID: String? = nil
    ) {
        self.id = id
        self.companyID = companyID
        self.supportContact = supportContact.trimmingCharacters(in: .whitespacesAndNewlines)
        self.escalationPolicy = escalationPolicy.trimmingCharacters(in: .whitespacesAndNewlines)
        self.refundPolicyURL = refundPolicyURL
        self.cancellationWorkflowURL = cancellationWorkflowURL
        self.slaHoursByPriority = slaHoursByPriority
        self.approvalPolicyID = approvalPolicyID
    }
}

struct CompanySupportReadiness: Codable, Hashable {
    var companyID: String
    var blockers: [String]

    var canLaunch: Bool {
        blockers.isEmpty
    }
}

struct CompanySupportTicket: Codable, Hashable, Identifiable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case open
        case pendingCustomer
        case pendingInternal
        case refundPending
        case escalated
        case closed
    }

    enum Priority: String, Codable, CaseIterable, Hashable {
        case low
        case normal
        case high
        case urgent
    }

    let id: String
    var companyID: String
    var customerID: String
    var customerEmail: String
    var subject: String
    var status: Status
    var priority: Priority
    var createdAt: Date
    var dueAt: Date
    var linkedPaymentID: String?
    var linkedProductArea: String
    var escalationReason: String?

    var isOpen: Bool {
        status != .closed
    }

    func breachesSLA(now: Date) -> Bool {
        isOpen && now > dueAt
    }
}

struct CompanySupportReply: Codable, Hashable, Identifiable {
    let id: String
    var ticketID: String
    var customerID: String
    var draftedBy: String
    var body: String
    var loggedAt: Date
    var approvalState: CompanyGrowthCampaign.ApprovalState

    var isLogged: Bool {
        !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CompanyRefundWorkflow: Codable, Hashable, Identifiable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case drafted
        case approvalRequired
        case approved
        case processed
        case denied
    }

    let id: String
    var companyID: String
    var ticketID: String
    var paymentID: String
    var amountUSD: Double
    var reason: String
    var status: Status
    var approvalRequestID: String?
}

struct CompanySupportDashboard: Codable, Hashable {
    var companyID: String
    var openTickets: Int
    var slaBreaches: Int
    var refundsPending: Int
    var escalations: Int
    var loggedReplies: Int
}

enum CompanySupportOperations {
    static func readiness(config: CompanySupportInboxConfig?) -> CompanySupportReadiness {
        guard let config else {
            return .init(
                companyID: "",
                blockers: ["Support contact and escalation policy are required before launch."]
            )
        }

        var blockers: [String] = []
        if config.supportContact.isEmpty { blockers.append("Support contact is required.") }
        if config.escalationPolicy.isEmpty { blockers.append("Escalation policy is required.") }
        if config.refundPolicyURL == nil { blockers.append("Refund policy link is required.") }
        if config.cancellationWorkflowURL == nil { blockers.append("Cancellation workflow link is required.") }
        for priority in CompanySupportTicket.Priority.allCases where config.slaHoursByPriority[priority] == nil {
            blockers.append("SLA hours missing for \(priority.rawValue).")
        }
        return .init(companyID: config.companyID, blockers: blockers)
    }

    static func dashboard(
        companyID: String,
        tickets: [CompanySupportTicket],
        replies: [CompanySupportReply],
        refunds: [CompanyRefundWorkflow],
        now: Date
    ) -> CompanySupportDashboard {
        let companyTickets = tickets.filter { $0.companyID == companyID }
        return .init(
            companyID: companyID,
            openTickets: companyTickets.filter(\.isOpen).count,
            slaBreaches: companyTickets.filter { $0.breachesSLA(now: now) }.count,
            refundsPending: refunds.filter {
                $0.companyID == companyID && $0.status == .approvalRequired
            }.count,
            escalations: companyTickets.filter { $0.status == .escalated }.count,
            loggedReplies: replies.filter(\.isLogged).count
        )
    }

    static func replyApprovalState(for draft: String) -> CompanyGrowthCampaign.ApprovalState {
        let action = "support reply: \(draft)"
        return CompanyApprovalPolicy.requiresApproval(proposedAction: action, estimatedCostUSD: nil)
            ? .approvalRequired
            : .draft
    }

    static func refundRequiresApproval(_ refund: CompanyRefundWorkflow) -> Bool {
        CompanyApprovalPolicy.requiresApproval(
            proposedAction: "refund payment \(refund.paymentID)",
            estimatedCostUSD: refund.amountUSD
        )
    }
}
