import Foundation

enum CompanyIncidentSeverity: String, Codable, CaseIterable, Hashable, Comparable {
    case sev4
    case sev3
    case sev2
    case sev1

    static func < (lhs: CompanyIncidentSeverity, rhs: CompanyIncidentSeverity) -> Bool {
        order(lhs) < order(rhs)
    }

    private static func order(_ severity: CompanyIncidentSeverity) -> Int {
        switch severity {
        case .sev4: return 0
        case .sev3: return 1
        case .sev2: return 2
        case .sev1: return 3
        }
    }
}

enum CompanyIncidentTrigger: String, Codable, CaseIterable, Hashable {
    case policyBreach
    case runawaySpend
    case suspiciousAutomation
    case customerComplaint
    case dataLeak
    case providerOutage
    case reputationBan
    case paymentDisputeSpike
}

enum CompanyHighRiskAction: String, Codable, CaseIterable, Hashable {
    case companyHeartbeat
    case browserAutomation
    case outboundCampaign
    case paymentAction
    case credentialAccess
    case externalSideEffect
}

struct CompanyIncidentPolicy: Codable, Hashable {
    var triggerSeverities: [CompanyIncidentTrigger: CompanyIncidentSeverity]
    var emergencyStopHaltSeconds: TimeInterval
    var onCallPrimary: String
    var telegramEscalationChatID: String?

    static let productionDefault = CompanyIncidentPolicy(
        triggerSeverities: [
            .policyBreach: .sev2,
            .runawaySpend: .sev1,
            .suspiciousAutomation: .sev2,
            .customerComplaint: .sev3,
            .dataLeak: .sev1,
            .providerOutage: .sev2,
            .reputationBan: .sev2,
            .paymentDisputeSpike: .sev2
        ],
        emergencyStopHaltSeconds: 30,
        onCallPrimary: "operator",
        telegramEscalationChatID: nil
    )
}

struct CompanyEmergencyStop: Codable, Hashable, Identifiable {
    var id: String
    var activatedAt: Date
    var activatedBy: String
    var reason: String
    var active: Bool
    var haltWithinSeconds: TimeInterval
    var blockedActions: Set<CompanyHighRiskAction>

    static func activeStop(
        id: String = "global-emergency-stop",
        activatedAt: Date,
        activatedBy: String,
        reason: String,
        policy: CompanyIncidentPolicy = .productionDefault
    ) -> CompanyEmergencyStop {
        CompanyEmergencyStop(
            id: id,
            activatedAt: activatedAt,
            activatedBy: activatedBy,
            reason: reason,
            active: true,
            haltWithinSeconds: policy.emergencyStopHaltSeconds,
            blockedActions: Set(CompanyHighRiskAction.allCases)
        )
    }

    func blocks(_ action: CompanyHighRiskAction, at now: Date) -> Bool {
        active && now >= activatedAt && blockedActions.contains(action)
    }

    func haltDeadline() -> Date {
        activatedAt.addingTimeInterval(haltWithinSeconds)
    }
}

struct CompanyIncidentRecord: Codable, Hashable, Identifiable {
    var id: String
    var createdAt: Date
    var severity: CompanyIncidentSeverity
    var trigger: CompanyIncidentTrigger
    var status: Status
    var summary: String
    var companyIDs: [String]
    var customerRefs: [String]
    var relatedEventIDs: [UUID]
    var approvalRequestIDs: [String]
    var escalationPath: [String]
    var emergencyStop: CompanyEmergencyStop?
    var metadata: [String: String]

    enum Status: String, Codable, CaseIterable, Hashable {
        case open
        case mitigated
        case resolved
    }
}

struct CompanyPostmortem: Codable, Hashable, Identifiable {
    var id: String
    var incidentID: String
    var timeline: [String]
    var rootCause: String
    var impact: String
    var fixes: [String]
    var followUps: [String]

    var githubIssueDrafts: [CompanyGitHubIssueDraft] {
        followUps.enumerated().map { index, followUp in
            CompanyGitHubIssueDraft(
                title: "Incident \(incidentID) follow-up \(index + 1): \(followUp)",
                body: """
                ## Incident
                \(incidentID)

                ## Follow-up
                \(followUp)

                ## Root cause
                \(rootCause)

                ## Impact
                \(impact)
                """,
                labels: ["incident-response", "follow-up"]
            )
        }
    }
}

struct CompanyGitHubIssueDraft: Codable, Hashable {
    var title: String
    var body: String
    var labels: [String]
}

enum CompanyIncidentResponseEngine {
    static func createIncident(
        trigger: CompanyIncidentTrigger,
        summary: String,
        companyIDs: [String],
        customerRefs: [String] = [],
        relatedEvents: [CompanyEvent] = [],
        approvalRequestIDs: [String] = [],
        policy: CompanyIncidentPolicy = .productionDefault,
        now: Date = Date()
    ) -> CompanyIncidentRecord {
        let severity = policy.triggerSeverities[trigger] ?? .sev3
        let emergencyStop = severity >= .sev2
            ? CompanyEmergencyStop.activeStop(
                activatedAt: now,
                activatedBy: "os1",
                reason: summary,
                policy: policy
            )
            : nil
        return CompanyIncidentRecord(
            id: incidentID(trigger: trigger, now: now),
            createdAt: now,
            severity: severity,
            trigger: trigger,
            status: .open,
            summary: summary,
            companyIDs: companyIDs.sorted(),
            customerRefs: customerRefs.sorted(),
            relatedEventIDs: relatedEvents.map(\.id).sorted { $0.uuidString < $1.uuidString },
            approvalRequestIDs: approvalRequestIDs.sorted(),
            escalationPath: escalationPath(severity: severity, policy: policy),
            emergencyStop: emergencyStop,
            metadata: ["haltWithinSeconds": "\(Int(policy.emergencyStopHaltSeconds))"]
        )
    }

    static func shouldBlock(
        action: CompanyHighRiskAction,
        emergencyStop: CompanyEmergencyStop?,
        now: Date = Date()
    ) -> Bool {
        emergencyStop?.blocks(action, at: now) == true
    }

    static func postmortem(
        incident: CompanyIncidentRecord,
        timeline: [String],
        rootCause: String,
        impact: String,
        fixes: [String],
        followUps: [String]
    ) -> CompanyPostmortem {
        CompanyPostmortem(
            id: "postmortem-\(incident.id)",
            incidentID: incident.id,
            timeline: timeline,
            rootCause: rootCause,
            impact: impact,
            fixes: fixes,
            followUps: followUps
        )
    }

    private static func escalationPath(
        severity: CompanyIncidentSeverity,
        policy: CompanyIncidentPolicy
    ) -> [String] {
        var path = ["OS1 incident console", "on-call:\(policy.onCallPrimary)"]
        if severity >= .sev2, let chat = policy.telegramEscalationChatID {
            path.append("telegram:\(chat)")
        }
        if severity == .sev1 {
            path.append("global emergency stop")
        }
        return path
    }

    private static func incidentID(trigger: CompanyIncidentTrigger, now: Date) -> String {
        "incident-\(trigger.rawValue)-\(Int(now.timeIntervalSince1970))"
    }
}
