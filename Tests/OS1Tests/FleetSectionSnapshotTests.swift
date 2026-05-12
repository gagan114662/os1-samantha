import Foundation
import Testing
@testable import OS1

struct FleetSectionSnapshotTests {
    @Test
    @MainActor
    func fleetSectionAndDoctorRowsRenderFixturePortfolio() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let runners = [
            CompanyRunner(id: CompanyScaleScheduler.localRunnerID, label: "This Mac", maxConcurrentHeartbeats: 5, isAvailable: true),
            CompanyRunner(id: "orgo-worker-1", label: "Orgo Worker 1", maxConcurrentHeartbeats: 5, isAvailable: true)
        ]
        let sessions = (0..<8).map { index -> CodexSession in
            var session = CodexSession(
                id: "co-\(index)",
                title: "Company \(index)",
                task: "run company \(index)",
                worktreePath: "/tmp/co-\(index)",
                branch: "company/co-\(index)",
                status: index < 4 ? .running : (index < 6 ? .queued : .idle),
                startedAt: now.addingTimeInterval(-10_000)
            )
            session.assignedRunnerID = index.isMultiple(of: 2) ? CompanyScaleScheduler.localRunnerID : "orgo-worker-1"
            session.lastHeartbeatAt = now.addingTimeInterval(-Double((index + 1) * 60))
            return session
        }
        let drift = CompanyEvent(
            occurredAt: now,
            companyID: "co-7",
            kind: .driftDetected,
            summary: "Company drift detected"
        )

        let snapshot = DoctorViewModel.fleetHealthSnapshot(
            sessions: sessions,
            events: [drift],
            runners: runners,
            now: now
        )

        #expect(FleetSection.renderedRows(snapshot: snapshot) == [
            "queueDepth=2",
            "drifting=1",
            "local-mac|local|2/5|co-0:60,co-2:180",
            "orgo-worker-1|orgo|2/5|co-1:120,co-3:240"
        ])
        #expect(DoctorViewModel.fleetDoctorRows(snapshot: snapshot) == [
            "Fleet capacity: 2 workers × cap 5 = 10 concurrent",
            "Companies flagged as drifting: 1"
        ])
    }
}
