import Foundation

struct CompanyEvidenceSnapshot: Codable, Hashable {
    var companyID: String
    var stage: CodexSession.LifecycleStage
    var validationDecision: CompanyValidationResult.Decision?
    var ledger: CompanyLedgerSummary
    var budgetReport: CompanyBudgetReport?
    var distribution: CompanyDistributionSummary?
    var legalReadiness: CompanyLegalReadiness? = nil
    var supportReadiness: CompanySupportReadiness? = nil
    var paymentsRisk: CompanyPaymentsRiskReport? = nil
    var failureCount: Int
    var complianceRisk: CompanyIdea.RiskTier
    var overrideReason: String?
    var artifactPaths: [String]

    var evidenceScore: Int {
        var score = 0
        if validationDecision == .readyToBuild { score += 20 }
        if ledger.canMarkProfitable { score += 30 }
        if ledger.netUSD > 0 { score += 15 }
        if distribution?.active.isEmpty == false { score += 10 }
        if budgetReport?.status == .warning { score -= 8 }
        if budgetReport?.shouldBlockHeartbeat == true { score -= 25 }
        if paymentsRisk?.accountHealth == .healthy { score += 8 }
        if paymentsRisk?.canEnableLiveBilling == false { score -= 8 }
        if paymentsRisk?.shouldPauseCompany == true { score -= 25 }
        score -= failureCount * 3
        if complianceRisk == .high || complianceRisk == .critical { score -= 10 }
        return max(0, score)
    }
}

struct CompanyLifecycleDecision: Codable, Hashable {
    enum Action: String, Codable, Hashable {
        case hold
        case promote
        case pause
        case kill
        case pivot
        case scale
    }

    var action: Action
    var from: CodexSession.LifecycleStage
    var to: CodexSession.LifecycleStage
    var rationale: String
    var requiresOverride: Bool
    var evidence: CompanyEvidenceSnapshot
}

struct CompanyPortfolioRank: Codable, Hashable, Identifiable {
    var id: String { companyID }
    var companyID: String
    var evidenceScore: Int
    var revenueUSD: Double
    var profitUSD: Double
    var risk: CompanyIdea.RiskTier
}

enum CompanyLifecycleEngine {
    static func decide(_ evidence: CompanyEvidenceSnapshot) -> CompanyLifecycleDecision {
        if let override = evidence.overrideReason, !override.isEmpty {
            return .init(
                action: .promote,
                from: evidence.stage,
                to: nextStage(after: evidence.stage),
                rationale: "Override recorded: \(override)",
                requiresOverride: false,
                evidence: evidence
            )
        }
        if evidence.complianceRisk == .critical {
            return .init(
                action: .kill,
                from: evidence.stage,
                to: .killed,
                rationale: "Critical compliance risk.",
                requiresOverride: false,
                evidence: evidence
            )
        }
        if evidence.failureCount >= 5 {
            return .init(
                action: .pause,
                from: evidence.stage,
                to: .paused,
                rationale: "Repeated failures breached lifecycle guard.",
                requiresOverride: false,
                evidence: evidence
            )
        }
        if evidence.budgetReport?.status == .emergencyShutdown {
            return .init(
                action: .kill,
                from: evidence.stage,
                to: .killed,
                rationale: "Emergency budget shutdown threshold reached.",
                requiresOverride: false,
                evidence: evidence
            )
        }
        if evidence.budgetReport?.status == .hardStop {
            return .init(
                action: .pause,
                from: evidence.stage,
                to: .paused,
                rationale: "Hard budget limit reached.",
                requiresOverride: false,
                evidence: evidence
            )
        }
        if evidence.paymentsRisk?.shouldPauseCompany == true {
            return .init(
                action: .pause,
                from: evidence.stage,
                to: .paused,
                rationale: "Unresolved payments risk requires pause.",
                requiresOverride: false,
                evidence: evidence
            )
        }
        let profitability = CompanyProfitabilityGuard.evaluate(summary: evidence.ledger)
        if profitability.shouldPause {
            return .init(
                action: .pause,
                from: evidence.stage,
                to: .paused,
                rationale: "Budget or unit economics guard: \(profitability.reasons.joined(separator: ","))",
                requiresOverride: false,
                evidence: evidence
            )
        }
        if evidence.stage == .validating && evidence.validationDecision == .rejected {
            return .init(
                action: .kill,
                from: .validating,
                to: .killed,
                rationale: "Validation rejected the idea.",
                requiresOverride: false,
                evidence: evidence
            )
        }
        if evidence.stage == .validating && evidence.validationDecision == .readyToBuild {
            return .init(
                action: .promote,
                from: .validating,
                to: .building,
                rationale: "Validation met ready-to-build thresholds.",
                requiresOverride: false,
                evidence: evidence
            )
        }
        if evidence.stage == .building && evidence.distribution?.active.isEmpty == false {
            guard evidence.legalReadiness?.canAcceptPayment == true else {
                let blockers = evidence.legalReadiness?.blockers.joined(separator: ", ")
                    ?? "Legal metadata is required before paid launch."
                return .init(
                    action: .hold,
                    from: .building,
                    to: .building,
                    rationale: "Legal launch gate blocked paid launch: \(blockers)",
                    requiresOverride: true,
                    evidence: evidence
                )
            }
            guard evidence.paymentsRisk?.canEnableLiveBilling == true else {
                let blockers = evidence.paymentsRisk?.blockers.joined(separator: ", ")
                    ?? "Payments risk review is required before live billing."
                return .init(
                    action: .hold,
                    from: .building,
                    to: .building,
                    rationale: "Payments launch gate blocked live billing: \(blockers)",
                    requiresOverride: true,
                    evidence: evidence
                )
            }
            guard evidence.supportReadiness?.canLaunch == true else {
                let blockers = evidence.supportReadiness?.blockers.joined(separator: ", ")
                    ?? "Support contact and escalation policy are required before launch."
                return .init(
                    action: .hold,
                    from: .building,
                    to: .building,
                    rationale: "Support launch gate blocked launch: \(blockers)",
                    requiresOverride: true,
                    evidence: evidence
                )
            }
            return .init(
                action: .promote,
                from: .building,
                to: .launched,
                rationale: "Launch assets and active distribution exist.",
                requiresOverride: false,
                evidence: evidence
            )
        }
        if evidence.ledger.canMarkProfitable && evidence.stage == .launched {
            return .init(
                action: .promote,
                from: .launched,
                to: .revenuePositive,
                rationale: "Verified or override-qualified revenue is positive.",
                requiresOverride: false,
                evidence: evidence
            )
        }
        if evidence.ledger.netUSD > 100 && evidence.stage == .revenuePositive {
            return .init(
                action: .scale,
                from: .revenuePositive,
                to: .scaling,
                rationale: "Profit threshold supports scaling.",
                requiresOverride: false,
                evidence: evidence
            )
        }
        return .init(
            action: .hold,
            from: evidence.stage,
            to: evidence.stage,
            rationale: "Configured gates are not yet satisfied.",
            requiresOverride: true,
            evidence: evidence
        )
    }

    static func rankPortfolio(_ snapshots: [CompanyEvidenceSnapshot]) -> [CompanyPortfolioRank] {
        snapshots.map {
            CompanyPortfolioRank(
                companyID: $0.companyID,
                evidenceScore: $0.evidenceScore,
                revenueUSD: $0.ledger.revenueUSD,
                profitUSD: $0.ledger.netUSD,
                risk: $0.complianceRisk
            )
        }
        .sorted {
            if $0.evidenceScore == $1.evidenceScore {
                if $0.profitUSD == $1.profitUSD { return $0.risk.rawValue < $1.risk.rawValue }
                return $0.profitUSD > $1.profitUSD
            }
            return $0.evidenceScore > $1.evidenceScore
        }
    }

    private static func nextStage(after stage: CodexSession.LifecycleStage) -> CodexSession.LifecycleStage {
        switch stage {
        case .idea: return .validating
        case .validating: return .building
        case .building: return .launched
        case .launched: return .revenuePositive
        case .revenuePositive: return .scaling
        case .scaling: return .scaling
        case .paused: return .validating
        case .killed: return .killed
        case .pivoting: return .validating
        }
    }
}
