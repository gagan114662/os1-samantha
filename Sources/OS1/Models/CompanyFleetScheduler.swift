import Foundation

struct CompanyFleetAssignment: Codable, Hashable, Identifiable {
    var id: String { companyID }
    var companyID: String
    var runnerID: String
    var started: Bool
    var queued: Bool
}

struct CompanyFleetPlan: Codable, Hashable {
    var assignments: [CompanyFleetAssignment]
    var queueDepth: Int
    var removedRunnerIDs: [String]
    var capacity: Int

    var runningAssignments: [CompanyFleetAssignment] {
        assignments.filter(\.started)
    }
}

enum CompanyFleetScheduler {
    static let localSandboxRunner = CompanyRunner(
        id: "local-sandbox",
        label: "Local sandbox",
        maxConcurrentHeartbeats: 5,
        isAvailable: true
    )

    static func plan(
        sessions: [CodexSession],
        now: Date,
        runners: [CompanyRunner],
        maxConcurrentCompaniesPerVM: Int = 5
    ) -> CompanyFleetPlan {
        let normalizedRunners = runners.isEmpty ? [localSandboxRunner] : runners.map { runner in
            CompanyRunner(
                id: runner.id,
                label: runner.label,
                maxConcurrentHeartbeats: min(runner.maxConcurrentHeartbeats, maxConcurrentCompaniesPerVM),
                isAvailable: runner.isAvailable
            )
        }
        let availableRunnerIDs = Set(normalizedRunners.filter(\.isAvailable).map(\.id))
        let removedRunnerIDs = Array(Set(sessions.map(\.assignedRunnerID)).subtracting(availableRunnerIDs)).sorted()
        let available = normalizedRunners.filter(\.isAvailable).sorted { $0.id < $1.id }
        var capacity = Dictionary(uniqueKeysWithValues: available.map { ($0.id, $0.maxConcurrentHeartbeats) })
        for running in sessions where running.status == .running && availableRunnerIDs.contains(running.assignedRunnerID) {
            capacity[running.assignedRunnerID, default: 0] = max(0, capacity[running.assignedRunnerID, default: 0] - 1)
        }

        let ready = sessions
            .filter { $0.status == .idle || $0.status == .queued || $0.status == .blocked }
            .filter { ($0.nextHeartbeatAt ?? .distantPast) <= now }
            .sorted { lhs, rhs in
                let lhsDate = lhs.nextHeartbeatAt ?? lhs.startedAt
                let rhsDate = rhs.nextHeartbeatAt ?? rhs.startedAt
                if lhsDate == rhsDate { return lhs.id < rhs.id }
                return lhsDate < rhsDate
            }

        var assignments: [CompanyFleetAssignment] = []
        for session in ready {
            guard let runner = available.first(where: { capacity[$0.id, default: 0] > 0 }) else {
                assignments.append(.init(companyID: session.id, runnerID: session.assignedRunnerID, started: false, queued: true))
                continue
            }
            capacity[runner.id, default: 0] -= 1
            assignments.append(.init(companyID: session.id, runnerID: runner.id, started: true, queued: false))
        }

        return CompanyFleetPlan(
            assignments: assignments,
            queueDepth: assignments.filter(\.queued).count,
            removedRunnerIDs: removedRunnerIDs,
            capacity: normalizedRunners.filter(\.isAvailable).map(\.maxConcurrentHeartbeats).reduce(0, +)
        )
    }
}

struct CompanyDriftReport: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var driftDetected: Bool
    var missionOverlap: Double
    var baselineOverlap: Double
    var revenueTrajectoryRisk: Bool
    var findings: [String]
    var event: CompanyEvent?
}

enum CompanyDriftEvaluator {
    static let defaultCadenceHeartbeats = 25

    static func evaluate(
        companyID: String,
        mission: String,
        constitution: String,
        firstWeekBaseline: String,
        currentBehaviorTail: String,
        ledger: CompanyLedgerSummary,
        heartbeatCount: Int,
        cadenceHeartbeats: Int = defaultCadenceHeartbeats,
        now: Date = Date()
    ) -> CompanyDriftReport {
        guard cadenceHeartbeats > 0, heartbeatCount % cadenceHeartbeats == 0 else {
            return CompanyDriftReport(
                id: "\(companyID)-drift-\(heartbeatCount)",
                companyID: companyID,
                driftDetected: false,
                missionOverlap: 1,
                baselineOverlap: 1,
                revenueTrajectoryRisk: false,
                findings: [],
                event: nil
            )
        }

        let behavior = "\(constitution) \(currentBehaviorTail)"
        let missionOverlap = overlap(mission, behavior)
        let baselineOverlap = overlap(firstWeekBaseline, currentBehaviorTail)
        let revenueRisk = ledger.costUSD > 0 && ledger.verifiedRevenueUSD == 0 && ledger.estimatedEntryCount > ledger.verifiedEntryCount
        var findings: [String] = []
        if missionOverlap < 0.18 { findings.append("missionForgotten") }
        if baselineOverlap < 0.12 { findings.append("firstWeekBaselineDrift") }
        if revenueRisk { findings.append("revenueCostTrajectoryDrift") }
        let detected = !findings.isEmpty
        let event = detected ? CompanyEvent(
            occurredAt: now,
            companyID: companyID,
            kind: .driftDetected,
            summary: "Company drift detected: \(findings.joined(separator: ","))",
            riskTier: "medium",
            metadata: [
                "missionOverlap": String(format: "%.3f", missionOverlap),
                "baselineOverlap": String(format: "%.3f", baselineOverlap),
                "findings": findings.joined(separator: ",")
            ]
        ) : nil
        return CompanyDriftReport(
            id: "\(companyID)-drift-\(heartbeatCount)",
            companyID: companyID,
            driftDetected: detected,
            missionOverlap: missionOverlap,
            baselineOverlap: baselineOverlap,
            revenueTrajectoryRisk: revenueRisk,
            findings: findings.sorted(),
            event: event
        )
    }

    private static func overlap(_ lhs: String, _ rhs: String) -> Double {
        let a = tokens(lhs)
        let b = tokens(rhs)
        guard !a.isEmpty else { return 1 }
        return Double(a.intersection(b).count) / Double(a.count)
    }

    private static func tokens(_ value: String) -> Set<String> {
        Set(value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 3 })
    }
}
