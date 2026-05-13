import Foundation

/// Closes acceptance bullet "Allocation recommender: given fleet posteriors
/// and operator capacity, rank top N for extra attention."
///
/// Reuses the Bayesian posterior surface that `CompanyProfitPriorEngine`
/// already exposes in `CompanyFleetRiskControls.swift` — no new prior model,
/// no forked scoring. The recommender's contract is purely how to **allocate
/// operator attention** over the existing posteriors:
///
/// - Operator capacity is expressed in attention slots per day.
/// - Risk appetite biases toward higher-EV-but-uncertain bets (`aggressive`)
///   or stable performers near a kill threshold (`defensive`).
/// - Slots that exceed `topN` are dropped — the recommender refuses to
///   over-allocate beyond what the operator said they can handle.
struct PortfolioAllocationRecommender {
    enum RiskAppetite: String, Codable, Hashable {
        case defensive    // protect what's working — favor low-variance posteriors
        case balanced     // default — EV × tractability with a mild uncertainty bonus
        case aggressive   // chase upside — favor wide credible intervals
    }

    struct OperatorCapacity: Codable, Hashable {
        var attentionSlots: Int
        var riskAppetite: RiskAppetite

        static let standard = OperatorCapacity(attentionSlots: 5, riskAppetite: .balanced)
    }

    struct Recommendation: Codable, Hashable, Identifiable {
        var id: String { companyID }
        var rank: Int
        var companyID: String
        var templateID: String
        var score: Double
        var expectedValueUSD: Double
        var lowerCredibleUSD: Double
        var upperCredibleUSD: Double
        var probabilityMRRExceedsTarget: Double
        var reasoning: [String]

        var credibleSpreadUSD: Double { upperCredibleUSD - lowerCredibleUSD }
    }

    /// Rank up to `min(topN, capacity.attentionSlots)` companies. Ties broken
    /// by companyID for determinism.
    static func rank(
        posteriors: [CompanyProfitPosterior],
        capacity: OperatorCapacity = .standard,
        topN: Int = 7
    ) -> [Recommendation] {
        let slots = max(0, min(topN, capacity.attentionSlots))
        guard slots > 0 else { return [] }
        let scored = posteriors.map { posterior in
            (posterior, score(posterior, appetite: capacity.riskAppetite))
        }
        let sorted = scored.sorted { lhs, rhs in
            if lhs.1 == rhs.1 { return lhs.0.companyID < rhs.0.companyID }
            return lhs.1 > rhs.1
        }
        return sorted.prefix(slots).enumerated().map { offset, pair in
            let (p, s) = pair
            let appetite = capacity.riskAppetite
            return Recommendation(
                rank: offset + 1,
                companyID: p.companyID,
                templateID: p.templateID,
                score: s,
                expectedValueUSD: p.expectedValueUSD,
                lowerCredibleUSD: p.lowerCredibleUSD,
                upperCredibleUSD: p.upperCredibleUSD,
                probabilityMRRExceedsTarget: p.probabilityMRRExceedsTarget,
                reasoning: reasoning(for: p, score: s, appetite: appetite)
            )
        }
    }

    /// Operator-facing one-liner per recommendation slot, suitable for the
    /// dashboard's Top-N table and the digest renderer.
    static func summaryLine(_ recommendation: Recommendation) -> String {
        let band = "$\(Int(recommendation.lowerCredibleUSD))–$\(Int(recommendation.upperCredibleUSD))"
        let prob = String(format: "P(MRR≥target)=%.2f", recommendation.probabilityMRRExceedsTarget)
        return "#\(recommendation.rank) \(recommendation.companyID) EV $\(Int(recommendation.expectedValueUSD)) [\(band)] \(prob)"
    }

    /// Score formula. EV × tractability is the spine; appetite bends the
    /// curve toward / away from uncertainty. We bake the formula into a
    /// pure function so tests can assert determinism.
    private static func score(_ p: CompanyProfitPosterior, appetite: RiskAppetite) -> Double {
        let base = p.expectedValueUSD * p.tractability
        let spread = max(0, p.upperCredibleUSD - p.lowerCredibleUSD)
        // Normalized to EV so the uncertainty bonus is comparable across
        // companies of very different sizes.
        let normalizedSpread = p.expectedValueUSD > 0 ? spread / p.expectedValueUSD : 0
        switch appetite {
        case .balanced:
            return base * (1 + 0.10 * p.probabilityMRRExceedsTarget)
        case .aggressive:
            return base * (1 + 0.25 * normalizedSpread + 0.10 * p.probabilityMRRExceedsTarget)
        case .defensive:
            // Penalize wide spreads — prefer the boringly-good.
            return base * (1 - 0.25 * normalizedSpread) * (1 + 0.20 * p.probabilityMRRExceedsTarget)
        }
    }

    private static func reasoning(
        for p: CompanyProfitPosterior,
        score: Double,
        appetite: RiskAppetite
    ) -> [String] {
        let band = "credible $\(Int(p.lowerCredibleUSD))–$\(Int(p.upperCredibleUSD))"
        let kicker: String
        switch appetite {
        case .balanced:    kicker = "balanced appetite weights EV × tractability"
        case .aggressive:  kicker = "aggressive appetite rewards wide credible spread"
        case .defensive:   kicker = "defensive appetite penalizes wide credible spread"
        }
        return [
            "score \(String(format: "%.2f", score)) (EV × tractability + appetite bonus)",
            band,
            "P(MRR≥target) = \(String(format: "%.2f", p.probabilityMRRExceedsTarget))",
            kicker
        ]
    }
}

extension CompanyProfitPriorEngine {
    /// Convenience bridge: produce an allocation ranking straight from a
    /// nightly snapshot. Lets callers (Doctor row, dashboard, digest
    /// renderer) skip the import dance.
    static func allocationRecommendations(
        snapshot: CompanyProfitNightlySnapshot,
        capacity: PortfolioAllocationRecommender.OperatorCapacity = .standard,
        topN: Int = 7
    ) -> [PortfolioAllocationRecommender.Recommendation] {
        PortfolioAllocationRecommender.rank(
            posteriors: snapshot.posteriors,
            capacity: capacity,
            topN: topN
        )
    }
}
