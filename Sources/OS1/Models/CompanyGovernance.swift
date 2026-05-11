import Foundation

enum CompanyDecisionKind: String, Codable, CaseIterable, Hashable {
    case launch
    case scale
    case pause
    case kill
    case budgetIncrease
    case complianceOverride
    case credentialGrant
    case providerChange
}

struct CompanyGovernanceOverride: Codable, Hashable {
    enum Status: String, Codable, Hashable {
        case active
        case renewalRequired
        case expired
    }

    var reason: String
    var approvedBy: String
    var createdAt: Date
    var expiresAt: Date
    var reviewDueAt: Date

    func status(at date: Date = Date()) -> Status {
        if date >= expiresAt { return .expired }
        if date >= reviewDueAt { return .renewalRequired }
        return .active
    }
}

struct CompanyProductionChangeChecklist: Codable, Hashable {
    var issueURL: String?
    var pullRequestURL: String?
    var releaseURL: String?
    var verificationArtifacts: [String]
    var riskSummary: String
    var rollbackPlan: String

    var missingItems: [String] {
        var missing: [String] = []
        if issueURL?.isEmpty ?? true { missing.append("issueURL") }
        if pullRequestURL?.isEmpty ?? true { missing.append("pullRequestURL") }
        if releaseURL?.isEmpty ?? true { missing.append("releaseURL") }
        if verificationArtifacts.isEmpty { missing.append("verificationArtifacts") }
        if riskSummary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("riskSummary")
        }
        if rollbackPlan.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            missing.append("rollbackPlan")
        }
        return missing
    }

    var isComplete: Bool { missingItems.isEmpty }
}

struct CompanyDecisionRecord: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var kind: CompanyDecisionKind
    var decidedAt: Date
    var decidedBy: String
    var approver: String
    var lifecycleFrom: CodexSession.LifecycleStage?
    var lifecycleTo: CodexSession.LifecycleStage?
    var rationale: String
    var evidenceLinks: [String]
    var evidenceSummary: String
    var alternativesConsidered: [String]
    var expectedFollowUp: String
    var override: CompanyGovernanceOverride?
    var productionChange: CompanyProductionChangeChecklist?

    init(
        id: String = UUID().uuidString,
        companyID: String,
        kind: CompanyDecisionKind,
        decidedAt: Date = Date(),
        decidedBy: String,
        approver: String,
        lifecycleFrom: CodexSession.LifecycleStage? = nil,
        lifecycleTo: CodexSession.LifecycleStage? = nil,
        rationale: String,
        evidenceLinks: [String],
        evidenceSummary: String,
        alternativesConsidered: [String],
        expectedFollowUp: String,
        override: CompanyGovernanceOverride? = nil,
        productionChange: CompanyProductionChangeChecklist? = nil
    ) {
        self.id = id
        self.companyID = companyID
        self.kind = kind
        self.decidedAt = decidedAt
        self.decidedBy = decidedBy
        self.approver = approver
        self.lifecycleFrom = lifecycleFrom
        self.lifecycleTo = lifecycleTo
        self.rationale = CompanyEvent.redact(rationale)
        self.evidenceLinks = evidenceLinks
        self.evidenceSummary = CompanyEvent.redact(evidenceSummary)
        self.alternativesConsidered = alternativesConsidered.map(CompanyEvent.redact)
        self.expectedFollowUp = CompanyEvent.redact(expectedFollowUp)
        self.override = override
        self.productionChange = productionChange
    }

    func auditEvent() -> CompanyEvent {
        CompanyEvent(
            companyID: companyID,
            actor: decidedBy,
            kind: .governanceDecisionRecorded,
            summary: "\(kind.rawValue) decision recorded: \(rationale)",
            riskTier: kind.rawValue,
            approvalState: override == nil ? "decision-recorded" : "override-recorded",
            metadata: [
                "decisionID": id,
                "approver": approver,
                "from": lifecycleFrom?.rawValue ?? "",
                "to": lifecycleTo?.rawValue ?? "",
                "evidenceCount": "\(evidenceLinks.count)",
                "followUp": expectedFollowUp
            ]
        )
    }
}

enum CompanyGovernanceEngine {
    static func record(
        lifecycleDecision: CompanyLifecycleDecision,
        decidedBy: String,
        approver: String,
        evidenceLinks: [String],
        alternativesConsidered: [String],
        expectedFollowUp: String,
        decidedAt: Date = Date(),
        override: CompanyGovernanceOverride? = nil
    ) -> CompanyDecisionRecord? {
        guard let kind = kind(for: lifecycleDecision) else { return nil }
        return CompanyDecisionRecord(
            companyID: lifecycleDecision.evidence.companyID,
            kind: kind,
            decidedAt: decidedAt,
            decidedBy: decidedBy,
            approver: approver,
            lifecycleFrom: lifecycleDecision.from,
            lifecycleTo: lifecycleDecision.to,
            rationale: lifecycleDecision.rationale,
            evidenceLinks: evidenceLinks,
            evidenceSummary: summary(for: lifecycleDecision.evidence),
            alternativesConsidered: alternativesConsidered,
            expectedFollowUp: expectedFollowUp,
            override: override
        )
    }

    static func budgetIncreaseRecord(
        companyID: String,
        approval: CompanyBudgetApproval,
        decidedBy: String,
        approver: String,
        evidenceLinks: [String],
        alternativesConsidered: [String],
        expectedFollowUp: String,
        decidedAt: Date = Date()
    ) -> CompanyDecisionRecord {
        CompanyDecisionRecord(
            companyID: companyID,
            kind: .budgetIncrease,
            decidedAt: decidedAt,
            decidedBy: decidedBy,
            approver: approver,
            rationale: approval.reason,
            evidenceLinks: evidenceLinks,
            evidenceSummary: [
                "Company budget +$\(approval.companyIncreaseUSD)",
                "global budget +$\(approval.globalIncreaseUSD)"
            ].joined(separator: "; "),
            alternativesConsidered: alternativesConsidered,
            expectedFollowUp: expectedFollowUp
        )
    }

    static func decisionRecord(
        companyID: String,
        kind: CompanyDecisionKind,
        decidedBy: String,
        approver: String,
        rationale: String,
        evidenceLinks: [String],
        evidenceSummary: String,
        alternativesConsidered: [String],
        expectedFollowUp: String,
        override: CompanyGovernanceOverride? = nil,
        productionChange: CompanyProductionChangeChecklist? = nil
    ) -> CompanyDecisionRecord {
        CompanyDecisionRecord(
            companyID: companyID,
            kind: kind,
            decidedBy: decidedBy,
            approver: approver,
            rationale: rationale,
            evidenceLinks: evidenceLinks,
            evidenceSummary: evidenceSummary,
            alternativesConsidered: alternativesConsidered,
            expectedFollowUp: expectedFollowUp,
            override: override,
            productionChange: productionChange
        )
    }

    static func explanation(
        companyID: String,
        kind: CompanyDecisionKind,
        records: [CompanyDecisionRecord]
    ) -> String? {
        records
            .filter { $0.companyID == companyID && $0.kind == kind }
            .sorted { $0.decidedAt > $1.decidedAt }
            .first
            .map {
                "\($0.kind.rawValue) by \($0.approver): \($0.rationale) Evidence: \($0.evidenceSummary)"
            }
    }

    static func validateProductionChange(_ checklist: CompanyProductionChangeChecklist) -> [String] {
        checklist.missingItems
    }

    private static func kind(for decision: CompanyLifecycleDecision) -> CompanyDecisionKind? {
        switch decision.action {
        case .promote where decision.to == .launched:
            return .launch
        case .scale:
            return .scale
        case .pause:
            return .pause
        case .kill:
            return .kill
        case .hold, .promote, .pivot:
            return nil
        }
    }

    private static func summary(for evidence: CompanyEvidenceSnapshot) -> String {
        [
            "stage=\(evidence.stage.rawValue)",
            "validation=\(evidence.validationDecision?.rawValue ?? "none")",
            "revenue=$\(evidence.ledger.revenueUSD)",
            "profit=$\(evidence.ledger.netUSD)",
            "failures=\(evidence.failureCount)",
            "risk=\(evidence.complianceRisk.rawValue)"
        ].joined(separator: " ")
    }
}
