import Foundation
import Testing
@testable import OS1

struct CompanyAbuseContainmentTests {
    @Test
    func suspectedCompromisedCompanyCanBeQuarantinedWithoutStoppingFleet() {
        let anomaly = CompanyAbuseAnomaly(
            id: "anomaly-company-unauthorizedSecretAccess",
            companyID: "company",
            kind: .unauthorizedSecretAccess,
            severity: .critical,
            eventIDs: [],
            summary: "secret misuse",
            detectedAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        let plan = CompanyAbuseContainmentEngine.quarantinePlan(
            companyID: "company",
            anomalies: [anomaly],
            credentialNames: ["STRIPE_API_KEY"],
            browserSessionIDs: ["browser-1"],
            runnerIDs: ["runner-1"]
        )

        #expect(plan.quarantineCompanyOnly)
        #expect(!plan.fleetWideStopRequired)
        #expect(plan.credentialNames.contains("STRIPE_API_KEY"))
        #expect(plan.blockedActions.contains("payments"))
    }

    @Test
    func credentialRevocationStepsAreSurfaced() {
        let steps = CompanyAbuseContainmentEngine.revocationRunbook(
            credentialNames: ["OPENAI_API_KEY", "STRIPE_API_KEY"]
        )

        #expect(steps.contains { $0.contains("Pause the company") })
        #expect(steps.contains { $0.contains("OPENAI_API_KEY") && $0.contains("STRIPE_API_KEY") })
        #expect(steps.contains { $0.contains("Record revocation evidence") })
    }

    @Test
    func runawaySpendCreatesAnomalyAndIncident() {
        let event = event(
            kind: .externalSideEffect,
            summary: "ad spend",
            costUSD: 250
        )
        let anomalies = CompanyAbuseContainmentEngine.detect(events: [event])
        let incidents = CompanyAbuseContainmentEngine.incidents(for: anomalies)

        #expect(anomalies.map(\.kind) == [.runawaySpend])
        #expect(incidents.count == 1)
        #expect(incidents[0].quarantinePlan.companyID == "company")
    }

    @Test
    func messageSpamCreatesAnomalyAndIncident() {
        let spam = event(
            kind: .externalSideEffect,
            summary: "sent outbound messages",
            metadata: ["messagesSent": "75"]
        )

        let anomalies = CompanyAbuseContainmentEngine.detect(events: [spam])
        let incident = CompanyAbuseContainmentEngine.incidents(for: anomalies).first

        #expect(anomalies.map(\.kind) == [.messageSpam])
        #expect(incident?.anomalyIDs == ["anomaly-company-messageSpam"])
    }

    @Test
    func unauthorizedSecretAccessCreatesCriticalAnomaly() {
        let secret = event(
            kind: .secretAccessed,
            summary: "credential read",
            metadata: ["credentialName": "STRIPE_API_KEY"]
        )

        let anomalies = CompanyAbuseContainmentEngine.detect(
            events: [secret],
            allowedCredentialsByCompany: ["company": ["RESEND_API_KEY"]]
        )

        #expect(anomalies.first?.kind == .unauthorizedSecretAccess)
        #expect(anomalies.first?.severity == .critical)
    }

    @Test
    func auditSnapshotsAreStableFromImmutableEventData() {
        let first = event(id: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE", summary: "one")
        let second = event(id: "BBBBBBBB-BBBB-CCCC-DDDD-EEEEEEEEEEEE", summary: "two")

        let a = CompanyAbuseContainmentEngine.auditSnapshot(companyID: "company", events: [first, second])
        let b = CompanyAbuseContainmentEngine.auditSnapshot(companyID: "company", events: [second, first])

        #expect(a.immutableHash == b.immutableHash)
        #expect(a.eventIDs == [first.id, second.id])
    }

    private func event(
        id: String = "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
        kind: CompanyEvent.Kind = .externalSideEffect,
        summary: String = "event",
        costUSD: Double? = nil,
        metadata: [String: String] = [:]
    ) -> CompanyEvent {
        CompanyEvent(
            id: UUID(uuidString: id)!,
            occurredAt: Date(timeIntervalSince1970: 1_800_000_000),
            companyID: "company",
            kind: kind,
            summary: summary,
            costUSD: costUSD,
            metadata: metadata
        )
    }
}
