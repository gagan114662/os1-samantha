import Foundation

struct PortfolioAllocationInput: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String { id }
    var expectedReturnUSD: Double
    var lossRiskUSD: Double
    var evidenceScore: Double
    var niche: String
    var revenueSeries: [Double]
}

struct PortfolioAllocationRecommendation: Codable, Hashable {
    var companyID: String
    var score: Double
    var kellyFraction: Double
    var recommendedBudgetUSD: Double
    var reasons: [String]
}

enum PortfolioAllocator {
    static func score(_ input: PortfolioAllocationInput) -> Double {
        let riskAdjustedReturn = input.expectedReturnUSD / max(1, input.lossRiskUSD)
        return max(0, min(100, riskAdjustedReturn * 20 + input.evidenceScore * 50))
    }

    static func kellyFraction(winProbability: Double, winLossRatio: Double) -> Double {
        max(0, min(1, (winProbability * (winLossRatio + 1) - 1) / max(0.0001, winLossRatio)))
    }

    static func recommendations(inputs: [PortfolioAllocationInput], capitalUSD: Double) -> [PortfolioAllocationRecommendation] {
        let scored = inputs.map { input in
            let score = score(input)
            let p = max(0.01, min(0.95, score / 100))
            let b = max(0.1, input.expectedReturnUSD / max(1, input.lossRiskUSD))
            let kelly = kellyFraction(winProbability: p, winLossRatio: b)
            return PortfolioAllocationRecommendation(
                companyID: input.companyID,
                score: score,
                kellyFraction: kelly,
                recommendedBudgetUSD: (capitalUSD * kelly * 100).rounded() / 100,
                reasons: ["score=\(String(format: "%.1f", score))", "kelly=\(String(format: "%.2f", kelly))"]
            )
        }
        return scored.sorted { $0.score == $1.score ? $0.companyID < $1.companyID : $0.score > $1.score }
    }

    static func concentrationAlert(recommendations: [PortfolioAllocationRecommendation], companyID: String, capFraction: Double, capitalUSD: Double) -> Bool {
        guard let budget = recommendations.first(where: { $0.companyID == companyID })?.recommendedBudgetUSD else { return false }
        return budget > capitalUSD * capFraction
    }

    static func nicheDrawdown(niche: String, inputs: [PortfolioAllocationInput], threshold: Double = -0.30) -> Bool {
        let series = inputs.filter { $0.niche == niche }.flatMap(\.revenueSeries)
        guard let first = series.first, let last = series.last, first > 0 else { return false }
        return (last - first) / first <= threshold
    }
}

enum PortfolioCorrelation {
    static func matrix(seriesByCompany: [String: [Double]]) -> [String: [String: Double]] {
        let ids = seriesByCompany.keys.sorted()
        return Dictionary(uniqueKeysWithValues: ids.map { lhs in
            let row = Dictionary(uniqueKeysWithValues: ids.map { rhs in
                (rhs, correlation(seriesByCompany[lhs, default: []], seriesByCompany[rhs, default: []]))
            })
            return (lhs, row)
        })
    }

    static func correlation(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 1 else { return 0 }
        let x = Array(lhs.prefix(count))
        let y = Array(rhs.prefix(count))
        let mx = x.reduce(0, +) / Double(count)
        let my = y.reduce(0, +) / Double(count)
        let numerator = zip(x, y).reduce(0) { $0 + (($1.0 - mx) * ($1.1 - my)) }
        let dx = sqrt(x.reduce(0) { $0 + pow($1 - mx, 2) })
        let dy = sqrt(y.reduce(0) { $0 + pow($1 - my, 2) })
        guard dx > 0, dy > 0 else { return 0 }
        return (numerator / (dx * dy) * 1_000).rounded() / 1_000
    }
}

struct CompanyGraduation: Codable, Hashable {
    enum State: String, Codable, CaseIterable, Hashable {
        case idea
        case validating
        case operating
        case scaling
        case harvested
        case killed
    }

    var companyID: String
    var state: State

    mutating func transition(to next: State) -> Bool {
        guard Self.allowed[state, default: []].contains(next) else { return false }
        state = next
        return true
    }

    private static let allowed: [State: Set<State>] = [
        .idea: [.validating, .killed],
        .validating: [.operating, .killed],
        .operating: [.scaling, .harvested, .killed],
        .scaling: [.harvested, .killed],
        .harvested: [.scaling],
        .killed: []
    ]
}

enum CompanyImagegenPreference: String, Codable, CaseIterable, Hashable {
    case codexOnly
    case codexPreferred
    case externalAllowed
}

struct CompanyImageRequest: Codable, Hashable {
    var companyID: String
    var prompt: String
    var aspectRatio: String
    var voiceVersion: String
    var outputPath: String
}

struct CompanyImageArtifact: Codable, Hashable {
    var path: String
    var provider: String
    var cacheKey: String
    var reusedCache: Bool
    var usageSource: String
}

struct CompanyImageGenerator {
    static let `default` = CompanyImageGenerator()

    func generate(
        request: CompanyImageRequest,
        preference: CompanyImagegenPreference,
        cache: [String: CompanyImageArtifact],
        runCodexImagegen: (CompanyImageRequest) throws -> CompanyImageArtifact,
        runExternalFallback: ((CompanyImageRequest) throws -> CompanyImageArtifact)? = nil
    ) throws -> CompanyImageArtifact {
        let key = Self.cacheKey(request)
        if let cached = cache[key] {
            var copy = cached
            copy.reusedCache = true
            return copy
        }
        do {
            var artifact = try runCodexImagegen(request)
            artifact.provider = "codex-imagegen"
            artifact.usageSource = "codex"
            return artifact
        } catch {
            guard preference != .codexOnly, let runExternalFallback else { throw error }
            return try runExternalFallback(request)
        }
    }

    static func cacheKey(_ request: CompanyImageRequest) -> String {
        CompanyEvent.inputHash(for: "\(request.companyID)|\(request.prompt)|\(request.aspectRatio)|\(request.voiceVersion)")
    }
}

struct CompanyCodexProfile: Codable, Hashable, Identifiable {
    enum Feature: String, Codable, CaseIterable, Hashable {
        case imagegen
        case web
        case vision
        case mcp
        case customTools
        case sandboxMode
        case resume
        case streaming
        case approvalModes
        case toolSearch
        case applyPatch
        case shellExec
        case browserUse
        case chromeUse
        case computerUse
        case githubConnector
        case gmailConnector
        case googleDriveConnector
        case documentsSkill
        case spreadsheetsSkill
        case presentationsSkill
        case skills
        case plugins
        case multiAgent
        case fanout
        case guardianApproval
        case budgetGuardian
        case policyValidation
        case secretsRedaction
        case auditTimeline
        case argsHashing
        case latencyTracking
        case costTracking
        case checkpointing
        case streamingEvents
        case applyPatchStreamingEvents
        case mcpServerBridge
        case customToolRegistration
        case publishHook
        case recordRevenue
        case requestApproval
        case publishLesson
        case chronicle
        case goals
        case memories
        case personality
        case steer
        case voiceProfile
        case hookLibrary
        case ragKnowledgeBase
        case webSearchCitations
        case liveSmokeGates
        case dryRunMode
        case fixtureMode
        case operatorDigest
        case killSwitch
        case anomalyDetector
        case portfolioLessonBus
        case marketplaceAdapters
        case paymentWebhooks
        case sqlite
    }

    let id: String
    var companyID: String
    var usesImagegen: Bool
    var usesWeb: Bool
    var usesVision: Bool
    var usesMCP: Bool
    var sandboxMode: String
    var approvalMode: String
    var resumeEnabled: Bool
    var streamingEnabled: Bool
    var enabledFeatures: Set<Feature> = []

    static func productionDefault(companyID: String) -> CompanyCodexProfile {
        CompanyCodexProfile(
            id: "codex-\(companyID)",
            companyID: companyID,
            usesImagegen: true,
            usesWeb: true,
            usesVision: true,
            usesMCP: true,
            sandboxMode: "workspace-write",
            approvalMode: "on-request",
            resumeEnabled: true,
            streamingEnabled: true,
            enabledFeatures: Set(Feature.allCases)
        )
    }

    func supports(_ feature: Feature) -> Bool {
        enabledFeatures.contains(feature)
    }
}

enum CompanyCodexRuntimeTool {
    static func publishHook(_ hook: String, library: CompanyHookLibrary) -> CompanyHookLibrary {
        var copy = library
        copy.promote(hook)
        return copy
    }

    static func recordRevenue(companyID: String, amountUSD: Double, reference: String) -> CompanyLedgerEntry {
        CompanyLedgerEntry(
            id: "codex-revenue-\(reference)",
            companyID: companyID,
            occurredAt: Date(),
            kind: .revenue,
            category: .sales,
            amountUSD: amountUSD,
            source: "codex-tool",
            sourceReference: reference,
            confidence: .verified,
            note: "recordRevenue reference=\(reference)"
        )
    }

    static func requestApproval(companyID: String, action: String) -> CompanyEvent {
        CompanyEvent(companyID: companyID, kind: .approvalRequested, summary: action, approvalState: "approval-required")
    }

    static func publishLesson(_ lesson: LessonLearned, to url: URL) throws {
        try PortfolioLessonBus.append(lesson, to: url)
    }
}
