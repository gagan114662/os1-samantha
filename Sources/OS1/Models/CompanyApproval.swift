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
        self.rollbackPlan = CompanyEvent.redact(rollbackPlan)
        self.status = status
        self.decisionNote = decisionNote.map(CompanyEvent.redact)
        self.decidedAt = decidedAt
        self.expiresAt = expiresAt
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
}
