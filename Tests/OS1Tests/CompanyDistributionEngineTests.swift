import Foundation
import Testing
@testable import OS1

struct CompanyDistributionEngineTests {
    @Test
    func everyGrowthActionHasCompanyCampaignChannelAndApprovalState() {
        let manifest = manifest()
        let campaigns = CompanyDistributionEngine.proposedCampaigns(companyID: "company", manifest: manifest)

        #expect(!campaigns.isEmpty)
        for campaign in campaigns {
            #expect(campaign.companyID == "company")
            #expect(!campaign.id.isEmpty)
            #expect(!campaign.channel.rawValue.isEmpty)
            #expect(!campaign.approvalState.rawValue.isEmpty)
            #expect(!campaign.complianceChecks.isEmpty)
            #expect(campaign.complianceDecision.status == .blocked)
        }
    }

    @Test
    func unapprovedOutboundMessagesAreBlocked() {
        let email = CompanyDistributionEngine.proposedCampaigns(companyID: "company", manifest: manifest())
            .first { $0.channel == .emailDrafts }!

        #expect(email.approvalState == .approvalRequired)
        #expect(CompanyDistributionEngine.blocksSend(campaign: email, recipient: "buyer@example.com", sentToday: 0))

        let approved = CompanyDistributionEngine.approve(email)
        #expect(CompanyDistributionEngine.blocksSend(campaign: approved, recipient: "buyer@example.com", sentToday: 0))

        let compliant = CompanyDistributionEngine.attachCompliance(to: approved, metadata: compliantMetadata())
        #expect(!CompanyDistributionEngine.blocksSend(campaign: compliant, recipient: "buyer@example.com", sentToday: 0))
    }

    @Test
    func suppressionListAndRateLimitBlockApprovedCampaigns() {
        let campaign = CompanyDistributionEngine.attachCompliance(
            to: CompanyDistributionEngine.approve(
                CompanyDistributionEngine.proposedCampaigns(
                    companyID: "company",
                    manifest: manifest(),
                    suppressionList: ["optout@example.com"]
                ).first { $0.channel == .emailDrafts }!
            ),
            metadata: compliantMetadata()
        )

        #expect(CompanyDistributionEngine.blocksSend(campaign: campaign, recipient: "optout@example.com", sentToday: 0))
        #expect(CompanyDistributionEngine.blocksSend(campaign: campaign, recipient: "new@example.com", sentToday: campaign.rateLimitPerDay))
    }

    @Test
    func resultsProduceLedgerEntriesAndSummaryMetrics() {
        let campaigns = CompanyDistributionEngine.proposedCampaigns(companyID: "company", manifest: manifest())
            .map(CompanyDistributionEngine.approve)
            .map { CompanyDistributionEngine.attachCompliance(to: $0, metadata: compliantMetadata()) }
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

    @Test
    func outboundCampaignsCannotExecuteWithoutPassingCompliancePolicy() {
        let email = CompanyDistributionEngine.proposedCampaigns(companyID: "company", manifest: manifest())
            .first { $0.channel == .emailDrafts }!

        let approvedOnly = CompanyDistributionEngine.approve(email)
        let compliant = CompanyDistributionEngine.attachCompliance(to: approvedOnly, metadata: compliantMetadata())

        #expect(!approvedOnly.canExecute)
        #expect(approvedOnly.complianceDecision.status == .blocked)
        #expect(compliant.canExecute)
    }

    @Test
    func legacyCampaignsDecodeWithComplianceDecisionDefaults() throws {
        let json = """
        {
          "id": "company-emailDrafts",
          "companyID": "company",
          "channel": "emailDrafts",
          "audience": "Small business owners",
          "creative": "Draft first 25 customer emails without sending.",
          "spendLimitUSD": 0,
          "approvalState": "approved",
          "complianceChecks": ["CAN-SPAM footer"],
          "rateLimitPerDay": 25,
          "suppressionList": [],
          "nextAction": "Prepare emailDrafts draft"
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(CompanyGrowthCampaign.self, from: json)

        #expect(decoded.complianceDecision.status == .blocked)
        #expect(!decoded.canExecute)
    }

    @Test
    func platformChannelsHaveComplianceAndRateLimitDefaults() {
        for channel in CompanyGrowthCampaign.Channel.allCases {
            #expect(!CompanyDistributionEngine.complianceChecks(channel: channel).isEmpty, "\(channel.rawValue) needs compliance checks.")
            #expect(CompanyDistributionEngine.defaultRateLimit(for: channel) > 0, "\(channel.rawValue) needs a rate limit.")
        }

        #expect(CompanyDistributionEngine.defaultRateLimit(for: .xPost) == 50)
        #expect(CompanyDistributionEngine.defaultRateLimit(for: .youtubeShort) == 2)
        #expect(CompanyDistributionEngine.defaultRateLimit(for: .pinterestPin) == 20)
    }

    @Test
    func proposedCampaignsCanBeRestrictedToEnabledChannels() {
        let campaigns = CompanyDistributionEngine.proposedCampaigns(
            companyID: "company",
            manifest: manifest(),
            enabledChannels: [.seoPages, .emailDrafts]
        )

        #expect(campaigns.map(\.channel) == [.seoPages, .emailDrafts])
    }

    @Test
    func newPlatformPublishesRequireApprovalDuringFirstWeek() {
        #expect(CompanyDistributionEngine.requiresApproval(channel: .xPost, spend: 0, companyHistoryDays: 0))
        #expect(!CompanyDistributionEngine.requiresApproval(channel: .xPost, spend: 0, companyHistoryDays: 7))
        #expect(CompanyDistributionEngine.complianceChannel(for: .linkedinPost) == .socialPlatform)
    }

    private func manifest() -> CompanyFactoryManifest {
        CompanyFactory.manifest(companyID: "company", template: nil, worktreePath: "/tmp/company")
    }

    private func compliantMetadata() -> CompanyComplianceMetadata {
        CompanyComplianceMetadata(
            legalBasis: "legitimate-interest",
            unsubscribePath: "Reply unsubscribe or use /unsubscribe",
            disclosureText: "Commercial outreach from the company",
            targetAudience: "Small business owners",
            contactSource: "manually sourced first-party list",
            dataRetentionPolicy: "Delete non-responders after 30 days"
        )
    }
}
