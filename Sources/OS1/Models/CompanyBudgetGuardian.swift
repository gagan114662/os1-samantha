import Foundation

enum CompanyBudgetStatus: String, Codable, Hashable {
    case healthy
    case warning
    case hardStop
    case emergencyShutdown
}

struct CompanyBudgetPolicy: Codable, Hashable {
    var companyWarningLimitUSD: Double
    var companyHardLimitUSD: Double
    var companyEmergencyLimitUSD: Double
    var globalWarningLimitUSD: Double
    var globalHardLimitUSD: Double
    var globalEmergencyLimitUSD: Double
    var channelWarningLimitsUSD: [CompanyLedgerEntry.Category: Double]
    var channelHardLimitsUSD: [CompanyLedgerEntry.Category: Double]

    static let productionDefault = CompanyBudgetPolicy(
        companyWarningLimitUSD: 35,
        companyHardLimitUSD: 50,
        companyEmergencyLimitUSD: 100,
        globalWarningLimitUSD: 350,
        globalHardLimitUSD: 500,
        globalEmergencyLimitUSD: 750,
        channelWarningLimitsUSD: [
            .tokenUsage: 12,
            .cloudCompute: 20,
            .ads: 15,
            .tools: 15,
            .subscription: 20,
            .purchases: 15,
            .paymentFees: 10
        ],
        channelHardLimitsUSD: [
            .tokenUsage: 20,
            .cloudCompute: 30,
            .ads: 25,
            .tools: 25,
            .subscription: 30,
            .purchases: 25,
            .paymentFees: 15
        ]
    )
}

struct CompanyBudgetApproval: Codable, Hashable, Identifiable {
    var id: String
    var approvedAt: Date
    var expiresAt: Date?
    var reason: String
    var companyIncreaseUSD: Double
    var globalIncreaseUSD: Double
    var channelIncreasesUSD: [CompanyLedgerEntry.Category: Double]

    func isActive(at now: Date) -> Bool {
        guard let expiresAt else { return true }
        return expiresAt > now
    }
}

struct CompanyBudgetReport: Codable, Hashable {
    struct ChannelUsage: Codable, Hashable {
        var category: CompanyLedgerEntry.Category
        var estimatedUSD: Double
        var actualUSD: Double
        var warningLimitUSD: Double?
        var hardLimitUSD: Double?

        var totalUSD: Double { estimatedUSD + actualUSD }
    }

    var companyID: String?
    var status: CompanyBudgetStatus
    var companyEstimatedSpendUSD: Double
    var companyActualSpendUSD: Double
    var companyHardLimitUSD: Double
    var companyEmergencyLimitUSD: Double
    var globalSpendUSD: Double
    var globalHardLimitUSD: Double
    var globalEmergencyLimitUSD: Double
    var channelUsage: [ChannelUsage]
    var reasons: [String]

    var companySpendUSD: Double {
        companyEstimatedSpendUSD + companyActualSpendUSD
    }

    var remainingCompanyHardLimitUSD: Double {
        companyHardLimitUSD - companySpendUSD
    }

    var shouldBlockHeartbeat: Bool {
        status == .hardStop || status == .emergencyShutdown
    }

    var isNearLimit: Bool {
        status == .warning
    }
}

enum CompanyBudgetGuardian {
    static func approval(
        from request: CompanyApprovalRequest,
        approvedAt: Date,
        expiresAt: Date?
    ) -> CompanyBudgetApproval? {
        let amount = max(0, request.estimatedCostUSD ?? 0)
        guard amount > 0 || request.proposedAction.localizedCaseInsensitiveContains("budget") else {
            return nil
        }
        return CompanyBudgetApproval(
            id: request.id,
            approvedAt: approvedAt,
            expiresAt: expiresAt,
            reason: request.decisionNote ?? request.proposedAction,
            companyIncreaseUSD: amount,
            globalIncreaseUSD: amount,
            channelIncreasesUSD: [category(for: request.proposedAction): amount]
        )
    }

    static func evaluate(
        companyID: String?,
        ledger: CompanyLedgerSummary,
        budget: CodexSession.BudgetState?,
        globalLedgerSummaries: [CompanyLedgerSummary],
        now: Date = Date()
    ) -> CompanyBudgetReport {
        let state = budget ?? .defaultState(now: now)
        let policy = state.policy
        let activeApprovals = state.approvals.filter { $0.isActive(at: now) }
        let companyIncrease = activeApprovals.reduce(0) { $0 + max(0, $1.companyIncreaseUSD) }
        let globalIncrease = activeApprovals.reduce(0) { $0 + max(0, $1.globalIncreaseUSD) }
        let channelIncreases = activeApprovals.reduce(into: [CompanyLedgerEntry.Category: Double]()) { partial, approval in
            for (category, increase) in approval.channelIncreasesUSD {
                partial[category, default: 0] += max(0, increase)
            }
        }

        let companyCosts = ledger.entries.filter { $0.kind == .cost }
        let estimated = spend(entries: companyCosts, estimated: true)
        let actual = spend(entries: companyCosts, estimated: false)
        let globalSpend = globalLedgerSummaries
            .flatMap(\.entries)
            .filter { $0.kind == .cost }
            .reduce(0) { $0 + $1.amountUSD }

        let companyHard = policy.companyHardLimitUSD + companyIncrease
        let globalHard = policy.globalHardLimitUSD + globalIncrease
        let channels = channelUsage(
            entries: companyCosts,
            policy: policy,
            channelIncreases: channelIncreases
        )

        var reasons: [String] = []
        var status = CompanyBudgetStatus.healthy
        let companySpend = estimated + actual

        if companySpend >= policy.companyEmergencyLimitUSD {
            reasons.append("companyEmergencyShutdown")
            status = .emergencyShutdown
        } else if companySpend >= companyHard {
            reasons.append("companyHardLimit")
            status = maxStatus(status, .hardStop)
        } else if companySpend >= policy.companyWarningLimitUSD {
            reasons.append("companyWarningLimit")
            status = maxStatus(status, .warning)
        }

        if globalSpend >= policy.globalEmergencyLimitUSD {
            reasons.append("globalEmergencyShutdown")
            status = .emergencyShutdown
        } else if globalSpend >= globalHard {
            reasons.append("globalHardLimit")
            status = maxStatus(status, .hardStop)
        } else if globalSpend >= policy.globalWarningLimitUSD {
            reasons.append("globalWarningLimit")
            status = maxStatus(status, .warning)
        }

        for channel in channels {
            if let hard = channel.hardLimitUSD, channel.totalUSD >= hard {
                reasons.append("channelHardLimit:\(channel.category.rawValue)")
                status = maxStatus(status, .hardStop)
            } else if let warning = channel.warningLimitUSD, channel.totalUSD >= warning {
                reasons.append("channelWarningLimit:\(channel.category.rawValue)")
                status = maxStatus(status, .warning)
            }
        }

        return CompanyBudgetReport(
            companyID: companyID,
            status: status,
            companyEstimatedSpendUSD: estimated,
            companyActualSpendUSD: actual,
            companyHardLimitUSD: companyHard,
            companyEmergencyLimitUSD: policy.companyEmergencyLimitUSD,
            globalSpendUSD: globalSpend,
            globalHardLimitUSD: globalHard,
            globalEmergencyLimitUSD: policy.globalEmergencyLimitUSD,
            channelUsage: channels,
            reasons: reasons
        )
    }

    static func globalReport(
        summaries: [CompanyLedgerSummary],
        budget: CodexSession.BudgetState? = nil,
        now: Date = Date()
    ) -> CompanyBudgetReport {
        evaluate(
            companyID: nil,
            ledger: CompanyLedgerSummary(entries: summaries.flatMap(\.entries)),
            budget: budget,
            globalLedgerSummaries: summaries,
            now: now
        )
    }

    private static func spend(entries: [CompanyLedgerEntry], estimated: Bool) -> Double {
        entries
            .filter { ($0.confidence == .estimated) == estimated }
            .reduce(0) { $0 + $1.amountUSD }
    }

    private static func category(for proposedAction: String) -> CompanyLedgerEntry.Category {
        let lower = proposedAction.lowercased()
        if lower.contains("ad") || lower.contains("campaign") { return .ads }
        if lower.contains("token") || lower.contains("codex") || lower.contains("claude") || lower.contains("openai") { return .tokenUsage }
        if lower.contains("cloud") || lower.contains("orgo") || lower.contains("vm") || lower.contains("compute") { return .cloudCompute }
        if lower.contains("subscription") { return .subscription }
        if lower.contains("tool") || lower.contains("api") || lower.contains("software") { return .tools }
        if lower.contains("fee") || lower.contains("stripe") || lower.contains("payment") { return .paymentFees }
        if lower.contains("purchase") || lower.contains("domain") || lower.contains("buy") { return .purchases }
        return .other
    }

    private static func channelUsage(
        entries: [CompanyLedgerEntry],
        policy: CompanyBudgetPolicy,
        channelIncreases: [CompanyLedgerEntry.Category: Double]
    ) -> [CompanyBudgetReport.ChannelUsage] {
        let categories = Set(entries.compactMap(\.category))
            .union(policy.channelHardLimitsUSD.keys)
            .union(policy.channelWarningLimitsUSD.keys)

        return categories.map { category in
            let categoryEntries = entries.filter { $0.category == category }
            return CompanyBudgetReport.ChannelUsage(
                category: category,
                estimatedUSD: spend(entries: categoryEntries, estimated: true),
                actualUSD: spend(entries: categoryEntries, estimated: false),
                warningLimitUSD: policy.channelWarningLimitsUSD[category],
                hardLimitUSD: policy.channelHardLimitsUSD[category].map { $0 + (channelIncreases[category] ?? 0) }
            )
        }
        .sorted { $0.category.rawValue < $1.category.rawValue }
    }

    private static func maxStatus(_ lhs: CompanyBudgetStatus, _ rhs: CompanyBudgetStatus) -> CompanyBudgetStatus {
        rank(rhs) > rank(lhs) ? rhs : lhs
    }

    private static func rank(_ status: CompanyBudgetStatus) -> Int {
        switch status {
        case .healthy: return 0
        case .warning: return 1
        case .hardStop: return 2
        case .emergencyShutdown: return 3
        }
    }
}
