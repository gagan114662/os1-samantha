import Foundation

struct CompanyFleetHealthSnapshot: Codable, Hashable, Sendable {
    struct ActiveCompany: Codable, Hashable, Identifiable, Sendable {
        var id: String { companyID }
        var companyID: String
        var title: String
        var lastHeartbeatLatencySeconds: Int?
    }

    struct Worker: Codable, Hashable, Identifiable, Sendable {
        var id: String { workerID }
        var workerID: String
        var kind: String
        var runningCount: Int
        var cap: Int
        var activeCompanies: [ActiveCompany]
    }

    var workers: [Worker]
    var queueDepth: Int
    var driftingCompanyCount: Int

    var activeWorkers: Int {
        workers.filter { $0.cap > 0 }.count
    }

    var perWorkerCap: Int {
        workers.map(\.cap).max() ?? CompanyFleetHealthSnapshot.defaultPerWorkerCap
    }

    var totalConcurrentCapacity: Int {
        workers.map(\.cap).reduce(0, +)
    }

    static let defaultPerWorkerCap = 5
    static let empty = CompanyFleetHealthSnapshot(workers: [], queueDepth: 0, driftingCompanyCount: 0)

    static func make(
        sessions: [CodexSession],
        runners: [CompanyRunner] = [.local],
        driftFlaggedCompanyIDs: Set<String> = [],
        now: Date = Date(),
        defaultPerWorkerCap: Int = Self.defaultPerWorkerCap
    ) -> CompanyFleetHealthSnapshot {
        let configured = runners.isEmpty ? [.local] : runners
        let configuredByID = Dictionary(uniqueKeysWithValues: configured.map { ($0.id, $0) })
        let workerIDs = Set(configured.map(\.id))
            .union(sessions.map(\.assignedRunnerID))
            .sorted()

        let workers = workerIDs.map { workerID in
            let configuredRunner = configuredByID[workerID]
            let runningSessions = sessions
                .filter { $0.assignedRunnerID == workerID && $0.status == .running }
                .sorted { $0.id < $1.id }
            return Worker(
                workerID: workerID,
                kind: workerKind(workerID),
                runningCount: runningSessions.count,
                cap: configuredRunner?.maxConcurrentHeartbeats ?? defaultPerWorkerCap,
                activeCompanies: runningSessions.map { session in
                    ActiveCompany(
                        companyID: session.id,
                        title: session.title,
                        lastHeartbeatLatencySeconds: session.lastHeartbeatAt.map {
                            max(0, Int(now.timeIntervalSince($0)))
                        }
                    )
                }
            )
        }

        return CompanyFleetHealthSnapshot(
            workers: workers,
            queueDepth: sessions.filter { $0.status == .queued }.count,
            driftingCompanyCount: sessions.filter { driftFlaggedCompanyIDs.contains($0.id) }.count
        )
    }

    static func workerKind(_ workerID: String) -> String {
        workerID == CompanyScaleScheduler.localRunnerID ? "local" : "orgo"
    }

    static func driftFlaggedCompanyIDs(from events: [CompanyEvent]) -> Set<String> {
        Set(events.compactMap { event in
            event.kind == .driftDetected ? event.companyID : nil
        })
    }
}
