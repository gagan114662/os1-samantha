import Foundation
import Testing
@testable import OS1

struct CompanyDistributionEngineTests {
    @Test
    func everyGrowthActionHasCompanyCampaignChannelAndApprovalState() {
        let manifest = CompanyFactory.manifest(companyID: "company", template: CompanyTemplateCatalog.all[0], worktreePath: "/tmp/company")
        let campaigns = CompanyDistributionEngine.proposedCampaigns(companyID: "company", manifest: manifest)

        #expect(!campaigns.isEmpty)
        for campaign in campaigns {
            #expect(campaign.companyID == "company")
            #expect(!campaign.id.isEmpty)
            #expect(!campaign.channel.rawValue.isEmpty)
            #expect(!campaign.approvalState.rawValue.isEmpty)
            #expect(!campaign.complianceChecks.isEmpty)
        }
    }

    @Test
    func unapprovedOutboundMessagesAreBlocked() {
        let manifest = CompanyFactory.manifest(companyID: "company", template: CompanyTemplateCatalog.all[0], worktreePath: "/tmp/company")
        let email = CompanyDistributionEngine.proposedCampaigns(companyID: "company", manifest: manifest)
            .first { $0.channel == .emailDrafts }!

        #expect(email.approvalState == .approvalRequired)
        #expect(CompanyDistributionEngine.blocksSend(campaign: email, recipient: "buyer@example.com", sentToday: 0))

        let approved = CompanyDistributionEngine.approve(email)
        #expect(!CompanyDistributionEngine.blocksSend(campaign: approved, recipient: "buyer@example.com", sentToday: 0))
    }

    @Test
    func suppressionListAndRateLimitBlockApprovedCampaigns() {
        let manifest = CompanyFactory.manifest(companyID: "company", template: CompanyTemplateCatalog.all[0], worktreePath: "/tmp/company")
        let campaign = CompanyDistributionEngine.approve(
            CompanyDistributionEngine.proposedCampaigns(
                companyID: "company",
                manifest: manifest,
                suppressionList: ["optout@example.com"]
            ).first { $0.channel == .emailDrafts }!
        )

        #expect(CompanyDistributionEngine.blocksSend(campaign: campaign, recipient: "optout@example.com", sentToday: 0))
        #expect(CompanyDistributionEngine.blocksSend(campaign: campaign, recipient: "new@example.com", sentToday: campaign.rateLimitPerDay))
    }

    @Test
    func resultsProduceLedgerEntriesAndSummaryMetrics() {
        let manifest = CompanyFactory.manifest(companyID: "company", template: CompanyTemplateCatalog.all[0], worktreePath: "/tmp/company")
        let campaigns = CompanyDistributionEngine.proposedCampaigns(companyID: "company", manifest: manifest).map(CompanyDistributionEngine.approve)
        let result = CompanyGrowthResult(
            companyID: "company",
            campaignID: campaigns[0].id,
            impressions: 100,
            clicks: 20,
            replies: 3,
            conversions: 2,
            revenueUSD: 50,
            costUSD: 10,
            sourceReference: "campaign=1"
        )
        let summary = CompanyDistributionEngine.summarize(campaigns: campaigns, results: [result])

        #expect(summary.active.count == campaigns.count)
        #expect(summary.blocked.isEmpty)
        #expect(summary.revenueLedgerEntries.contains { $0.kind == .revenue && $0.amountUSD == 50 })
        #expect(summary.revenueLedgerEntries.contains { $0.kind == .cost && $0.amountUSD == 10 })
        #expect(result.conversionRate == 0.1)
    }
}
