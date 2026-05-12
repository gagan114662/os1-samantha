import Foundation
import Testing
@testable import OS1

struct CompanyCodexPortfolioInfrastructureTests {
    @Test
    func allocatorCorrelationGraduationAndDrawdownAreDeterministic() {
        let inputs = [
            PortfolioAllocationInput(id: "a", expectedReturnUSD: 100, lossRiskUSD: 20, evidenceScore: 0.8, niche: "seo", revenueSeries: [100, 110, 120]),
            PortfolioAllocationInput(id: "b", expectedReturnUSD: 20, lossRiskUSD: 50, evidenceScore: 0.2, niche: "seo", revenueSeries: [100, 80, 65])
        ]
        let recommendations = PortfolioAllocator.recommendations(inputs: inputs, capitalUSD: 1_000)
        let matrix = PortfolioCorrelation.matrix(seriesByCompany: ["a": [1, 2, 3], "b": [2, 4, 6], "c": [3, 2, 1]])
        var graduation = CompanyGraduation(companyID: "a", state: .idea)
        let advanced = graduation.transition(to: .validating)
        let invalid = graduation.transition(to: .harvested)

        #expect(recommendations.first?.companyID == "a")
        #expect(PortfolioAllocator.kellyFraction(winProbability: 0.6, winLossRatio: 2) > 0)
        #expect(PortfolioAllocator.concentrationAlert(recommendations: recommendations, companyID: "a", capFraction: 0.1, capitalUSD: 1_000))
        #expect(PortfolioAllocator.nicheDrawdown(niche: "seo", inputs: [inputs[1]]))
        #expect(matrix["a"]?["b"] == 1)
        #expect(matrix["a"]?["c"] == -1)
        #expect(advanced)
        #expect(!invalid)
    }

    @Test
    func imagegenUsesCodexPolicyFallbackAndCache() throws {
        let request = CompanyImageRequest(companyID: "co", prompt: "hero image", aspectRatio: "16:9", voiceVersion: "v1", outputPath: "/tmp/hero.png")
        let key = CompanyImageGenerator.cacheKey(request)
        let artifact = CompanyImageArtifact(path: request.outputPath, provider: "codex-imagegen", cacheKey: key, reusedCache: false, usageSource: "codex")
        let cached = try CompanyImageGenerator.default.generate(
            request: request,
            preference: .codexOnly,
            cache: [key: artifact],
            runCodexImagegen: { _ in throw MockImagegenError.quota }
        )
        let fallback = try CompanyImageGenerator.default.generate(
            request: request,
            preference: .externalAllowed,
            cache: [:],
            runCodexImagegen: { _ in throw MockImagegenError.quota },
            runExternalFallback: { request in
                CompanyImageArtifact(path: request.outputPath, provider: "external", cacheKey: key, reusedCache: false, usageSource: "provider")
            }
        )

        #expect(cached.reusedCache)
        #expect(fallback.provider == "external")
        #expect(throws: MockImagegenError.quota) {
            _ = try CompanyImageGenerator.default.generate(
                request: request,
                preference: .codexOnly,
                cache: [:],
                runCodexImagegen: { _ in throw MockImagegenError.quota },
                runExternalFallback: { request in
                    CompanyImageArtifact(path: request.outputPath, provider: "external", cacheKey: key, reusedCache: false, usageSource: "provider")
                }
            )
        }
    }

    @Test
    func codexProfileAndRuntimeToolsRoundTrip() throws {
        let profile = CompanyCodexProfile(
            id: "profile",
            companyID: "co",
            usesImagegen: true,
            usesWeb: true,
            usesVision: true,
            usesMCP: true,
            sandboxMode: "workspace-write",
            approvalMode: "on-request",
            resumeEnabled: true,
            streamingEnabled: true,
            enabledFeatures: [.imagegen, .web, .vision, .mcp]
        )
        let decoded = try JSONDecoder().decode(CompanyCodexProfile.self, from: JSONEncoder().encode(profile))
        let production = CompanyCodexProfile.productionDefault(companyID: "co")
        let library = CompanyCodexRuntimeTool.publishHook("new hook", library: .init(companyID: "co", topHooks: []))
        let revenue = CompanyCodexRuntimeTool.recordRevenue(companyID: "co", amountUSD: 42, reference: "pi_1")
        let approval = CompanyCodexRuntimeTool.requestApproval(companyID: "co", action: "publish first ad")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("codex-lesson-\(UUID().uuidString).jsonl")
        try CompanyCodexRuntimeTool.publishLesson(.init(id: "l", sourceCompanyID: "co", niche: "seo", kind: .offer, evidence: "won", confidence: 0.9), to: url)

        #expect(decoded.usesImagegen && decoded.usesWeb && decoded.usesVision && decoded.usesMCP)
        #expect(CompanyCodexProfile.Feature.allCases.count >= 60)
        #expect(production.supports(.web))
        #expect(production.supports(.vision))
        #expect(production.supports(.mcpServerBridge))
        #expect(production.supports(.customToolRegistration))
        #expect(production.supports(.sandboxMode))
        #expect(production.supports(.approvalModes))
        #expect(production.supports(.resume))
        #expect(production.supports(.streaming))
        #expect(production.supports(.auditTimeline))
        #expect(production.supports(.argsHashing))
        #expect(production.supports(.latencyTracking))
        #expect(production.supports(.costTracking))
        #expect(production.supports(.toolSearch))
        #expect(production.supports(.paymentWebhooks))
        #expect(library.topHooks.first == "new hook")
        #expect(revenue.kind == .revenue)
        #expect(approval.kind == .approvalRequested)
        #expect(try PortfolioLessonBus.load(from: url).count == 1)
    }
}

private enum MockImagegenError: Error, Equatable {
    case quota
}
