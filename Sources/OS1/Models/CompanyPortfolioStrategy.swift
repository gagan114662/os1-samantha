import Foundation

struct CompanyPortfolioObjectives: Codable, Hashable {
    var cashGenerationWeight: Double
    var learningVelocityWeight: Double
    var riskControlWeight: Double
    var channelDiversityWeight: Double
    var timeHorizonDays: Int

    static let productionDefault = CompanyPortfolioObjectives(
        cashGenerationWeight: 0.36,
        learningVelocityWeight: 0.22,
        riskControlWeight: 0.24,
        channelDiversityWeight: 0.18,
        timeHorizonDays: 90
    )
}

struct CompanyPortfolioRules: Codable, Hashable {
    var maxCompaniesPerChannel: Int
    var maxCompaniesPerNiche: Int
    var maxCompaniesPerBrand: Int
    var maxCompaniesPerAccount: Int
    var maxCompaniesPerProvider: Int
    var defaultBudgetUSD: Double
    var maxBudgetUSD: Double
    var maxComputeSlotsPerCompany: Int

    static let productionDefault = CompanyPortfolioRules(
        maxCompaniesPerChannel: 8,
        maxCompaniesPerNiche: 4,
        maxCompaniesPerBrand: 1,
        maxCompaniesPerAccount: 6,
        maxCompaniesPerProvider: 25,
        defaultBudgetUSD: 25,
        maxBudgetUSD: 250,
        maxComputeSlotsPerCompany: 2
    )
}

struct CompanyPortfolioProfile: Codable, Hashable, Identifiable {
    var id: String { companyID }
    var companyID: String
    var title: String
    var channel: String
    var niche: String
    var brand: String
    var account: String
    var provider: String
    var status: CodexSession.Status
    var lifecycleStage: CodexSession.LifecycleStage
    var expectedValueUSD: Double
    var evidenceScore: Int
    var contributionMargin: Double?
    var risk: CompanyIdea.RiskTier
    var learningSummary: String?

    var preservesLearning: Bool {
        lifecycleStage == .killed || lifecycleStage == .pivoting || status == .killed
    }
}

struct CompanyPortfolioConcentrationRisk: Codable, Hashable, Identifiable {
    enum Dimension: String, Codable, Hashable {
        case channel
        case niche
        case brand
        case account
        case provider
    }

    var id: String { "\(dimension.rawValue):\(value)" }
    var dimension: Dimension
    var value: String
    var companyIDs: [String]
    var limit: Int

    var count: Int { companyIDs.count }
    var summary: String {
        "\(dimension.rawValue) \(value) has \(count) companies over limit \(limit)"
    }
}

struct CompanyPortfolioAllocation: Codable, Hashable, Identifiable {
    var id: String { companyID }
    var companyID: String
    var rank: Int
    var priorityScore: Double
    var recommendedBudgetUSD: Double
    var computeSlots: Int
    var canStartHeartbeat: Bool
    var reasons: [String]
}

struct CompanyPortfolioDashboard: Codable, Hashable {
    var objectives: CompanyPortfolioObjectives
    var totalCompanies: Int
    var cashGenerationUSD: Double
    var expectedValueUSD: Double
    var channelCount: Int
    var allocations: [CompanyPortfolioAllocation]
    var concentrationRisks: [CompanyPortfolioConcentrationRisk]
    var preservedLearnings: [String: String]

    var allocationByCompanyID: [String: CompanyPortfolioAllocation] {
        Dictionary(uniqueKeysWithValues: allocations.map { ($0.companyID, $0) })
    }
}

enum CompanyPortfolioStrategyEngine {
    static func dashboard(
        profiles: [CompanyPortfolioProfile],
        objectives: CompanyPortfolioObjectives = .productionDefault,
        rules: CompanyPortfolioRules = .productionDefault
    ) -> CompanyPortfolioDashboard {
        let risks = concentrationRisks(profiles: profiles, rules: rules)
        let allocations = allocationsForProfiles(profiles, objectives: objectives, rules: rules, risks: risks)
        let learnings = Dictionary(uniqueKeysWithValues: profiles.compactMap { profile -> (String, String)? in
            guard profile.preservesLearning,
                  let learning = profile.learningSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !learning.isEmpty
            else { return nil }
            return (profile.companyID, learning)
        })

        return CompanyPortfolioDashboard(
            objectives: objectives,
            totalCompanies: profiles.count,
            cashGenerationUSD: profiles.map(\.expectedValueUSD).filter { $0 > 0 }.reduce(0, +),
            expectedValueUSD: profiles.map(\.expectedValueUSD).reduce(0, +),
            channelCount: Set(profiles.map { normalized($0.channel) }).count,
            allocations: allocations,
            concentrationRisks: risks,
            preservedLearnings: learnings
        )
    }

    static func rankIdeas(
        _ ideas: [CompanyIdea],
        preservedLearnings: [String: String]
    ) -> [CompanyIdea] {
        ideas.sorted { lhs, rhs in
            let lhsScore = learningAdjustedScore(lhs, learnings: preservedLearnings)
            let rhsScore = learningAdjustedScore(rhs, learnings: preservedLearnings)
            if lhsScore == rhsScore { return lhs.title < rhs.title }
            return lhsScore > rhsScore
        }
    }

    private static func allocationsForProfiles(
        _ profiles: [CompanyPortfolioProfile],
        objectives: CompanyPortfolioObjectives,
        rules: CompanyPortfolioRules,
        risks: [CompanyPortfolioConcentrationRisk]
    ) -> [CompanyPortfolioAllocation] {
        let riskIDsByCompany = risks.reduce(into: [String: [CompanyPortfolioConcentrationRisk]]()) { partial, risk in
            for companyID in risk.companyIDs {
                partial[companyID, default: []].append(risk)
            }
        }
        let channels = Set(profiles.map { normalized($0.channel) })
        let scored = profiles.map { profile -> (CompanyPortfolioProfile, Double, [String], Bool) in
            let concentration = riskIDsByCompany[profile.companyID, default: []]
            let reasons = allocationReasons(profile: profile, concentration: concentration)
            let score = priorityScore(
                profile: profile,
                objectives: objectives,
                channelCount: max(1, channels.count),
                concentrationCount: concentration.count
            )
            let canStart = profile.status != .killed &&
                profile.lifecycleStage != .killed &&
                concentration.contains(where: { $0.dimension == .brand || $0.dimension == .account }) == false
            return (profile, score, reasons, canStart)
        }
        .sorted {
            if $0.1 == $1.1 { return $0.0.companyID < $1.0.companyID }
            return $0.1 > $1.1
        }

        return scored.enumerated().map { index, item in
            let budgetMultiplier = min(1.0, max(0.2, item.1 / 100.0))
            let budget = min(rules.maxBudgetUSD, max(rules.defaultBudgetUSD, rules.maxBudgetUSD * budgetMultiplier))
            let slots = item.1 >= 85 ? rules.maxComputeSlotsPerCompany : 1
            return CompanyPortfolioAllocation(
                companyID: item.0.companyID,
                rank: index + 1,
                priorityScore: (item.1 * 100).rounded() / 100,
                recommendedBudgetUSD: (budget * 100).rounded() / 100,
                computeSlots: slots,
                canStartHeartbeat: item.3,
                reasons: item.2
            )
        }
    }

    private static func concentrationRisks(
        profiles: [CompanyPortfolioProfile],
        rules: CompanyPortfolioRules
    ) -> [CompanyPortfolioConcentrationRisk] {
        [
            risks(for: profiles, dimension: .channel, limit: rules.maxCompaniesPerChannel) { $0.channel },
            risks(for: profiles, dimension: .niche, limit: rules.maxCompaniesPerNiche) { $0.niche },
            risks(for: profiles, dimension: .brand, limit: rules.maxCompaniesPerBrand) { $0.brand },
            risks(for: profiles, dimension: .account, limit: rules.maxCompaniesPerAccount) { $0.account },
            risks(for: profiles, dimension: .provider, limit: rules.maxCompaniesPerProvider) { $0.provider }
        ]
        .flatMap { $0 }
        .sorted {
            if $0.dimension.rawValue == $1.dimension.rawValue { return $0.value < $1.value }
            return $0.dimension.rawValue < $1.dimension.rawValue
        }
    }

    private static func risks(
        for profiles: [CompanyPortfolioProfile],
        dimension: CompanyPortfolioConcentrationRisk.Dimension,
        limit: Int,
        value: (CompanyPortfolioProfile) -> String
    ) -> [CompanyPortfolioConcentrationRisk] {
        let grouped = Dictionary(grouping: profiles) { normalized(value($0)) }
        return grouped.compactMap { key, companies in
            guard companies.count > limit else { return nil }
            return CompanyPortfolioConcentrationRisk(
                dimension: dimension,
                value: key,
                companyIDs: companies.map(\.companyID).sorted(),
                limit: limit
            )
        }
    }

    private static func priorityScore(
        profile: CompanyPortfolioProfile,
        objectives: CompanyPortfolioObjectives,
        channelCount: Int,
        concentrationCount: Int
    ) -> Double {
        let cash = min(40, max(0, profile.expectedValueUSD / 10))
        let evidence = Double(profile.evidenceScore)
        let learning = profile.lifecycleStage == .validating || profile.lifecycleStage == .building ? 25.0 : 8.0
        let margin = max(0, min(20, (profile.contributionMargin ?? 0) * 20))
        let diversity = 20.0 / Double(channelCount)
        let riskPenalty = riskPenalty(profile.risk) + Double(concentrationCount * 8)
        return cash * objectives.cashGenerationWeight +
            evidence * 0.3 +
            learning * objectives.learningVelocityWeight +
            margin +
            diversity * objectives.channelDiversityWeight -
            riskPenalty * objectives.riskControlWeight
    }

    private static func allocationReasons(
        profile: CompanyPortfolioProfile,
        concentration: [CompanyPortfolioConcentrationRisk]
    ) -> [String] {
        var reasons: [String] = []
        if profile.expectedValueUSD > 0 { reasons.append("positive expected value") }
        if profile.evidenceScore >= 50 { reasons.append("strong evidence") }
        if profile.contributionMargin ?? 0 > 0.3 { reasons.append("healthy margin") }
        if profile.lifecycleStage == .validating { reasons.append("learning velocity") }
        if !concentration.isEmpty {
            let dimensions = concentration.map(\.dimension.rawValue).joined(separator: ",")
            reasons.append("concentration: \(dimensions)")
        }
        return reasons.isEmpty ? ["portfolio baseline"] : reasons
    }

    private static func learningAdjustedScore(
        _ idea: CompanyIdea,
        learnings: [String: String]
    ) -> Int {
        let text = [idea.title, idea.icp, idea.offer, idea.channel]
            .joined(separator: " ")
            .lowercased()
        let lessonPenalty = learnings.values.reduce(0) { partial, lesson in
            let normalizedLesson = lesson.lowercased()
            let overlapsIdea = text
                .components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { $0.count >= 4 }
                .contains { normalizedLesson.contains($0) }
            if normalizedLesson.contains("avoid") && overlapsIdea {
                return partial + 4
            }
            if overlapsIdea || normalizedLesson.contains(idea.riskTier.rawValue) {
                return partial + 2
            }
            return partial
        }
        return idea.score - lessonPenalty
    }

    private static func riskPenalty(_ risk: CompanyIdea.RiskTier) -> Double {
        switch risk {
        case .low: return 0
        case .medium: return 8
        case .high: return 18
        case .critical: return 40
        }
    }

    private static func normalized(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "unknown" : trimmed
    }
}
