import Foundation
import Testing
@testable import OS1

struct CompanyIncidentResponseTests {
    @Test
    func severityRulesAreConfigurableAndCreateEscalationPath() {
        let policy = CompanyIncidentPolicy(
            triggerSeverities: [.customerComplaint: .sev1],
            emergencyStopHaltSeconds: 15,
            onCallPrimary: "gagan",
            telegramEscalationChatID: "ops-chat"
        )

        let incident = CompanyIncidentResponseEngine.createIncident(
            trigger: .customerComplaint,
            summary: "customer reported bad outbound message",
            companyIDs: ["company"],
            policy: policy,
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(incident.severity == .sev1)
        #expect(incident.escalationPath.contains("on-call:gagan"))
        #expect(incident.escalationPath.contains("telegram:ops-chat"))
        #expect(incident.escalationPath.contains("global emergency stop"))
        #expect(incident.emergencyStop?.haltWithinSeconds == 15)
    }

    @Test
    func emergencyStopHaltsNewHighRiskActionsWithinBoundedTime() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stop = CompanyEmergencyStop.activeStop(
            activatedAt: now,
            activatedBy: "operator",
            reason: "runaway spend"
        )

        #expect(stop.blocks(.paymentAction, at: now))
        #expect(stop.haltDeadline() == now.addingTimeInterval(30))
        #expect(CompanyIncidentResponseEngine.shouldBlock(
            action: .browserAutomation,
            emergencyStop: stop,
            now: now.addingTimeInterval(1)
        ))
    }

    @Test
    func schedulerDoesNotStartHeartbeatsDuringEmergencyStop() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let stop = CompanyEmergencyStop.activeStop(
            activatedAt: now,
            activatedBy: "operator",
            reason: "data leak"
        )
        let plan = CompanyScaleScheduler.plan(
            sessions: [session(id: "company", now: now)],
            now: now,
            limits: CompanySchedulerLimits(
                maxGlobalConcurrentHeartbeats: 1,
                maxQueuedCompaniesBeforeBackpressure: 100,
                maxFailedCompaniesBeforeBackpressure: 100
            ),
            emergencyStop: stop
        )

        #expect(plan.startNowIDs.isEmpty)
        #expect(plan.queuedIDs == ["company"])
        #expect(plan.backpressureReasons.contains("emergencyStop"))
    }

    @Test
    func incidentsLinkEventsApprovalsCompaniesAndCustomers() {
        let event = CompanyEvent(
            id: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            companyID: "company",
            kind: .budgetBlocked,
            summary: "spend limit breached"
        )
        let incident = CompanyIncidentResponseEngine.createIncident(
            trigger: .runawaySpend,
            summary: "runaway spend",
            companyIDs: ["company"],
            customerRefs: ["cust_123"],
            relatedEvents: [event],
            approvalRequestIDs: ["approval-1"],
            now: Date(timeIntervalSince1970: 1_800_000_001)
        )

        #expect(incident.companyIDs == ["company"])
        #expect(incident.customerRefs == ["cust_123"])
        #expect(incident.relatedEventIDs == [event.id])
        #expect(incident.approvalRequestIDs == ["approval-1"])
        #expect(incident.emergencyStop != nil)
    }

    @Test
    func postmortemFollowUpsCreateGitHubIssueDrafts() {
        let incident = CompanyIncidentResponseEngine.createIncident(
            trigger: .providerOutage,
            summary: "provider outage",
            companyIDs: ["company"],
            now: Date(timeIntervalSince1970: 1_800_000_000)
        )
        let postmortem = CompanyIncidentResponseEngine.postmortem(
            incident: incident,
            timeline: ["10:00 outage detected", "10:05 traffic paused"],
            rootCause: "single provider dependency",
            impact: "heartbeats delayed",
            fixes: ["route to backup provider"],
            followUps: ["add provider canary", "document failover drill"]
        )

        #expect(postmortem.githubIssueDrafts.count == 2)
        #expect(postmortem.githubIssueDrafts[0].title.contains("add provider canary"))
        #expect(postmortem.githubIssueDrafts[0].labels.contains("incident-response"))
    }

    private func session(id: String, now: Date) -> CodexSession {
        var session = CodexSession(
            id: id,
            title: id,
            task: "run \(id)",
            worktreePath: "/tmp/\(id)",
            branch: "company/\(id)",
            status: .idle,
            startedAt: now.addingTimeInterval(-100)
        )
        session.nextHeartbeatAt = now.addingTimeInterval(-1)
        session.budget = .defaultState(now: now)
        return session
    }
}
