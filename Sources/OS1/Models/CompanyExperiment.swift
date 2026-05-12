import Foundation

struct CompanyExperiment: Codable, Hashable, Identifiable {
    enum Metric: String, Codable, CaseIterable, Hashable {
        case clicksPerImpression
        case conversionsPerClick
        case revenuePerImpression
    }

    enum AllocationPolicy: String, Codable, CaseIterable, Hashable {
        case fixedSplit
        case thompsonSampling
        case sequential
    }

    enum Status: String, Codable, CaseIterable, Hashable {
        case running
        case decided
        case stopped
        case inconclusive
    }

    struct VariantSpec: Codable, Hashable, Identifiable {
        var id: String
        var label: String
        var creative: String
        var allocationWeight: Double
    }

    var id: String
    var companyID: String
    var hypothesis: String
    var metric: Metric
    var variants: [VariantSpec]
    var allocationPolicy: AllocationPolicy
    var status: Status
    var winnerVariantID: String?
    var confidenceLevel: Double
    var decidedAt: Date?
}

struct CompanyHookLibrary: Codable, Hashable {
    var companyID: String
    var topHooks: [String]

    mutating func promote(_ hook: String, limit: Int = 10) {
        topHooks.removeAll { $0 == hook }
        topHooks.insert(hook, at: 0)
        topHooks = Array(topHooks.prefix(limit))
    }
}

struct CompanyVoiceProfile: Codable, Hashable {
    var companyID: String
    var examples: [String]
}

struct CompanyExperimentDecision: Codable, Hashable {
    var experiment: CompanyExperiment
    var winnerCampaign: CompanyGrowthCampaign?
    var loserCampaignIDs: [String]
    var promotedHook: String?
    var event: CompanyEvent?
}

enum CompanyExperimentRunner {
    static func createExperiment(
        companyID: String,
        baseDraft: String,
        hypothesis: String,
        transforms: [(id: String, label: String, creative: String)],
        metric: CompanyExperiment.Metric = .clicksPerImpression,
        allocationPolicy: CompanyExperiment.AllocationPolicy = .fixedSplit,
        accessControl: CompanyAccessControl,
        companyRunHistoryDays: Int = 0
    ) -> CompanyExperiment {
        let enabled = accessControl.experimentationEnabled && companyRunHistoryDays >= 7
        let variants = transforms.enumerated().map { index, transform in
            CompanyExperiment.VariantSpec(
                id: transform.id,
                label: transform.label,
                creative: transform.creative.isEmpty ? baseDraft : transform.creative,
                allocationWeight: enabled ? 1 / Double(max(1, transforms.count)) : 0
            )
        }
        return CompanyExperiment(
            id: "\(companyID)-experiment-\(abs(hypothesis.hashValue))",
            companyID: companyID,
            hypothesis: hypothesis,
            metric: metric,
            variants: variants,
            allocationPolicy: allocationPolicy,
            status: enabled ? .running : .stopped,
            winnerVariantID: nil,
            confidenceLevel: 0,
            decidedAt: nil
        )
    }

    static func allocation(
        experiment: CompanyExperiment,
        results: [String: CompanyGrowthResult] = [:]
    ) -> [String: Double] {
        guard experiment.status == .running else {
            return Dictionary(uniqueKeysWithValues: experiment.variants.map { ($0.id, 0) })
        }
        switch experiment.allocationPolicy {
        case .fixedSplit:
            let weight = 1 / Double(max(1, experiment.variants.count))
            return Dictionary(uniqueKeysWithValues: experiment.variants.map { ($0.id, weight) })
        case .thompsonSampling:
            let scores = experiment.variants.map { variant -> (String, Double) in
                let result = results[variant.id]
                let successes = Double(result?.clicks ?? 0) + 1
                let trials = Double(max(1, result?.impressions ?? 0)) + 2
                return (variant.id, successes / trials)
            }
            let total = max(0.0001, scores.map(\.1).reduce(0, +))
            return Dictionary(uniqueKeysWithValues: scores.map { ($0.0, $0.1 / total) })
        case .sequential:
            let ordered = experiment.variants.sorted { $0.id < $1.id }
            guard let first = ordered.first else { return [:] }
            let firstImpressions = results[first.id]?.impressions ?? 0
            if firstImpressions < 100 {
                return Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, $0.id == first.id ? 1 : 0) })
            }
            let weight = 1 / Double(max(1, ordered.count))
            return Dictionary(uniqueKeysWithValues: ordered.map { ($0.id, weight) })
        }
    }

    static func campaigns(
        for experiment: CompanyExperiment,
        channel: CompanyGrowthCampaign.Channel,
        audience: String
    ) -> [CompanyGrowthCampaign] {
        experiment.variants.map { variant in
            CompanyGrowthCampaign(
                id: "\(experiment.id)-\(variant.id)",
                companyID: experiment.companyID,
                channel: channel,
                audience: audience,
                creative: variant.creative,
                spendLimitUSD: 0,
                approvalState: .approvalRequired,
                complianceChecks: CompanyDistributionEngine.complianceChecks(channel: channel),
                complianceMetadata: nil,
                complianceDecision: .approved,
                rateLimitPerDay: CompanyDistributionEngine.defaultRateLimit(for: channel),
                suppressionList: [],
                nextAction: "Run experiment variant \(variant.label)",
                parentExperimentID: experiment.id
            )
        }
    }

    static func decide(
        experiment: CompanyExperiment,
        campaigns: [CompanyGrowthCampaign],
        results: [String: CompanyGrowthResult],
        confidenceThreshold: Double,
        hookLibrary: CompanyHookLibrary,
        voiceProfile: CompanyVoiceProfile,
        now: Date = Date()
    ) -> (decision: CompanyExperimentDecision, hookLibrary: CompanyHookLibrary, voiceProfile: CompanyVoiceProfile, campaigns: [CompanyGrowthCampaign]) {
        let scored = experiment.variants.compactMap { variant -> (CompanyExperiment.VariantSpec, Double)? in
            guard let result = results[variant.id] else { return nil }
            return (variant, metricValue(experiment.metric, result: result))
        }.sorted { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.id < rhs.0.id }
            return lhs.1 > rhs.1
        }
        guard scored.count >= 2 else {
            var inconclusive = experiment
            inconclusive.status = .inconclusive
            return (.init(experiment: inconclusive, winnerCampaign: nil, loserCampaignIDs: [], promotedHook: nil, event: nil), hookLibrary, voiceProfile, campaigns)
        }
        let confidence = min(1, (scored[0].1 - scored[1].1) / max(0.0001, scored[0].1))
        guard confidence >= confidenceThreshold else {
            var inconclusive = experiment
            inconclusive.status = .inconclusive
            inconclusive.confidenceLevel = confidence
            return (.init(experiment: inconclusive, winnerCampaign: nil, loserCampaignIDs: [], promotedHook: nil, event: nil), hookLibrary, voiceProfile, campaigns)
        }
        let winner = scored[0].0
        var decided = experiment
        decided.status = .decided
        decided.winnerVariantID = winner.id
        decided.confidenceLevel = confidence
        decided.decidedAt = now
        var updatedHookLibrary = hookLibrary
        updatedHookLibrary.promote(winner.creative)
        var updatedVoice = voiceProfile
        updatedVoice.examples.insert(winner.creative, at: 0)
        updatedVoice.examples = Array(updatedVoice.examples.prefix(10))
        var updatedCampaigns = campaigns
        var loserIDs: [String] = []
        for index in updatedCampaigns.indices where updatedCampaigns[index].parentExperimentID == experiment.id {
            if updatedCampaigns[index].id.contains(winner.id) {
                updatedCampaigns[index].approvalState = .approved
            } else {
                updatedCampaigns[index].approvalState = .blocked
                loserIDs.append(updatedCampaigns[index].id)
            }
        }
        let event = CompanyEvent(
            occurredAt: now,
            companyID: experiment.companyID,
            kind: .experimentDecided,
            summary: "Experiment \(experiment.id) winner: \(winner.id)",
            approvalState: "decided",
            metadata: [
                "experimentID": experiment.id,
                "winnerVariantID": winner.id,
                "confidence": String(format: "%.3f", confidence)
            ]
        )
        return (
            .init(
                experiment: decided,
                winnerCampaign: updatedCampaigns.first { $0.id.contains(winner.id) },
                loserCampaignIDs: loserIDs.sorted(),
                promotedHook: winner.creative,
                event: event
            ),
            updatedHookLibrary,
            updatedVoice,
            updatedCampaigns
        )
    }

    private static func metricValue(_ metric: CompanyExperiment.Metric, result: CompanyGrowthResult) -> Double {
        switch metric {
        case .clicksPerImpression:
            return result.impressions > 0 ? Double(result.clicks) / Double(result.impressions) : 0
        case .conversionsPerClick:
            return result.conversionRate
        case .revenuePerImpression:
            return result.impressions > 0 ? result.revenueUSD / Double(result.impressions) : 0
        }
    }
}
