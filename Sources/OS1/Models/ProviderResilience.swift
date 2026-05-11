import Foundation

enum ModelProviderCapability: String, Codable, CaseIterable, Hashable {
    case reasoning
    case coding
    case browser
    case realtimeVoice
    case toolUse
    case longContext
    case lowCost
}

struct ModelProviderProfile: Codable, Hashable, Identifiable {
    var id: String
    var providerSlug: String
    var modelID: String
    var capabilities: Set<ModelProviderCapability>
    var contextTokens: Int
    var inputCostPerMillionTokensUSD: Double
    var outputCostPerMillionTokensUSD: Double
    var p50LatencyMS: Int

    func estimatedCostUSD(inputTokens: Int, outputTokens: Int) -> Double {
        let input = Double(inputTokens) / 1_000_000 * inputCostPerMillionTokensUSD
        let output = Double(outputTokens) / 1_000_000 * outputCostPerMillionTokensUSD
        return input + output
    }
}

struct ModelProviderHealth: Codable, Hashable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case healthy
        case degraded
        case rateLimited
        case authFailed
        case outage
        case regressed
    }

    var providerID: String
    var status: Status
    var historicalSuccessRate: Double
    var recentQualityScore: Double
    var observedSpendUSD: Double
    var note: String

    var canReceiveNewWork: Bool {
        switch status {
        case .healthy, .degraded:
            return historicalSuccessRate >= 0.8
        case .rateLimited, .authFailed, .outage, .regressed:
            return false
        }
    }
}

struct ModelProviderTaskRequest: Codable, Hashable {
    enum RiskTier: String, Codable, CaseIterable, Hashable {
        case low
        case medium
        case high
        case critical
    }

    var companyID: String
    var taskType: String
    var requiredCapabilities: Set<ModelProviderCapability>
    var riskTier: RiskTier
    var expectedInputTokens: Int
    var expectedOutputTokens: Int
    var maxCostUSD: Double?
    var preferCheaperModel: Bool
}

enum ModelProviderFailure: String, Codable, CaseIterable, Hashable {
    case rateLimited
    case authFailed
    case outage
    case regression
    case contextTooSmall
    case tooExpensive
    case unknown
}

struct ModelProviderRoutingDecision: Codable, Hashable {
    enum Action: String, Codable, CaseIterable, Hashable {
        case route
        case fallback
        case block
    }

    var action: Action
    var selectedProviderID: String?
    var fallbackProviderIDs: [String]
    var estimatedCostUSD: Double?
    var reasons: [String]
    var event: CompanyEvent
}

struct ModelProviderUsageMetric: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var providerID: String
    var taskType: String
    var inputTokens: Int
    var outputTokens: Int
    var costUSD: Double
    var success: Bool
    var qualityScore: Double
}

struct ModelProviderUsageSummary: Codable, Hashable {
    var companyID: String
    var taskType: String
    var providerID: String
    var totalCostUSD: Double
    var successRate: Double
    var averageQualityScore: Double
}

struct ModelProviderCanaryResult: Codable, Hashable, Identifiable {
    var id: String
    var providerID: String
    var taskID: String
    var outputHash: String
    var qualityScore: Double
    var latencyMS: Int
    var costUSD: Double
    var passedSafetyChecks: Bool
}

struct ModelProviderCanaryComparison: Codable, Hashable {
    var incumbentProviderID: String
    var candidateProviderID: String
    var canSwitchDefault: Bool
    var reasons: [String]
}

enum ModelProviderResilienceEngine {
    static func route(
        request: ModelProviderTaskRequest,
        providers: [ModelProviderProfile],
        health: [String: ModelProviderHealth]
    ) -> ModelProviderRoutingDecision {
        let candidates = eligibleProviders(request: request, providers: providers, health: health)
        guard let selected = candidates.first else {
            return decision(
                action: .block,
                companyID: request.companyID,
                taskType: request.taskType,
                selected: nil,
                fallbacks: [],
                cost: nil,
                reasons: ["noEligibleProvider"]
            )
        }

        let cost = selected.estimatedCostUSD(
            inputTokens: request.expectedInputTokens,
            outputTokens: request.expectedOutputTokens
        )
        return decision(
            action: .route,
            companyID: request.companyID,
            taskType: request.taskType,
            selected: selected,
            fallbacks: Array(candidates.dropFirst().map(\.id)),
            cost: cost,
            reasons: ["matchedCapabilities"]
        )
    }

    static func fallback(
        after failedProviderID: String,
        failure: ModelProviderFailure,
        request: ModelProviderTaskRequest,
        providers: [ModelProviderProfile],
        health: [String: ModelProviderHealth]
    ) -> ModelProviderRoutingDecision {
        if failure == .authFailed && request.riskTier == .critical {
            return decision(
                action: .block,
                companyID: request.companyID,
                taskType: request.taskType,
                selected: nil,
                fallbacks: [],
                cost: nil,
                reasons: ["criticalTaskAuthFailureRequiresHumanFix"]
            )
        }

        let candidates = eligibleProviders(request: request, providers: providers, health: health)
            .filter { $0.id != failedProviderID }
        guard let selected = candidates.first else {
            return decision(
                action: .block,
                companyID: request.companyID,
                taskType: request.taskType,
                selected: nil,
                fallbacks: [],
                cost: nil,
                reasons: ["noFallbackAvailable", failure.rawValue]
            )
        }
        let cost = selected.estimatedCostUSD(
            inputTokens: request.expectedInputTokens,
            outputTokens: request.expectedOutputTokens
        )
        return decision(
            action: .fallback,
            companyID: request.companyID,
            taskType: request.taskType,
            selected: selected,
            fallbacks: Array(candidates.dropFirst().map(\.id)),
            cost: cost,
            reasons: ["failed:\(failedProviderID)", failure.rawValue]
        )
    }

    static func summarizeUsage(_ metrics: [ModelProviderUsageMetric]) -> [ModelProviderUsageSummary] {
        let grouped = Dictionary(grouping: metrics) {
            "\($0.companyID)|\($0.taskType)|\($0.providerID)"
        }
        return grouped.values.map { group in
            let first = group[0]
            let successCount = group.filter(\.success).count
            return ModelProviderUsageSummary(
                companyID: first.companyID,
                taskType: first.taskType,
                providerID: first.providerID,
                totalCostUSD: group.map(\.costUSD).reduce(0, +),
                successRate: Double(successCount) / Double(group.count),
                averageQualityScore: group.map(\.qualityScore).reduce(0, +) / Double(group.count)
            )
        }
        .sorted { $0.providerID < $1.providerID }
    }

    static func compareCanary(
        incumbent: [ModelProviderCanaryResult],
        candidate: [ModelProviderCanaryResult],
        minimumQualityDelta: Double = 0,
        maximumLatencyMultiplier: Double = 1.25
    ) -> ModelProviderCanaryComparison {
        let incumbentProvider = incumbent.first?.providerID ?? "incumbent"
        let candidateProvider = candidate.first?.providerID ?? "candidate"
        var reasons: [String] = []

        guard !incumbent.isEmpty, !candidate.isEmpty else {
            return .init(
                incumbentProviderID: incumbentProvider,
                candidateProviderID: candidateProvider,
                canSwitchDefault: false,
                reasons: ["missingCanaryResults"]
            )
        }
        if candidate.contains(where: { !$0.passedSafetyChecks }) {
            reasons.append("candidateFailedSafety")
        }
        let incumbentQuality = average(incumbent.map(\.qualityScore))
        let candidateQuality = average(candidate.map(\.qualityScore))
        if candidateQuality < incumbentQuality + minimumQualityDelta {
            reasons.append("candidateQualityTooLow")
        }
        let incumbentLatency = average(incumbent.map { Double($0.latencyMS) })
        let candidateLatency = average(candidate.map { Double($0.latencyMS) })
        if candidateLatency > incumbentLatency * maximumLatencyMultiplier {
            reasons.append("candidateLatencyTooHigh")
        }

        return .init(
            incumbentProviderID: incumbentProvider,
            candidateProviderID: candidateProvider,
            canSwitchDefault: reasons.isEmpty,
            reasons: reasons
        )
    }

    private static func eligibleProviders(
        request: ModelProviderTaskRequest,
        providers: [ModelProviderProfile],
        health: [String: ModelProviderHealth]
    ) -> [ModelProviderProfile] {
        providers.filter { provider in
            request.requiredCapabilities.isSubset(of: provider.capabilities) &&
                provider.contextTokens >= request.expectedInputTokens + request.expectedOutputTokens &&
                (health[provider.id]?.canReceiveNewWork ?? true) &&
                withinBudget(provider: provider, request: request)
        }
        .sorted { lhs, rhs in
            let lhsCost = lhs.estimatedCostUSD(
                inputTokens: request.expectedInputTokens,
                outputTokens: request.expectedOutputTokens
            )
            let rhsCost = rhs.estimatedCostUSD(
                inputTokens: request.expectedInputTokens,
                outputTokens: request.expectedOutputTokens
            )
            if request.preferCheaperModel || request.riskTier == .low {
                if lhsCost == rhsCost { return quality(lhs, health) > quality(rhs, health) }
                return lhsCost < rhsCost
            }
            if quality(lhs, health) == quality(rhs, health) { return lhsCost < rhsCost }
            return quality(lhs, health) > quality(rhs, health)
        }
    }

    private static func withinBudget(
        provider: ModelProviderProfile,
        request: ModelProviderTaskRequest
    ) -> Bool {
        guard let maxCost = request.maxCostUSD else { return true }
        return provider.estimatedCostUSD(
            inputTokens: request.expectedInputTokens,
            outputTokens: request.expectedOutputTokens
        ) <= maxCost
    }

    private static func quality(
        _ provider: ModelProviderProfile,
        _ health: [String: ModelProviderHealth]
    ) -> Double {
        guard let health = health[provider.id] else { return 1 }
        return health.historicalSuccessRate * 0.7 + health.recentQualityScore * 0.3
    }

    private static func decision(
        action: ModelProviderRoutingDecision.Action,
        companyID: String,
        taskType: String,
        selected: ModelProviderProfile?,
        fallbacks: [String],
        cost: Double?,
        reasons: [String]
    ) -> ModelProviderRoutingDecision {
        ModelProviderRoutingDecision(
            action: action,
            selectedProviderID: selected?.id,
            fallbackProviderIDs: fallbacks,
            estimatedCostUSD: cost,
            reasons: reasons,
            event: CompanyEvent(
                companyID: companyID,
                actor: "provider-router",
                kind: .externalSideEffect,
                summary: "Provider routing \(action.rawValue) for \(taskType)",
                tool: selected?.modelID,
                costUSD: cost,
                riskTier: nil,
                approvalState: "policy",
                metadata: [
                    "action": action.rawValue,
                    "selectedProviderID": selected?.id ?? "",
                    "fallbackProviderIDs": fallbacks.joined(separator: ","),
                    "reasons": reasons.joined(separator: ","),
                ]
            )
        )
    }

    private static func average(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        return values.reduce(0, +) / Double(values.count)
    }
}
