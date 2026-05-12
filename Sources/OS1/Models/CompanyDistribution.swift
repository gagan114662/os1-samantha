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
        case xPost
        case xThread
        case xReply
        case youtubeUpload
        case youtubeShort
        case youtubeCommunityPost
        case instagramReel
        case instagramPost
        case instagramStory
        case instagramDM
        case tiktokVideo
        case tiktokComment
        case linkedinPost
        case linkedinDM
        case linkedinNewsletter
        case pinterestPin
        case redditPost
        case redditComment
        case affiliateLink
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
    var complianceMetadata: CompanyComplianceMetadata?
    var complianceDecision: CompanyComplianceDecision
    var rateLimitPerDay: Int
    var suppressionList: [String]
    var nextAction: String
    var parentExperimentID: String? = nil

    var canExecute: Bool {
        approvalState == .approved && complianceChecks.isEmpty == false && complianceDecision.canRun
    }

    var isOutbound: Bool {
        switch channel {
        case .partnerOutreach, .warmIntros, .emailDrafts, .xReply, .instagramDM, .tiktokComment, .linkedinDM, .redditComment:
            return true
        case .seoPages, .contentPosts, .marketplace, .directories, .paidExperiment, .xPost, .xThread, .youtubeUpload, .youtubeShort, .youtubeCommunityPost, .instagramReel, .instagramPost, .instagramStory, .tiktokVideo, .linkedinPost, .linkedinNewsletter, .pinterestPin, .redditPost, .affiliateLink:
            return false
        }
    }
}

extension CompanyGrowthCampaign.Channel {
    var displayTitle: String {
        L10n.string(localizationKey)
    }

    var localizationKey: String {
        "CompanyGrowthCampaign.Channel.\(rawValue)"
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

extension CompanyGrowthCampaign {
    enum CodingKeys: String, CodingKey {
        case id
        case companyID
        case channel
        case audience
        case creative
        case spendLimitUSD
        case approvalState
        case complianceChecks
        case complianceMetadata
        case complianceDecision
        case rateLimitPerDay
        case suppressionList
        case nextAction
        case parentExperimentID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        companyID = try container.decode(String.self, forKey: .companyID)
        channel = try container.decode(Channel.self, forKey: .channel)
        audience = try container.decode(String.self, forKey: .audience)
        creative = try container.decode(String.self, forKey: .creative)
        spendLimitUSD = try container.decode(Double.self, forKey: .spendLimitUSD)
        approvalState = try container.decode(ApprovalState.self, forKey: .approvalState)
        complianceChecks = try container.decode([String].self, forKey: .complianceChecks)
        complianceMetadata = try container.decodeIfPresent(CompanyComplianceMetadata.self, forKey: .complianceMetadata)
        complianceDecision = try container.decodeIfPresent(CompanyComplianceDecision.self, forKey: .complianceDecision)
            ?? CompanyComplianceEngine.evaluate(
                action: CompanyComplianceAction(
                    companyID: companyID,
                    channel: CompanyDistributionEngine.complianceChannel(for: channel),
                    proposedAction: creative,
                    content: audience,
                    metadata: complianceMetadata,
                    browserPolicy: nil,
                    targetDomain: nil,
                    browserAction: nil,
                    requestedCredential: nil
                )
            )
        rateLimitPerDay = try container.decode(Int.self, forKey: .rateLimitPerDay)
        suppressionList = try container.decode([String].self, forKey: .suppressionList)
        nextAction = try container.decode(String.self, forKey: .nextAction)
        parentExperimentID = try container.decodeIfPresent(String.self, forKey: .parentExperimentID)
    }
}

enum CompanyDistributionEngine {
    static func proposedCampaigns(
        companyID: String,
        manifest: CompanyFactoryManifest,
        suppressionList: [String] = [],
        enabledChannels: Set<CompanyGrowthCampaign.Channel>? = nil
    ) -> [CompanyGrowthCampaign] {
        let audience = manifest.icp
        let proposals = [
            campaign(companyID: companyID, channel: .seoPages, audience: audience, creative: "Publish 3 validation-backed SEO pages for \(manifest.offer).", spend: 0, suppressionList: suppressionList),
            campaign(companyID: companyID, channel: .marketplace, audience: audience, creative: "Draft marketplace listing assets and compliance-safe claims.", spend: 0, suppressionList: suppressionList),
            campaign(companyID: companyID, channel: .partnerOutreach, audience: audience, creative: "Draft partner outreach sequence for warm review.", spend: 0, suppressionList: suppressionList),
            campaign(companyID: companyID, channel: .emailDrafts, audience: audience, creative: "Draft first 25 customer emails without sending.", spend: 0, suppressionList: suppressionList),
            campaign(companyID: companyID, channel: .paidExperiment, audience: audience, creative: "Draft a capped paid test with sandbox budget approval.", spend: 25, suppressionList: suppressionList)
        ]
        guard let enabledChannels else { return proposals }
        return proposals.filter { enabledChannels.contains($0.channel) }
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

    static func approve(
        _ campaign: CompanyGrowthCampaign,
        qualityDecision: CompanyContentQualityDecision,
        operatorOverrideBy actor: String? = nil
    ) -> (campaign: CompanyGrowthCampaign, auditEvent: CompanyEvent?) {
        guard qualityDecision.canApprove else {
            guard let actor else {
                var blocked = campaign
                blocked.approvalState = .blocked
                return (blocked, nil)
            }
            var approved = campaign
            approved.approvalState = .approved
            let event = CompanyEvent(
                companyID: campaign.companyID,
                actor: actor,
                kind: .approvalApproved,
                summary: "Operator override approved campaign \(campaign.id) despite content quality flags.",
                riskTier: "medium",
                approvalState: "quality-override",
                metadata: [
                    "campaignID": campaign.id,
                    "flags": qualityDecision.flags.joined(separator: ",")
                ]
            )
            return (approved, event)
        }
        return (approve(campaign), nil)
    }

    static func attachCompliance(
        to campaign: CompanyGrowthCampaign,
        metadata: CompanyComplianceMetadata,
        browserPolicy: CompanyBrowserAutomationPolicy? = nil
    ) -> CompanyGrowthCampaign {
        var checked = campaign
        checked.complianceMetadata = metadata
        checked.complianceDecision = complianceDecision(
            campaign: checked,
            metadata: metadata,
            browserPolicy: browserPolicy
        )
        return checked
    }

    static func blocksSend(
        campaign: CompanyGrowthCampaign,
        recipient: String,
        sentToday: Int,
        reputation: CompanyReputationHealth? = nil
    ) -> Bool {
        campaign.approvalState != .approved ||
        !campaign.complianceDecision.canRun ||
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
            complianceMetadata: nil,
            complianceDecision: complianceDecision(campaignChannel: channel, companyID: companyID, audience: audience, creative: creative),
            rateLimitPerDay: defaultRateLimit(for: channel),
            suppressionList: suppressionList.map { $0.lowercased() },
            nextAction: approval == .approvalRequired ? "Request approval before \(channel.rawValue)" : "Prepare \(channel.rawValue) draft",
            parentExperimentID: nil
        )
    }

    static func requiresApproval(channel: CompanyGrowthCampaign.Channel, spend: Double, companyHistoryDays: Int = 0) -> Bool {
        if spend > 0 { return true }
        if platformSpecificChannels.contains(channel), companyHistoryDays < 7 { return true }
        switch channel {
        case .partnerOutreach, .warmIntros, .paidExperiment, .emailDrafts, .contentPosts, .marketplace:
            return true
        case .seoPages, .directories, .xPost, .xThread, .xReply, .youtubeUpload, .youtubeShort, .youtubeCommunityPost, .instagramReel, .instagramPost, .instagramStory, .instagramDM, .tiktokVideo, .tiktokComment, .linkedinPost, .linkedinDM, .linkedinNewsletter, .pinterestPin, .redditPost, .redditComment, .affiliateLink:
            return false
        }
    }

    static func complianceChecks(channel: CompanyGrowthCampaign.Channel) -> [String] {
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
        case .xPost, .xThread, .xReply:
            return ["paid promotion disclosure", "affiliate disclosure if applicable", "platform rate limit checked", "user approval before first publish"]
        case .youtubeUpload, .youtubeShort, .youtubeCommunityPost:
            return ["affiliate disclosure in description", "media rights cleared", "no unsafe regulated claims", "user approval before first publish"]
        case .instagramReel, .instagramPost, .instagramStory, .instagramDM:
            return ["branded-content tag if applicable", "affiliate disclosure if applicable", "no fake engagement", "user approval before first publish"]
        case .tiktokVideo, .tiktokComment:
            return ["branded-content disclosure", "music/media rights cleared", "platform rate limit checked", "user approval before first publish"]
        case .linkedinPost, .linkedinDM, .linkedinNewsletter:
            return ["truthful professional identity", "unsubscribe path for outreach", "no scraped contact list", "user approval before first publish"]
        case .pinterestPin:
            return ["affiliate disclosure on destination", "image rights cleared", "no misleading pin destination", "user approval before first publish"]
        case .redditPost, .redditComment:
            return ["subreddit rules checked", "no astroturfing", "affiliate disclosure if applicable", "user approval before first publish"]
        case .affiliateLink:
            return ["affiliate disclosure", "UTM privacy review", "destination claim review"]
        }
    }

    static func defaultRateLimit(for channel: CompanyGrowthCampaign.Channel) -> Int {
        switch channel {
        case .emailDrafts, .partnerOutreach, .warmIntros:
            return 25
        case .xPost, .xThread, .xReply:
            return 50
        case .youtubeUpload, .youtubeShort, .youtubeCommunityPost:
            return 2
        case .instagramReel, .instagramPost, .instagramStory, .instagramDM:
            return 5
        case .tiktokVideo, .tiktokComment:
            return 5
        case .linkedinPost, .linkedinDM, .linkedinNewsletter:
            return 5
        case .pinterestPin:
            return 20
        case .redditPost, .redditComment:
            return 5
        case .affiliateLink:
            return 100
        case .seoPages, .contentPosts, .marketplace, .directories, .paidExperiment:
            return 5
        }
    }

    private static func complianceDecision(
        campaign: CompanyGrowthCampaign,
        metadata: CompanyComplianceMetadata,
        browserPolicy: CompanyBrowserAutomationPolicy?
    ) -> CompanyComplianceDecision {
        complianceDecision(
            campaignChannel: campaign.channel,
            companyID: campaign.companyID,
            audience: campaign.audience,
            creative: campaign.creative,
            metadata: metadata,
            browserPolicy: browserPolicy
        )
    }

    private static func complianceDecision(
        campaignChannel: CompanyGrowthCampaign.Channel,
        companyID: String,
        audience: String,
        creative: String,
        metadata: CompanyComplianceMetadata? = nil,
        browserPolicy: CompanyBrowserAutomationPolicy? = nil
    ) -> CompanyComplianceDecision {
        CompanyComplianceEngine.evaluate(
            action: CompanyComplianceAction(
                companyID: companyID,
                channel: complianceChannel(for: campaignChannel),
                proposedAction: creative,
                content: audience,
                metadata: metadata,
                browserPolicy: browserPolicy,
                targetDomain: nil,
                browserAction: nil,
                requestedCredential: nil
            )
        )
    }

    static func complianceChannel(for channel: CompanyGrowthCampaign.Channel) -> CompanyComplianceChannel {
        switch channel {
        case .emailDrafts, .partnerOutreach, .warmIntros:
            return .email
        case .marketplace:
            return .marketplace
        case .xPost, .xThread, .xReply, .instagramReel, .instagramPost, .instagramStory, .instagramDM, .tiktokVideo, .tiktokComment, .linkedinPost, .linkedinDM, .linkedinNewsletter, .pinterestPin, .redditPost, .redditComment:
            return .socialPlatform
        case .youtubeUpload, .youtubeShort, .youtubeCommunityPost:
            return .publicContent
        case .contentPosts, .seoPages, .directories, .affiliateLink:
            return .publicContent
        case .paidExperiment:
            return .payments
        }
    }

    private static let platformSpecificChannels: Set<CompanyGrowthCampaign.Channel> = [
        .xPost, .xThread, .xReply,
        .youtubeUpload, .youtubeShort, .youtubeCommunityPost,
        .instagramReel, .instagramPost, .instagramStory, .instagramDM,
        .tiktokVideo, .tiktokComment,
        .linkedinPost, .linkedinDM, .linkedinNewsletter,
        .pinterestPin,
        .redditPost, .redditComment,
        .affiliateLink
    ]

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
