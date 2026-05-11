import Foundation

struct CompanyRunner: Codable, Hashable, Identifiable {
    let id: String
    var label: String
    var maxConcurrentHeartbeats: Int
    var isAvailable: Bool

    static let local = CompanyRunner(
        id: CompanyScaleScheduler.localRunnerID,
        label: "This Mac",
        maxConcurrentHeartbeats: 3,
        isAvailable: true
    )
}

struct CompanySchedulerLimits: Codable, Hashable {
    var maxGlobalConcurrentHeartbeats: Int
    var maxQueuedCompaniesBeforeBackpressure: Int
    var maxFailedCompaniesBeforeBackpressure: Int

    static let productionDefault = CompanySchedulerLimits(
        maxGlobalConcurrentHeartbeats: 3,
        maxQueuedCompaniesBeforeBackpressure: 250,
        maxFailedCompaniesBeforeBackpressure: 50
    )
}

struct CompanyHeartbeatSchedulePlan: Codable, Hashable {
    var startNowIDs: [String]
    var queuedIDs: [String]
    var blockedIDs: [String]
    var pauseIDs: [String]
    var budgetWarningIDs: [String]
    var backpressureReasons: [String]
}

struct CompanyFleetStatus: Codable, Hashable {
    var total: Int
    var active: Int
    var queued: Int
    var blocked: Int
    var failed: Int
    var profitable: Int
    var paused: Int
    var idle: Int
    var runners: [String: Int]
    var budgetStatus: CompanyBudgetStatus
    var globalSpendUSD: Double
    var globalHardLimitUSD: Double
}

enum CompanyScaleScheduler {
    static let localRunnerID = "local-mac"

    static func plan(
        sessions: [CodexSession],
        now: Date,
        limits: CompanySchedulerLimits = .productionDefault,
        runners: [CompanyRunner] = [.local],
        ledgerSummaries: [String: CompanyLedgerSummary] = [:],
        profitabilityPolicy: CompanyProfitabilityPolicy = .productionDefault,
        budgetReports: [String: CompanyBudgetReport] = [:],
        portfolioProfiles: [String: CompanyPortfolioProfile] = [:],
        portfolioRules: CompanyPortfolioRules = .productionDefault,
        emergencyStop: CompanyEmergencyStop? = nil
    ) -> CompanyHeartbeatSchedulePlan {
        let activeCount = sessions.filter { $0.status == .running }.count
        let queuedCount = sessions.filter { $0.status == .queued }.count
        let failedCount = sessions.filter { $0.status == .failed }.count
        var backpressure: [String] = []
        let computedBudgetReports: [String: CompanyBudgetReport] = budgetReports.isEmpty
            ? Dictionary(uniqueKeysWithValues: sessions.compactMap { session in
                guard let summary = ledgerSummaries[session.id] else { return nil }
                return (
                    session.id,
                    CompanyBudgetGuardian.evaluate(
                        companyID: session.id,
                        ledger: summary,
                        budget: session.budget,
                        globalLedgerSummaries: Array(ledgerSummaries.values),
                        now: now
                    )
                )
            })
            : budgetReports
        let globalBudgetReport = CompanyBudgetGuardian.globalReport(summaries: Array(ledgerSummaries.values))
        let portfolioAllocations = portfolioProfiles.isEmpty
            ? [:]
            : CompanyPortfolioStrategyEngine.dashboard(
                profiles: Array(portfolioProfiles.values),
                rules: portfolioRules
            )
            .allocationByCompanyID

        if queuedCount > limits.maxQueuedCompaniesBeforeBackpressure {
            backpressure.append("queueDepth")
        }
        if failedCount > limits.maxFailedCompaniesBeforeBackpressure {
            backpressure.append("failureRate")
        }
        if globalBudgetReport.status == .warning {
            backpressure.append("globalBudgetWarning")
        } else if globalBudgetReport.shouldBlockHeartbeat {
            backpressure.append("globalBudgetHardStop")
        }
        if CompanyIncidentResponseEngine.shouldBlock(
            action: .companyHeartbeat,
            emergencyStop: emergencyStop,
            now: now
        ) {
            backpressure.append("emergencyStop")
        }

        var runnerCapacity = Dictionary(uniqueKeysWithValues: runners.map {
            ($0.id, $0.isAvailable ? max(0, $0.maxConcurrentHeartbeats) : 0)
        })
        for session in sessions where session.status == .running {
            runnerCapacity[session.assignedRunnerID, default: 0] = max(0, runnerCapacity[session.assignedRunnerID, default: 0] - 1)
        }

        var remainingGlobal = max(0, limits.maxGlobalConcurrentHeartbeats - activeCount)
        var start: [String] = []
        var queued: [String] = []
        var blocked: [String] = []
        var budgetWarningIDs: [String] = []
        let pauseIDs = sessions.compactMap { session -> String? in
            guard let summary = ledgerSummaries[session.id],
                  CompanyProfitabilityGuard.evaluate(summary: summary, policy: profitabilityPolicy).shouldPause
            else { return nil }
            return session.id
        }
        let pauseSet = Set(pauseIDs)

        let eligible = sessions
            .filter { $0.status == .idle || $0.status == .queued || $0.status == .blocked }
            .sorted { lhs, rhs in
                let lhsDate = lhs.nextHeartbeatAt ?? lhs.startedAt
                let rhsDate = rhs.nextHeartbeatAt ?? rhs.startedAt
                let lhsBudget = budgetPriority(computedBudgetReports[lhs.id])
                let rhsBudget = budgetPriority(computedBudgetReports[rhs.id])
                let lhsPortfolio = portfolioPriority(portfolioAllocations[lhs.id])
                let rhsPortfolio = portfolioPriority(portfolioAllocations[rhs.id])
                if lhsBudget != rhsBudget { return lhsBudget < rhsBudget }
                if lhsPortfolio != rhsPortfolio { return lhsPortfolio < rhsPortfolio }
                if lhsDate == rhsDate { return lhs.id < rhs.id }
                return lhsDate < rhsDate
            }

        for session in eligible {
            if portfolioAllocations[session.id]?.canStartHeartbeat == false {
                blocked.append(session.id)
                continue
            }

            if globalBudgetReport.shouldBlockHeartbeat {
                blocked.append(session.id)
                continue
            }

            if let report = computedBudgetReports[session.id] {
                if report.shouldBlockHeartbeat {
                    blocked.append(session.id)
                    continue
                }
                if report.isNearLimit {
                    budgetWarningIDs.append(session.id)
                }
            }

            if pauseSet.contains(session.id) {
                blocked.append(session.id)
                continue
            }

            if backpressure.isEmpty == false {
                queued.append(session.id)
                continue
            }

            if session.status == .blocked {
                blocked.append(session.id)
                continue
            }

            if let next = session.nextHeartbeatAt, next > now {
                queued.append(session.id)
                continue
            }

            if let budget = session.budget, budget.dailyHeartbeatCount >= budget.maxDailyHeartbeats {
                blocked.append(session.id)
                continue
            }

            guard remainingGlobal > 0 else {
                queued.append(session.id)
                continue
            }

            let runnerID = session.assignedRunnerID
            guard runnerCapacity[runnerID, default: 0] > 0 else {
                queued.append(session.id)
                continue
            }

            start.append(session.id)
            remainingGlobal -= 1
            runnerCapacity[runnerID, default: 0] = max(0, runnerCapacity[runnerID, default: 0] - 1)
        }

        return CompanyHeartbeatSchedulePlan(
            startNowIDs: start,
            queuedIDs: queued,
            blockedIDs: blocked,
            pauseIDs: pauseIDs,
            budgetWarningIDs: budgetWarningIDs,
            backpressureReasons: backpressure
        )
    }

    static func migrate(_ session: CodexSession, toRunnerID runnerID: String) -> CodexSession {
        var migrated = session
        migrated.assignedRunnerID = runnerID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? localRunnerID
            : runnerID.trimmingCharacters(in: .whitespacesAndNewlines)
        return migrated
    }

    static func fleetStatus(
        sessions: [CodexSession],
        profitableCompanyIDs: Set<String>,
        globalBudgetReport: CompanyBudgetReport? = nil
    ) -> CompanyFleetStatus {
        CompanyFleetStatus(
            total: sessions.count,
            active: sessions.filter { $0.status == .running }.count,
            queued: sessions.filter { $0.status == .queued }.count,
            blocked: sessions.filter { $0.status == .blocked }.count,
            failed: sessions.filter { $0.status == .failed }.count,
            profitable: sessions.filter { profitableCompanyIDs.contains($0.id) }.count,
            paused: sessions.filter { $0.status == .paused }.count,
            idle: sessions.filter { $0.status == .idle }.count,
            runners: sessions.reduce(into: [:]) { counts, session in
                counts[session.assignedRunnerID, default: 0] += 1
            },
            budgetStatus: globalBudgetReport?.status ?? .healthy,
            globalSpendUSD: globalBudgetReport?.globalSpendUSD ?? 0,
            globalHardLimitUSD: globalBudgetReport?.globalHardLimitUSD ?? CompanyBudgetPolicy.productionDefault.globalHardLimitUSD
        )
    }

    private static func budgetPriority(_ report: CompanyBudgetReport?) -> Int {
        guard let report else { return 0 }
        switch report.status {
        case .healthy: return 0
        case .warning: return 1
        case .hardStop: return 2
        case .emergencyShutdown: return 3
        }
    }

    private static func portfolioPriority(_ allocation: CompanyPortfolioAllocation?) -> Int {
        allocation?.rank ?? Int.max
    }
}
