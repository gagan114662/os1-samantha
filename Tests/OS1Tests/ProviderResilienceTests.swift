import Foundation
import Testing
@testable import OS1

struct ProviderResilienceTests {
    @Test
    func failedProviderCanFallbackOrBlockAccordingToPolicy() {
        let request = codingRequest(riskTier: .medium)
        let fallback = ModelProviderResilienceEngine.fallback(
            after: "anthropic-claude",
            failure: .rateLimited,
            request: request,
            providers: providers,
            health: health(overrides: ["anthropic-claude": .rateLimited])
        )
        let blocked = ModelProviderResilienceEngine.fallback(
            after: "anthropic-claude",
            failure: .authFailed,
            request: codingRequest(riskTier: .critical),
            providers: providers,
            health: health(overrides: ["anthropic-claude": .authFailed])
        )

        #expect(fallback.action == .fallback)
        #expect(fallback.selectedProviderID == "openai-codex")
        #expect(fallback.reasons.contains("rateLimited"))
        #expect(blocked.action == .block)
        #expect(blocked.reasons == ["criticalTaskAuthFailureRequiresHumanFix"])
    }

    @Test
    func routingDecisionsAreVisibleInEventLogs() {
        let decision = ModelProviderResilienceEngine.route(
            request: codingRequest(),
            providers: providers,
            health: health()
        )

        #expect(decision.action == .route)
        #expect(decision.event.kind == .externalSideEffect)
        #expect(decision.event.actor == "provider-router")
        #expect(decision.event.metadata["selectedProviderID"] == decision.selectedProviderID)
        #expect(decision.event.metadata["fallbackProviderIDs"] == decision.fallbackProviderIDs.joined(separator: ","))
        #expect(!decision.fallbackProviderIDs.isEmpty)
    }

    @Test
    func lowRiskBudgetSensitiveTasksChooseCheaperCapableModel() {
        let request = ModelProviderTaskRequest(
            companyID: "company-1",
            taskType: "classify-leads",
            requiredCapabilities: [.reasoning],
            riskTier: .low,
            expectedInputTokens: 4_000,
            expectedOutputTokens: 500,
            maxCostUSD: 0.01,
            preferCheaperModel: true
        )

        let decision = ModelProviderResilienceEngine.route(
            request: request,
            providers: providers,
            health: health()
        )

        #expect(decision.selectedProviderID == "local-small")
        #expect(decision.estimatedCostUSD == 0)
    }

    @Test
    func routingBlocksWhenNoProviderMeetsCapabilitiesHealthOrBudget() {
        let request = ModelProviderTaskRequest(
            companyID: "company-1",
            taskType: "voice-agent",
            requiredCapabilities: [.realtimeVoice, .toolUse],
            riskTier: .high,
            expectedInputTokens: 1_000,
            expectedOutputTokens: 1_000,
            maxCostUSD: 0.0001,
            preferCheaperModel: false
        )

        let decision = ModelProviderResilienceEngine.route(
            request: request,
            providers: providers,
            health: health()
        )

        #expect(decision.action == .block)
        #expect(decision.reasons == ["noEligibleProvider"])
    }

    @Test
    func usageMetricsSummarizeSpendSuccessAndQualityPerCompanyTaskProvider() {
        let summary = ModelProviderResilienceEngine.summarizeUsage([
            metric(providerID: "openai-codex", cost: 0.10, success: true, quality: 0.9),
            metric(providerID: "openai-codex", cost: 0.20, success: false, quality: 0.3),
            metric(providerID: "local-small", cost: 0, success: true, quality: 0.6)
        ])

        let openai = summary.first { $0.providerID == "openai-codex" }

        #expect(abs((openai?.totalCostUSD ?? 0) - 0.30) < 0.0001)
        #expect(openai?.successRate == 0.5)
        #expect(openai?.averageQualityScore == 0.6)
    }

    @Test
    func canaryComparisonMustPassBeforeDefaultModelSwitch() {
        let incumbent = [
            canary(providerID: "anthropic-claude", taskID: "reasoning", quality: 0.82, latency: 1_000),
            canary(providerID: "anthropic-claude", taskID: "coding", quality: 0.84, latency: 1_100)
        ]
        let goodCandidate = [
            canary(providerID: "openai-codex", taskID: "reasoning", quality: 0.86, latency: 1_000),
            canary(providerID: "openai-codex", taskID: "coding", quality: 0.88, latency: 1_200)
        ]
        let unsafeCandidate = [
            canary(providerID: "openai-codex", taskID: "reasoning", quality: 0.90, latency: 900),
            canary(providerID: "openai-codex", taskID: "coding", quality: 0.92, latency: 900, safe: false)
        ]

        let approved = ModelProviderResilienceEngine.compareCanary(
            incumbent: incumbent,
            candidate: goodCandidate,
            minimumQualityDelta: 0.01
        )
        let rejected = ModelProviderResilienceEngine.compareCanary(
            incumbent: incumbent,
            candidate: unsafeCandidate,
            minimumQualityDelta: 0.01
        )

        #expect(approved.canSwitchDefault)
        #expect(rejected.canSwitchDefault == false)
        #expect(rejected.reasons.contains("candidateFailedSafety"))
    }

    private var providers: [ModelProviderProfile] {
        [
            .init(
                id: "anthropic-claude",
                providerSlug: "anthropic",
                modelID: "claude-opus",
                capabilities: [.reasoning, .coding, .browser, .toolUse, .longContext],
                contextTokens: 200_000,
                inputCostPerMillionTokensUSD: 15,
                outputCostPerMillionTokensUSD: 75,
                p50LatencyMS: 1_800
            ),
            .init(
                id: "openai-codex",
                providerSlug: "openai",
                modelID: "gpt-codex",
                capabilities: [.reasoning, .coding, .toolUse, .longContext],
                contextTokens: 200_000,
                inputCostPerMillionTokensUSD: 5,
                outputCostPerMillionTokensUSD: 20,
                p50LatencyMS: 1_200
            ),
            .init(
                id: "local-small",
                providerSlug: "local",
                modelID: "local-small",
                capabilities: [.reasoning, .lowCost],
                contextTokens: 16_000,
                inputCostPerMillionTokensUSD: 0,
                outputCostPerMillionTokensUSD: 0,
                p50LatencyMS: 400
            )
        ]
    }

    private func codingRequest(riskTier: ModelProviderTaskRequest.RiskTier = .high) -> ModelProviderTaskRequest {
        ModelProviderTaskRequest(
            companyID: "company-1",
            taskType: "code-change",
            requiredCapabilities: [.reasoning, .coding, .toolUse],
            riskTier: riskTier,
            expectedInputTokens: 8_000,
            expectedOutputTokens: 2_000,
            maxCostUSD: 0.50,
            preferCheaperModel: false
        )
    }

    private func health(
        overrides: [String: ModelProviderHealth.Status] = [:]
    ) -> [String: ModelProviderHealth] {
        Dictionary(uniqueKeysWithValues: providers.map { provider in
            let status = overrides[provider.id] ?? .healthy
            return (provider.id, ModelProviderHealth(
                providerID: provider.id,
                status: status,
                historicalSuccessRate: provider.id == "local-small" ? 0.86 : 0.95,
                recentQualityScore: provider.id == "local-small" ? 0.70 : 0.92,
                observedSpendUSD: provider.id == "local-small" ? 0 : 10,
                note: status.rawValue
            ))
        })
    }

    private func metric(
        providerID: String,
        cost: Double,
        success: Bool,
        quality: Double
    ) -> ModelProviderUsageMetric {
        .init(
            id: UUID().uuidString,
            companyID: "company-1",
            providerID: providerID,
            taskType: "code-change",
            inputTokens: 1_000,
            outputTokens: 500,
            costUSD: cost,
            success: success,
            qualityScore: quality
        )
    }

    private func canary(
        providerID: String,
        taskID: String,
        quality: Double,
        latency: Int,
        safe: Bool = true
    ) -> ModelProviderCanaryResult {
        .init(
            id: "\(providerID)-\(taskID)",
            providerID: providerID,
            taskID: taskID,
            outputHash: "\(providerID)-\(taskID)-hash",
            qualityScore: quality,
            latencyMS: latency,
            costUSD: 0.01,
            passedSafetyChecks: safe
        )
    }
}
