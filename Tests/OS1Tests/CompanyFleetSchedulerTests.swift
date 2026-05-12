import Foundation
import Testing
@testable import OS1

struct CompanyFleetSchedulerTests {
    @Test
    func fleetSchedulerEnforcesPerVMCapAndQueuesOverflow() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessions = (0..<12).map { makeSession(id: "co-\($0)", nextHeartbeatAt: now.addingTimeInterval(-1)) }

        let plan = CompanyFleetScheduler.plan(
            sessions: sessions,
            now: now,
            runners: [CompanyRunner(id: "vm-1", label: "VM 1", maxConcurrentHeartbeats: 20, isAvailable: true)],
            maxConcurrentCompaniesPerVM: 5
        )

        #expect(plan.runningAssignments.count == 5)
        #expect(plan.queueDepth == 7)
        #expect(Set(plan.runningAssignments.map(\.runnerID)) == ["vm-1"])
    }

    @Test
    func fleetSchedulerStartsOldestCompaniesFirstToPreventStarvation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let newer = makeSession(id: "newer", nextHeartbeatAt: now.addingTimeInterval(-10))
        let older = makeSession(id: "older", nextHeartbeatAt: now.addingTimeInterval(-500))

        let plan = CompanyFleetScheduler.plan(
            sessions: [newer, older],
            now: now,
            runners: [CompanyRunner(id: "vm-1", label: "VM 1", maxConcurrentHeartbeats: 1, isAvailable: true)],
            maxConcurrentCompaniesPerVM: 1
        )

        #expect(plan.runningAssignments.map(\.companyID) == ["older"])
        #expect(plan.assignments.first { $0.companyID == "newer" }?.queued == true)
    }

    @Test
    func fleetSchedulerReportsRemovedVMsAndRepoolsToAvailableRunners() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var session = makeSession(id: "company", nextHeartbeatAt: now.addingTimeInterval(-1))
        session.assignedRunnerID = "removed-vm"

        let plan = CompanyFleetScheduler.plan(
            sessions: [session],
            now: now,
            runners: [CompanyRunner(id: "vm-2", label: "VM 2", maxConcurrentHeartbeats: 5, isAvailable: true)]
        )

        #expect(plan.removedRunnerIDs == ["removed-vm"])
        #expect(plan.runningAssignments.first?.runnerID == "vm-2")
    }

    @Test
    func fiftyCompaniesThroughOneVMWithCapFiveFinishesQuickly() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessions = (0..<50).map { makeSession(id: "co-\($0)", nextHeartbeatAt: now.addingTimeInterval(-1)) }
        let start = Date()

        let plan = CompanyFleetScheduler.plan(
            sessions: sessions,
            now: now,
            runners: [CompanyRunner(id: "vm-1", label: "VM 1", maxConcurrentHeartbeats: 5, isAvailable: true)],
            maxConcurrentCompaniesPerVM: 5
        )

        #expect(plan.runningAssignments.count == 5)
        #expect(plan.queueDepth == 45)
        #expect(Date().timeIntervalSince(start) < 0.25)
    }

    @Test
    func driftEvaluatorFlagsCompanyThatForgotMission() {
        let report = CompanyDriftEvaluator.evaluate(
            companyID: "co",
            mission: "Publish sourced roofing repair guides for Toronto homeowners",
            constitution: "Stay truthful and useful.",
            firstWeekBaseline: "roofing repair estimates homeowner leak guide",
            currentBehaviorTail: "Now posting generic crypto memes and celebrity news with no local service context.",
            ledger: CompanyLedgerSummary(entries: [
                CompanyLedgerEntry(
                    id: "ad",
                    companyID: "co",
                    occurredAt: nil,
                    kind: .cost,
                    category: .ads,
                    amountUSD: 50,
                    source: "manual",
                    confidence: .estimated,
                    note: "estimated spend"
                )
            ]),
            heartbeatCount: 25
        )

        #expect(report.driftDetected)
        #expect(report.findings.contains("missionForgotten"))
        #expect(report.event?.kind == .driftDetected)
    }

    private func makeSession(id: String, nextHeartbeatAt: Date?) -> CodexSession {
        var session = CodexSession(
            id: id,
            title: id,
            task: "run \(id)",
            worktreePath: "/tmp/\(id)",
            branch: "company/\(id)",
            status: .idle,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        session.nextHeartbeatAt = nextHeartbeatAt
        return session
    }
}
