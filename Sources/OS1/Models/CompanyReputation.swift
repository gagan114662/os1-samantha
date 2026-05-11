import Foundation

struct CompanyReputationPolicy: Codable, Hashable {
    var maxBounceRate: Double
    var maxComplaintRate: Double
    var maxUnsubscribeRate: Double
    var minReviewAverage: Double
    var warmupDailyLimit: Int
    var throttledDailyLimit: Int

    static let productionDefault = CompanyReputationPolicy(
        maxBounceRate: 0.04,
        maxComplaintRate: 0.003,
        maxUnsubscribeRate: 0.02,
        minReviewAverage: 3.8,
        warmupDailyLimit: 10,
        throttledDailyLimit: 5
    )
}

struct CompanyReputationAsset: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case senderDomain
        case emailAccount
        case socialAccount
        case marketplaceAccount
        case brandProfile
    }

    enum Status: String, Codable, CaseIterable, Hashable {
        case active
        case warmup
        case throttled
        case quarantined
        case retired
        case banned
    }

    var id: String
    var kind: Kind
    var label: String
    var ownerCompanyIDs: [String]
    var status: Status
    var dailySendLimit: Int
    var notes: [String]
}

struct CompanyReputationSignal: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var assetID: String
    var sent: Int
    var delivered: Int
    var bounced: Int
    var complaints: Int
    var unsubscribes: Int
    var reviewAverage: Double?
    var reviewCount: Int
    var accountWarnings: [String]
    var accountBans: [String]
}

struct CompanyReputationHealth: Codable, Hashable, Identifiable {
    var id: String { assetID }
    var assetID: String
    var kind: CompanyReputationAsset.Kind
    var label: String
    var ownerCompanyIDs: [String]
    var status: CompanyReputationAsset.Status
    var bounceRate: Double
    var complaintRate: Double
    var unsubscribeRate: Double
    var reviewAverage: Double?
    var risk: CompanyIdea.RiskTier
    var canUseForOutbound: Bool
    var recommendedDailyLimit: Int
    var warnings: [String]
    var escalationTasks: [String]

    var isShared: Bool {
        ownerCompanyIDs.count > 1
    }
}

struct CompanyReputationDashboard: Codable, Hashable {
    var companyHealth: [String: [CompanyReputationHealth]]
    var sharedAssetHealth: [CompanyReputationHealth]
    var quarantinedAssetIDs: [String]
    var retiredAssetIDs: [String]
    var escalationTasks: [String]

    var allHealth: [CompanyReputationHealth] {
        let flattened = companyHealth.values.flatMap { $0 } + sharedAssetHealth
        return Array(Dictionary(grouping: flattened, by: \.assetID).compactMap { $0.value.first })
            .sorted { $0.assetID < $1.assetID }
    }
}

enum CompanyReputationEngine {
    static func dashboard(
        assets: [CompanyReputationAsset],
        signals: [CompanyReputationSignal],
        policy: CompanyReputationPolicy = .productionDefault
    ) -> CompanyReputationDashboard {
        let health = assets.map { evaluate(asset: $0, signals: signals, policy: policy) }
        let companyHealth = health.reduce(into: [String: [CompanyReputationHealth]]()) { partial, item in
            for companyID in item.ownerCompanyIDs {
                partial[companyID, default: []].append(item)
            }
        }
        return CompanyReputationDashboard(
            companyHealth: companyHealth,
            sharedAssetHealth: health.filter(\.isShared),
            quarantinedAssetIDs: health.filter { $0.status == .quarantined }.map(\.assetID).sorted(),
            retiredAssetIDs: health.filter { $0.status == .retired || $0.status == .banned }.map(\.assetID).sorted(),
            escalationTasks: health.flatMap(\.escalationTasks).sorted()
        )
    }

    static func evaluate(
        asset: CompanyReputationAsset,
        signals: [CompanyReputationSignal],
        policy: CompanyReputationPolicy = .productionDefault
    ) -> CompanyReputationHealth {
        let related = signals.filter { $0.assetID == asset.id }
        let sent = related.map(\.sent).reduce(0, +)
        let bounced = related.map(\.bounced).reduce(0, +)
        let complaints = related.map(\.complaints).reduce(0, +)
        let unsubscribes = related.map(\.unsubscribes).reduce(0, +)
        let reviewSamples = related.compactMap { signal -> (Double, Int)? in
            guard let average = signal.reviewAverage, signal.reviewCount > 0 else { return nil }
            return (average, signal.reviewCount)
        }
        let reviewTotal = reviewSamples.map(\.1).reduce(0, +)
        let reviewAverage = reviewTotal == 0
            ? nil
            : reviewSamples.reduce(0.0) { $0 + ($1.0 * Double($1.1)) } / Double(reviewTotal)
        let warnings = related.flatMap(\.accountWarnings)
        let bans = related.flatMap(\.accountBans)
        let bounceRate = rate(bounced, sent)
        let complaintRate = rate(complaints, sent)
        let unsubscribeRate = rate(unsubscribes, sent)
        let risk = riskTier(
            asset: asset,
            bounceRate: bounceRate,
            complaintRate: complaintRate,
            unsubscribeRate: unsubscribeRate,
            reviewAverage: reviewAverage,
            warnings: warnings,
            bans: bans,
            policy: policy
        )
        let escalationTasks = escalationTasks(
            asset: asset,
            risk: risk,
            warnings: warnings,
            bans: bans
        )
        return CompanyReputationHealth(
            assetID: asset.id,
            kind: asset.kind,
            label: asset.label,
            ownerCompanyIDs: asset.ownerCompanyIDs.sorted(),
            status: asset.status,
            bounceRate: bounceRate,
            complaintRate: complaintRate,
            unsubscribeRate: unsubscribeRate,
            reviewAverage: reviewAverage,
            risk: risk,
            canUseForOutbound: canUseForOutbound(asset: asset, risk: risk),
            recommendedDailyLimit: recommendedDailyLimit(asset: asset, risk: risk, policy: policy),
            warnings: warnings + thresholdWarnings(
                bounceRate: bounceRate,
                complaintRate: complaintRate,
                unsubscribeRate: unsubscribeRate,
                reviewAverage: reviewAverage,
                policy: policy
            ),
            escalationTasks: escalationTasks
        )
    }

    static func blocksSend(
        campaign: CompanyGrowthCampaign,
        reputation: CompanyReputationHealth?,
        policy: CompanyReputationPolicy = .productionDefault
    ) -> Bool {
        guard campaign.isOutbound else { return false }
        guard let reputation else { return false }
        if !reputation.canUseForOutbound { return true }
        if reputation.bounceRate >= policy.maxBounceRate { return true }
        if reputation.complaintRate >= policy.maxComplaintRate { return true }
        return campaign.rateLimitPerDay > reputation.recommendedDailyLimit
    }

    static func quarantine(
        _ asset: CompanyReputationAsset,
        reason: String
    ) -> CompanyReputationAsset {
        var copy = asset
        copy.status = .quarantined
        copy.dailySendLimit = 0
        copy.notes.append("quarantined: \(reason)")
        return copy
    }

    static func retire(
        _ asset: CompanyReputationAsset,
        reason: String
    ) -> CompanyReputationAsset {
        var copy = asset
        copy.status = .retired
        copy.dailySendLimit = 0
        copy.notes.append("retired: \(reason)")
        return copy
    }

    private static func riskTier(
        asset: CompanyReputationAsset,
        bounceRate: Double,
        complaintRate: Double,
        unsubscribeRate: Double,
        reviewAverage: Double?,
        warnings: [String],
        bans: [String],
        policy: CompanyReputationPolicy
    ) -> CompanyIdea.RiskTier {
        if asset.status == .banned || asset.status == .retired || !bans.isEmpty { return .critical }
        if asset.status == .quarantined { return .critical }
        if bounceRate >= policy.maxBounceRate || complaintRate >= policy.maxComplaintRate { return .high }
        if !warnings.isEmpty { return .high }
        if unsubscribeRate >= policy.maxUnsubscribeRate { return .medium }
        if let reviewAverage, reviewAverage < policy.minReviewAverage { return .medium }
        if asset.status == .warmup || asset.status == .throttled { return .medium }
        return .low
    }

    private static func escalationTasks(
        asset: CompanyReputationAsset,
        risk: CompanyIdea.RiskTier,
        warnings: [String],
        bans: [String]
    ) -> [String] {
        var tasks: [String] = []
        if !warnings.isEmpty {
            tasks.append("Open incident: account warning on \(asset.label)")
        }
        if !bans.isEmpty || asset.status == .banned {
            tasks.append("Escalate ban appeal and retire \(asset.label)")
        }
        if risk == .high || risk == .critical {
            tasks.append("Pause outbound campaigns using \(asset.label)")
        }
        return tasks
    }

    private static func thresholdWarnings(
        bounceRate: Double,
        complaintRate: Double,
        unsubscribeRate: Double,
        reviewAverage: Double?,
        policy: CompanyReputationPolicy
    ) -> [String] {
        var warnings: [String] = []
        if bounceRate >= policy.maxBounceRate { warnings.append("bounce threshold exceeded") }
        if complaintRate >= policy.maxComplaintRate { warnings.append("complaint threshold exceeded") }
        if unsubscribeRate >= policy.maxUnsubscribeRate { warnings.append("unsubscribe threshold exceeded") }
        if let reviewAverage, reviewAverage < policy.minReviewAverage { warnings.append("review health below floor") }
        return warnings
    }

    private static func recommendedDailyLimit(
        asset: CompanyReputationAsset,
        risk: CompanyIdea.RiskTier,
        policy: CompanyReputationPolicy
    ) -> Int {
        if risk == .critical || risk == .high { return 0 }
        if asset.status == .warmup { return min(asset.dailySendLimit, policy.warmupDailyLimit) }
        if asset.status == .throttled || risk == .medium {
            return min(asset.dailySendLimit, policy.throttledDailyLimit)
        }
        return asset.dailySendLimit
    }

    private static func canUseForOutbound(
        asset: CompanyReputationAsset,
        risk: CompanyIdea.RiskTier
    ) -> Bool {
        guard asset.status != .quarantined,
              asset.status != .retired,
              asset.status != .banned
        else { return false }
        return risk != .high && risk != .critical
    }

    private static func rate(_ numerator: Int, _ denominator: Int) -> Double {
        guard denominator > 0 else { return 0 }
        return Double(numerator) / Double(denominator)
    }
}
