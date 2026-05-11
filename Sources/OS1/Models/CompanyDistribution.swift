import Foundation

struct CompanyGrowthCampaign: Codable, Hashable, Identifiable {
    enum Channel: String, Codable, CaseIterable, Hashable {
        case seoPages
        case contentPosts
        case marketplace
        case directories
        case partnerOutreach
        case warmIntros
        case paidExperiment
        case emailDrafts
    }

    enum ApprovalState: String, Codable, CaseIterable, Hashable {
        case draft
        case approvalRequired
        case approved
        case blocked
    }

    let id: String
    var companyID: String
    var channel: Channel
    var audience: String
    var creative: String
    var spendLimitUSD: Double
    var approvalState: ApprovalState
    var complianceChecks: [String]
    var rateLimitPerDay: Int
    var suppressionList: [String]
    var nextAction: String

    var canExecute: Bool {
        approvalState == .approved && complianceChecks.isEmpty == false
    }

    var isOutbound: Bool {
        switch channel {
        case .partnerOutreach, .warmIntros, .emailDrafts:
            return true
        case .seoPages, .contentPosts, .marketplace, .directories, .paidExperiment:
            return false
        }
    }
}

struct CompanyGrowthResult: Codable, Hashable {
    var companyID: String
    var campaignID: String
    var impressions: Int
    var clicks: Int
    var replies: Int
    var conversions: Int
    var revenueUSD: Double
    var costUSD: Double
    var sourceReference: String

    var conversionRate: Double {
        guard clicks > 0 else { return 0 }
        return Double(conversions) / Double(clicks)
    }
}

struct CompanyDistributionSummary: Codable, Hashable {
    var active: [CompanyGrowthCampaign]
    var blocked: [CompanyGrowthCampaign]
    var nextRecommendedAction: String
    var revenueLedgerEntries: [CompanyLedgerEntry]
}

enum CompanyDistributionEngine {
    static func proposedCampaigns(
        companyID: String,
        manifest: CompanyFactoryManifest,
        suppressionList: [String] = []
    ) -> [CompanyGrowthCampaign] {
        let audience = manifest.icp
        return [
            campaign(companyID: companyID, channel: .seoPages, audience: audience, creative: "Publish 3 validation-backed SEO pages for \(manifest.offer).", spend: 0, suppressionList: suppressionList),
            campaign(companyID: companyID, channel: .marketplace, audience: audience, creative: "Draft marketplace listing assets and compliance-safe claims.", spend: 0, suppressionList: suppressionList),
            campaign(companyID: companyID, channel: .partnerOutreach, audience: audience, creative: "Draft partner outreach sequence for warm review.", spend: 0, suppressionList: suppressionList),
            campaign(companyID: companyID, channel: .emailDrafts, audience: audience, creative: "Draft first 25 customer emails without sending.", spend: 0, suppressionList: suppressionList),
            campaign(companyID: companyID, channel: .paidExperiment, audience: audience, creative: "Draft a capped paid test with sandbox budget approval.", spend: 25, suppressionList: suppressionList)
        ]
    }

    static func summarize(campaigns: [CompanyGrowthCampaign], results: [CompanyGrowthResult]) -> CompanyDistributionSummary {
        let active = campaigns.filter(\.canExecute)
        let blocked = campaigns.filter { !$0.canExecute }
        let entries = results.flatMap(ledgerEntries)
        let next = blocked.first?.nextAction ?? active.first?.nextAction ?? "No campaign action queued"
        return CompanyDistributionSummary(active: active, blocked: blocked, nextRecommendedAction: next, revenueLedgerEntries: entries)
    }

    static func approve(_ campaign: CompanyGrowthCampaign) -> CompanyGrowthCampaign {
        var approved = campaign
        approved.approvalState = .approved
        return approved
    }

    static func blocksSend(
        campaign: CompanyGrowthCampaign,
        recipient: String,
        sentToday: Int,
        reputation: CompanyReputationHealth? = nil
    ) -> Bool {
        campaign.approvalState != .approved ||
        campaign.suppressionList.contains(recipient.lowercased()) ||
        sentToday >= campaign.rateLimitPerDay ||
        CompanyReputationEngine.blocksSend(campaign: campaign, reputation: reputation)
    }

    private static func campaign(
        companyID: String,
        channel: CompanyGrowthCampaign.Channel,
        audience: String,
        creative: String,
        spend: Double,
        suppressionList: [String]
    ) -> CompanyGrowthCampaign {
        let approval = requiresApproval(channel: channel, spend: spend) ? CompanyGrowthCampaign.ApprovalState.approvalRequired : .draft
        return CompanyGrowthCampaign(
            id: "\(companyID)-\(channel.rawValue)",
            companyID: companyID,
            channel: channel,
            audience: audience,
            creative: creative,
            spendLimitUSD: spend,
            approvalState: approval,
            complianceChecks: complianceChecks(channel: channel),
            rateLimitPerDay: channel == .emailDrafts || channel == .partnerOutreach ? 25 : 5,
            suppressionList: suppressionList.map { $0.lowercased() },
            nextAction: approval == .approvalRequired ? "Request approval before \(channel.rawValue)" : "Prepare \(channel.rawValue) draft"
        )
    }

    private static func requiresApproval(channel: CompanyGrowthCampaign.Channel, spend: Double) -> Bool {
        if spend > 0 { return true }
        switch channel {
        case .partnerOutreach, .warmIntros, .paidExperiment, .emailDrafts, .contentPosts, .marketplace:
            return true
        case .seoPages, .directories:
            return false
        }
    }

    private static func complianceChecks(channel: CompanyGrowthCampaign.Channel) -> [String] {
        switch channel {
        case .emailDrafts:
            return ["CAN-SPAM footer", "consent/source recorded", "suppression list checked", "user approval before send"]
        case .partnerOutreach, .warmIntros:
            return ["no deceptive identity", "suppression list checked", "user approval before send"]
        case .contentPosts, .marketplace:
            return ["platform terms reviewed", "claims review", "affiliate disclosure if applicable", "user approval before publish"]
        case .paidExperiment:
            return ["budget approval", "ad policy review", "tracking disclosure"]
        case .seoPages, .directories:
            return ["privacy-safe analytics", "claims review", "no fake reviews"]
        }
    }

    private static func ledgerEntries(for result: CompanyGrowthResult) -> [CompanyLedgerEntry] {
        var entries: [CompanyLedgerEntry] = []
        if result.revenueUSD > 0 {
            entries.append(
                CompanyLedgerEntry(
                    id: "\(result.campaignID)-revenue",
                    companyID: result.companyID,
                    occurredAt: nil,
                    kind: .revenue,
                    category: .sales,
                    amountUSD: result.revenueUSD,
                    source: "distribution",
                    sourceReference: result.sourceReference,
                    confidence: .verified,
                    note: "Growth campaign conversion"
                )
            )
        }
        if result.costUSD > 0 {
            entries.append(
                CompanyLedgerEntry(
                    id: "\(result.campaignID)-cost",
                    companyID: result.companyID,
                    occurredAt: nil,
                    kind: .cost,
                    category: .ads,
                    amountUSD: result.costUSD,
                    source: "distribution",
                    sourceReference: result.sourceReference,
                    confidence: .verified,
                    note: "Growth campaign spend"
                )
            )
        }
        return entries
    }
}
