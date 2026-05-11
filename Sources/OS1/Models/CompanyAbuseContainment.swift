import Foundation

struct CompanyAbusePolicy: Codable, Hashable {
    var maxSingleEventSpendUSD: Double
    var maxMessagesPerMinute: Int
    var maxProviderErrorsPerWindow: Int
    var suspiciousPathPrefixes: [String]

    static let productionDefault = CompanyAbusePolicy(
        maxSingleEventSpendUSD: 100,
        maxMessagesPerMinute: 40,
        maxProviderErrorsPerWindow: 10,
        suspiciousPathPrefixes: ["/etc", "/var/db", "/Users/*/.ssh", "/Users/*/.aws"]
    )
}

struct CompanyAbuseAnomaly: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case runawaySpend
        case messageSpam
        case unauthorizedSecretAccess
        case unusualFilesystemAccess
        case providerErrorBurst
        case loginAttemptBurst
    }

    var id: String
    var companyID: String
    var kind: Kind
    var severity: CompanyIdea.RiskTier
    var eventIDs: [UUID]
    var summary: String
    var detectedAt: Date
}

struct CompanyAbuseIncident: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var anomalyIDs: [String]
    var createdAt: Date
    var summary: String
    var quarantinePlan: CompanyAbuseQuarantinePlan
}

struct CompanyAbuseQuarantinePlan: Codable, Hashable {
    var companyID: String
    var quarantineCompanyOnly: Bool
    var credentialNames: [String]
    var browserSessionIDs: [String]
    var runnerIDs: [String]
    var blockedActions: [String]
    var revocationSteps: [String]

    var fleetWideStopRequired: Bool {
        !quarantineCompanyOnly
    }
}

struct CompanyAbuseAuditSnapshot: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var capturedAt: Date
    var eventIDs: [UUID]
    var immutableHash: String
    var notes: [String]
}

enum CompanyAbuseContainmentEngine {
    static func detect(
        events: [CompanyEvent],
        allowedCredentialsByCompany: [String: Set<String>] = [:],
        policy: CompanyAbusePolicy = .productionDefault,
        now: Date = Date()
    ) -> [CompanyAbuseAnomaly] {
        let spend = spendAnomalies(events: events, policy: policy, now: now)
        let messages = messageAnomalies(events: events, policy: policy, now: now)
        let secrets = secretAnomalies(
            events: events,
            allowedCredentialsByCompany: allowedCredentialsByCompany,
            now: now
        )
        let filesystem = filesystemAnomalies(events: events, policy: policy, now: now)
        let provider = providerErrorAnomalies(events: events, policy: policy, now: now)
        return (spend + messages + secrets + filesystem + provider).sorted { $0.id < $1.id }
    }

    static func incidents(
        for anomalies: [CompanyAbuseAnomaly],
        now: Date = Date()
    ) -> [CompanyAbuseIncident] {
        Dictionary(grouping: anomalies, by: \.companyID).map { companyID, items in
            CompanyAbuseIncident(
                id: "abuse-incident-\(companyID)-\(Int(now.timeIntervalSince1970))",
                companyID: companyID,
                anomalyIDs: items.map(\.id).sorted(),
                createdAt: now,
                summary: "Abuse containment triggered for \(items.map(\.kind.rawValue).joined(separator: ","))",
                quarantinePlan: quarantinePlan(companyID: companyID, anomalies: items)
            )
        }
        .sorted { $0.companyID < $1.companyID }
    }

    static func quarantinePlan(
        companyID: String,
        anomalies: [CompanyAbuseAnomaly],
        credentialNames: [String] = [],
        browserSessionIDs: [String] = [],
        runnerIDs: [String] = []
    ) -> CompanyAbuseQuarantinePlan {
        let includesSecretMisuse = anomalies.contains { $0.kind == .unauthorizedSecretAccess }
        let credentials = includesSecretMisuse
            ? Array(Set(credentialNames + ["all company-scoped credentials"])).sorted()
            : credentialNames.sorted()
        return CompanyAbuseQuarantinePlan(
            companyID: companyID,
            quarantineCompanyOnly: true,
            credentialNames: credentials,
            browserSessionIDs: browserSessionIDs.sorted(),
            runnerIDs: runnerIDs.sorted(),
            blockedActions: ["heartbeats", "browser automation", "outbound sends", "payments"],
            revocationSteps: revocationRunbook(credentialNames: credentials)
        )
    }

    static func auditSnapshot(
        companyID: String,
        events: [CompanyEvent],
        now: Date = Date(),
        notes: [String] = []
    ) -> CompanyAbuseAuditSnapshot {
        let canonical = events
            .sorted { $0.id.uuidString < $1.id.uuidString }
            .map { "\($0.id.uuidString)|\($0.kind.rawValue)|\($0.summary)|\($0.metadata.sorted { $0.key < $1.key })" }
            .joined(separator: "\n")
        return CompanyAbuseAuditSnapshot(
            id: "abuse-audit-\(companyID)-\(Int(now.timeIntervalSince1970))",
            companyID: companyID,
            capturedAt: now,
            eventIDs: events.map(\.id).sorted { $0.uuidString < $1.uuidString },
            immutableHash: CompanyEvent.inputHash(for: canonical),
            notes: notes
        )
    }

    static func revocationRunbook(credentialNames: [String]) -> [String] {
        let names = credentialNames.isEmpty ? ["affected credential"] : credentialNames
        return [
            "Pause the company and block heartbeats before touching credentials.",
            "Revoke \(names.joined(separator: ", ")) at the provider dashboard.",
            "Remove the credential from the company allowlist and local grant files.",
            "Rotate replacement keys only after audit snapshot review.",
            "Record revocation evidence in the incident timeline."
        ]
    }

    private static func spendAnomalies(
        events: [CompanyEvent],
        policy: CompanyAbusePolicy,
        now: Date
    ) -> [CompanyAbuseAnomaly] {
        events.compactMap { event in
            guard let companyID = event.companyID,
                  event.costUSD ?? 0 >= policy.maxSingleEventSpendUSD
            else { return nil }
            return anomaly(
                companyID: companyID,
                kind: .runawaySpend,
                eventIDs: [event.id],
                summary: "Spend spike \(event.costUSD ?? 0) exceeded policy",
                now: now
            )
        }
    }

    private static func messageAnomalies(
        events: [CompanyEvent],
        policy: CompanyAbusePolicy,
        now: Date
    ) -> [CompanyAbuseAnomaly] {
        events.compactMap { event in
            guard let companyID = event.companyID,
                  let count = Int(event.metadata["messagesSent"] ?? ""),
                  count >= policy.maxMessagesPerMinute
            else { return nil }
            return anomaly(
                companyID: companyID,
                kind: .messageSpam,
                eventIDs: [event.id],
                summary: "Message burst \(count)/minute exceeded policy",
                now: now
            )
        }
    }

    private static func secretAnomalies(
        events: [CompanyEvent],
        allowedCredentialsByCompany: [String: Set<String>],
        now: Date
    ) -> [CompanyAbuseAnomaly] {
        events.compactMap { event in
            guard event.kind == .secretAccessed,
                  let companyID = event.companyID,
                  let credential = event.metadata["credentialName"]
            else { return nil }
            let allowed = allowedCredentialsByCompany[companyID, default: []]
            guard !allowed.contains(credential) else { return nil }
            return anomaly(
                companyID: companyID,
                kind: .unauthorizedSecretAccess,
                eventIDs: [event.id],
                summary: "Unauthorized credential access attempted for \(credential)",
                now: now
            )
        }
    }

    private static func filesystemAnomalies(
        events: [CompanyEvent],
        policy: CompanyAbusePolicy,
        now: Date
    ) -> [CompanyAbuseAnomaly] {
        events.compactMap { event in
            guard let companyID = event.companyID,
                  let path = event.metadata["path"],
                  policy.suspiciousPathPrefixes.contains(where: { matches(path: path, prefix: $0) })
            else { return nil }
            return anomaly(
                companyID: companyID,
                kind: .unusualFilesystemAccess,
                eventIDs: [event.id],
                summary: "Suspicious filesystem access: \(path)",
                now: now
            )
        }
    }

    private static func providerErrorAnomalies(
        events: [CompanyEvent],
        policy: CompanyAbusePolicy,
        now: Date
    ) -> [CompanyAbuseAnomaly] {
        let grouped = Dictionary(grouping: events) { $0.companyID ?? "" }
        return grouped.compactMap { companyID, companyEvents in
            guard !companyID.isEmpty else { return nil }
            let errors = companyEvents.filter { $0.metadata["providerError"] == "true" }
            guard errors.count >= policy.maxProviderErrorsPerWindow else { return nil }
            return anomaly(
                companyID: companyID,
                kind: .providerErrorBurst,
                eventIDs: errors.map(\.id),
                summary: "Provider error burst \(errors.count) exceeded policy",
                now: now
            )
        }
    }

    private static func anomaly(
        companyID: String,
        kind: CompanyAbuseAnomaly.Kind,
        eventIDs: [UUID],
        summary: String,
        now: Date
    ) -> CompanyAbuseAnomaly {
        CompanyAbuseAnomaly(
            id: "anomaly-\(companyID)-\(kind.rawValue)",
            companyID: companyID,
            kind: kind,
            severity: kind == .unauthorizedSecretAccess ? .critical : .high,
            eventIDs: eventIDs.sorted { $0.uuidString < $1.uuidString },
            summary: summary,
            detectedAt: now
        )
    }

    private static func matches(path: String, prefix: String) -> Bool {
        if prefix.contains("*") {
            let parts = prefix.split(separator: "*").map(String.init)
            return parts.allSatisfy { path.contains($0) }
        }
        return path.hasPrefix(prefix)
    }
}
