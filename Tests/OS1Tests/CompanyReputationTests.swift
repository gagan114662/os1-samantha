import Foundation
import Testing
@testable import OS1

struct CompanyReputationTests {
    @Test
    func reputationDashboardShowsCompanyAndSharedAssetHealth() {
        let shared = asset(id: "domain:shared", owners: ["a", "b"])
        let dashboard = CompanyReputationEngine.dashboard(
            assets: [shared],
            signals: [
                signal(companyID: "a", assetID: shared.id, sent: 100, bounced: 1),
                signal(companyID: "b", assetID: shared.id, sent: 50, bounced: 0)
            ]
        )

        #expect(dashboard.companyHealth["a"]?.first?.assetID == shared.id)
        #expect(dashboard.companyHealth["b"]?.first?.assetID == shared.id)
        #expect(dashboard.sharedAssetHealth.map(\.assetID) == [shared.id])
    }

    @Test
    func campaignsAreBlockedWhenBounceOrComplaintThresholdsAreExceeded() {
        let health = CompanyReputationEngine.evaluate(
            asset: asset(id: "sender"),
            signals: [signal(companyID: "company", assetID: "sender", sent: 100, bounced: 6, complaints: 1)]
        )
        let campaign = CompanyDistributionEngine.approve(emailCampaign())

        #expect(health.risk == .high)
        #expect(health.warnings.contains("bounce threshold exceeded"))
        #expect(CompanyDistributionEngine.blocksSend(
            campaign: campaign,
            recipient: "buyer@example.com",
            sentToday: 0,
            reputation: health
        ))
    }

    @Test
    func accountWarningsAndBansCreateEscalationTasks() {
        let warning = CompanyReputationEngine.evaluate(
            asset: asset(id: "market"),
            signals: [
                signal(
                    companyID: "company",
                    assetID: "market",
                    warnings: ["marketplace policy warning"],
                    bans: ["temporary listing ban"]
                )
            ]
        )

        #expect(warning.risk == .critical)
        #expect(warning.escalationTasks.contains { $0.contains("account warning") })
        #expect(warning.escalationTasks.contains { $0.contains("ban appeal") })
    }

    @Test
    func assetsCanBeQuarantinedOrRetiredAndCannotSend() {
        let quarantined = CompanyReputationEngine.quarantine(asset(id: "sender"), reason: "complaints")
        let retired = CompanyReputationEngine.retire(asset(id: "old"), reason: "burned domain")
        let quarantineHealth = CompanyReputationEngine.evaluate(asset: quarantined, signals: [])
        let retiredHealth = CompanyReputationEngine.evaluate(asset: retired, signals: [])

        #expect(quarantineHealth.canUseForOutbound == false)
        #expect(retiredHealth.canUseForOutbound == false)
        #expect(quarantined.notes.contains("quarantined: complaints"))
        #expect(retired.notes.contains("retired: burned domain"))
    }

    @Test
    func lifecyclePausesForHighReputationRisk() {
        let health = CompanyReputationEngine.evaluate(
            asset: asset(id: "sender"),
            signals: [signal(companyID: "company", assetID: "sender", sent: 100, complaints: 1)]
        )
        let decision = CompanyLifecycleEngine.decide(
            CompanyEvidenceSnapshot(
                companyID: "company",
                stage: .launched,
                validationDecision: nil,
                ledger: .empty,
                budgetReport: nil,
                distribution: nil,
                reputationHealth: [health],
                failureCount: 0,
                complianceRisk: .low,
                overrideReason: nil,
                artifactPaths: []
            )
        )

        #expect(decision.action == .pause)
        #expect(decision.rationale.contains("reputation"))
    }

    private func asset(
        id: String,
        owners: [String] = ["company"],
        status: CompanyReputationAsset.Status = .active
    ) -> CompanyReputationAsset {
        CompanyReputationAsset(
            id: id,
            kind: .senderDomain,
            label: id,
            ownerCompanyIDs: owners,
            status: status,
            dailySendLimit: 25,
            notes: []
        )
    }

    private func signal(
        companyID: String,
        assetID: String,
        sent: Int = 0,
        bounced: Int = 0,
        complaints: Int = 0,
        unsubscribes: Int = 0,
        warnings: [String] = [],
        bans: [String] = []
    ) -> CompanyReputationSignal {
        CompanyReputationSignal(
            id: "\(companyID)-\(assetID)",
            companyID: companyID,
            assetID: assetID,
            sent: sent,
            delivered: max(0, sent - bounced),
            bounced: bounced,
            complaints: complaints,
            unsubscribes: unsubscribes,
            reviewAverage: nil,
            reviewCount: 0,
            accountWarnings: warnings,
            accountBans: bans
        )
    }

    private func emailCampaign() -> CompanyGrowthCampaign {
        CompanyGrowthCampaign(
            id: "email",
            companyID: "company",
            channel: .emailDrafts,
            audience: "buyers",
            creative: "draft",
            spendLimitUSD: 0,
            approvalState: .approved,
            complianceChecks: ["CAN-SPAM footer"],
            rateLimitPerDay: 25,
            suppressionList: [],
            nextAction: "send"
        )
    }
}
