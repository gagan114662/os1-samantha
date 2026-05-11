import Foundation
import Testing
@testable import OS1

struct CompanyScaleSchedulerTests {
    @Test
    func loadPlannerHandlesHundredsOfCompaniesWithoutStartingTooMany() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        for count in [100, 250, 500] {
            let sessions = (0..<count).map { index in
                makeSession(id: "c\(index)", status: .idle, nextHeartbeatAt: now.addingTimeInterval(-1))
            }
            let start = Date()
            let plan = CompanyScaleScheduler.plan(
                sessions: sessions,
                now: now,
                limits: CompanySchedulerLimits(
                    maxGlobalConcurrentHeartbeats: 7,
                    maxQueuedCompaniesBeforeBackpressure: 1_000,
                    maxFailedCompaniesBeforeBackpressure: 1_000
                ),
                runners: [
                    CompanyRunner(id: CompanyScaleScheduler.localRunnerID, label: "local", maxConcurrentHeartbeats: 7, isAvailable: true)
                ]
            )

            #expect(plan.startNowIDs.count == 7)
            #expect(plan.queuedIDs.count == count - 7)
            #expect(plan.blockedIDs.isEmpty)
            #expect(Date().timeIntervalSince(start) < 0.5)
        }
    }

    @Test
    func schedulerEnforcesGlobalRunnerAndPerCompanyQuotas() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var budgetExhausted = makeSession(id: "budget", status: .idle, nextHeartbeatAt: now.addingTimeInterval(-1))
        budgetExhausted.budget = CodexSession.BudgetState(
            dailyWindowStart: now,
            dailyHeartbeatCount: 2,
            maxDailyHeartbeats: 2,
            maxHeartbeatsWithoutRevenueSignal: 10
        )
        let sessions = [
            makeSession(id: "running", status: .running, nextHeartbeatAt: nil),
            makeSession(id: "ready-a", status: .idle, nextHeartbeatAt: now.addingTimeInterval(-1)),
            makeSession(id: "ready-b", status: .idle, nextHeartbeatAt: now.addingTimeInterval(-1)),
            budgetExhausted
        ]

        let plan = CompanyScaleScheduler.plan(
            sessions: sessions,
            now: now,
            limits: CompanySchedulerLimits(
                maxGlobalConcurrentHeartbeats: 2,
                maxQueuedCompaniesBeforeBackpressure: 100,
                maxFailedCompaniesBeforeBackpressure: 100
            ),
            runners: [
                CompanyRunner(id: CompanyScaleScheduler.localRunnerID, label: "local", maxConcurrentHeartbeats: 2, isAvailable: true)
            ]
        )

        #expect(plan.startNowIDs == ["ready-a"])
        #expect(plan.queuedIDs == ["ready-b"])
        #expect(plan.blockedIDs == ["budget"])
    }

    @Test
    func backpressureStopsNewStartsWhenQueueOrFailuresAreTooHigh() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessions = [
            makeSession(id: "q1", status: .queued, nextHeartbeatAt: now.addingTimeInterval(-1)),
            makeSession(id: "q2", status: .queued, nextHeartbeatAt: now.addingTimeInterval(-1)),
            makeSession(id: "f1", status: .failed, nextHeartbeatAt: nil),
            makeSession(id: "ready", status: .idle, nextHeartbeatAt: now.addingTimeInterval(-1))
        ]

        let plan = CompanyScaleScheduler.plan(
            sessions: sessions,
            now: now,
            limits: CompanySchedulerLimits(
                maxGlobalConcurrentHeartbeats: 10,
                maxQueuedCompaniesBeforeBackpressure: 1,
                maxFailedCompaniesBeforeBackpressure: 0
            )
        )

        #expect(plan.startNowIDs.isEmpty)
        #expect(plan.queuedIDs.contains("ready"))
        #expect(plan.backpressureReasons.contains("queueDepth"))
        #expect(plan.backpressureReasons.contains("failureRate"))
    }

    @Test
    func companyCanMigrateBetweenRunnersWithoutLosingState() {
        var session = makeSession(id: "company", status: .blocked, nextHeartbeatAt: nil)
        session.heartbeatCount = 12
        session.pendingUserInstruction = "fix pricing"
        session.credentialAllowlist = ["STRIPE_API_KEY"]
        session.blockedReason = "approval required"

        let migrated = CompanyScaleScheduler.migrate(session, toRunnerID: "orgo-runner-2")

        #expect(migrated.assignedRunnerID == "orgo-runner-2")
        #expect(migrated.id == session.id)
        #expect(migrated.worktreePath == session.worktreePath)
        #expect(migrated.journalPath == session.journalPath)
        #expect(migrated.ledgerPath == session.ledgerPath)
        #expect(migrated.heartbeatCount == 12)
        #expect(migrated.pendingUserInstruction == "fix pricing")
        #expect(migrated.credentialAllowlist == ["STRIPE_API_KEY"])
        #expect(migrated.blockedReason == "approval required")
    }

    @Test
    func fleetStatusCountsActiveQueuedBlockedFailedAndProfitableCompanies() {
        let sessions = [
            makeSession(id: "active", status: .running, nextHeartbeatAt: nil),
            makeSession(id: "queued", status: .queued, nextHeartbeatAt: nil),
            makeSession(id: "blocked", status: .blocked, nextHeartbeatAt: nil),
            makeSession(id: "failed", status: .failed, nextHeartbeatAt: nil),
            makeSession(id: "profit", status: .idle, nextHeartbeatAt: nil)
        ]

        let status = CompanyScaleScheduler.fleetStatus(
            sessions: sessions,
            profitableCompanyIDs: ["profit"]
        )

        #expect(status.total == 5)
        #expect(status.active == 1)
        #expect(status.queued == 1)
        #expect(status.blocked == 1)
        #expect(status.failed == 1)
        #expect(status.profitable == 1)
        #expect(status.runners[CompanyScaleScheduler.localRunnerID] == 5)
    }

    private func makeSession(
        id: String,
        status: CodexSession.Status,
        nextHeartbeatAt: Date?
    ) -> CodexSession {
        var session = CodexSession(
            id: id,
            title: id,
            task: "run \(id)",
            worktreePath: "/tmp/\(id)",
            branch: "company/\(id)",
            status: status,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        session.nextHeartbeatAt = nextHeartbeatAt
        session.budget = .defaultState(now: Date(timeIntervalSince1970: 1_700_000_000))
        return session
    }
}
