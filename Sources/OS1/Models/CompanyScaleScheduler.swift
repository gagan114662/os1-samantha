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
}

enum CompanyScaleScheduler {
    static let localRunnerID = "local-mac"

    static func plan(
        sessions: [CodexSession],
        now: Date,
        limits: CompanySchedulerLimits = .productionDefault,
        runners: [CompanyRunner] = [.local]
    ) -> CompanyHeartbeatSchedulePlan {
        let activeCount = sessions.filter { $0.status == .running }.count
        let queuedCount = sessions.filter { $0.status == .queued }.count
        let failedCount = sessions.filter { $0.status == .failed }.count
        var backpressure: [String] = []

        if queuedCount > limits.maxQueuedCompaniesBeforeBackpressure {
            backpressure.append("queueDepth")
        }
        if failedCount > limits.maxFailedCompaniesBeforeBackpressure {
            backpressure.append("failureRate")
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

        let eligible = sessions
            .filter { $0.status == .idle || $0.status == .queued || $0.status == .blocked }
            .sorted { lhs, rhs in
                (lhs.nextHeartbeatAt ?? lhs.startedAt) < (rhs.nextHeartbeatAt ?? rhs.startedAt)
            }

        for session in eligible {
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
        profitableCompanyIDs: Set<String>
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
            }
        )
    }
}
