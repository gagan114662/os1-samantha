import Foundation

struct CompanyExperimentTemplate: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case pricing
        case landingPage
        case outreach
        case seo
        case ads
    }

    var id: String
    var kind: Kind
    var minimumSampleSize: Int
    var minimumAttributedConversions: Int
    var attributionWindowDays: Int

    static let productionDefaults: [CompanyExperimentTemplate] = [
        .init(
            id: "pricing",
            kind: .pricing,
            minimumSampleSize: 30,
            minimumAttributedConversions: 3,
            attributionWindowDays: 14
        ),
        .init(
            id: "landing-page",
            kind: .landingPage,
            minimumSampleSize: 100,
            minimumAttributedConversions: 5,
            attributionWindowDays: 14
        ),
        .init(
            id: "outreach",
            kind: .outreach,
            minimumSampleSize: 50,
            minimumAttributedConversions: 3,
            attributionWindowDays: 21
        ),
        .init(
            id: "seo",
            kind: .seo,
            minimumSampleSize: 200,
            minimumAttributedConversions: 5,
            attributionWindowDays: 30
        ),
        .init(
            id: "ads",
            kind: .ads,
            minimumSampleSize: 100,
            minimumAttributedConversions: 5,
            attributionWindowDays: 7
        ),
    ]
}

struct CompanyExperimentEvent: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case impression
        case visit
        case signup
        case reply
        case purchase
    }

    var id: String
    var companyID: String
    var experimentID: String
    var cohortID: String
    var subjectID: String?
    var kind: Kind
    var channel: String
    var occurredAt: Date
    var attributedToEventID: String?
    var isBot: Bool
    var isSelfClick: Bool
    var isDuplicateLead: Bool
    var revenueUSD: Double
}

struct CompanyExperimentFunnel: Codable, Hashable {
    var impressions: Int
    var visits: Int
    var signups: Int
    var replies: Int
    var purchases: Int
    var attributedConversions: Int
    var revenueUSD: Double

    var conversionRate: Double {
        guard visits > 0 else { return 0 }
        return Double(purchases + signups + replies) / Double(visits)
    }
}

struct CompanyExperimentResult: Codable, Hashable {
    enum EvidenceStrength: String, Codable, CaseIterable, Hashable {
        case weak
        case moderate
        case strong
    }

    var companyID: String
    var experimentID: String
    var templateKind: CompanyExperimentTemplate.Kind
    var cohortIDs: [String]
    var sampleSize: Int
    var funnel: CompanyExperimentFunnel
    var confidence: Double
    var evidenceStrength: EvidenceStrength
    var uncertaintyNotes: [String]
    var falseSignalWarnings: [String]
    var rawEventIDs: [String]
    var reproducibilityHash: String

    var canSupportLifecyclePromotion: Bool {
        evidenceStrength == .strong && falseSignalWarnings.isEmpty
    }
}

enum CompanyExperimentStatisticsEngine {
    static func evaluate(
        companyID: String,
        experimentID: String,
        template: CompanyExperimentTemplate,
        events: [CompanyExperimentEvent],
        now: Date = Date()
    ) -> CompanyExperimentResult {
        let scoped = events.filter {
            $0.companyID == companyID && $0.experimentID == experimentID
        }
        let clean = scoped.filter { !$0.isBot && !$0.isSelfClick && !$0.isDuplicateLead }
        let windowStart = now.addingTimeInterval(-Double(template.attributionWindowDays) * 86_400)
        let inWindow = clean.filter { $0.occurredAt >= windowStart && $0.occurredAt <= now }
        let attributed = inWindow.filter {
            ($0.kind == .purchase || $0.kind == .signup || $0.kind == .reply) &&
                $0.attributedToEventID != nil
        }
        let funnel = CompanyExperimentFunnel(
            impressions: inWindow.filter { $0.kind == .impression }.count,
            visits: inWindow.filter { $0.kind == .visit }.count,
            signups: inWindow.filter { $0.kind == .signup }.count,
            replies: inWindow.filter { $0.kind == .reply }.count,
            purchases: inWindow.filter { $0.kind == .purchase }.count,
            attributedConversions: attributed.count,
            revenueUSD: inWindow.map(\.revenueUSD).reduce(0, +)
        )
        let sampleSize = inWindow.filter { $0.kind == .visit || $0.kind == .impression }.count
        let warnings = falseSignalWarnings(scoped: scoped, clean: inWindow, funnel: funnel)
        let uncertainty = uncertaintyNotes(
            template: template,
            sampleSize: sampleSize,
            attributedConversions: attributed.count,
            funnel: funnel,
            warnings: warnings
        )
        let confidence = confidenceScore(
            sampleSize: sampleSize,
            attributedConversions: attributed.count,
            template: template,
            warnings: warnings
        )

        return CompanyExperimentResult(
            companyID: companyID,
            experimentID: experimentID,
            templateKind: template.kind,
            cohortIDs: Array(Set(inWindow.map(\.cohortID))).sorted(),
            sampleSize: sampleSize,
            funnel: funnel,
            confidence: confidence,
            evidenceStrength: evidenceStrength(confidence: confidence, uncertaintyNotes: uncertainty),
            uncertaintyNotes: uncertainty,
            falseSignalWarnings: warnings,
            rawEventIDs: scoped.map(\.id).sorted(),
            reproducibilityHash: reproducibilityHash(scoped)
        )
    }

    static func template(kind: CompanyExperimentTemplate.Kind) -> CompanyExperimentTemplate {
        CompanyExperimentTemplate.productionDefaults.first { $0.kind == kind }!
    }

    private static func falseSignalWarnings(
        scoped: [CompanyExperimentEvent],
        clean: [CompanyExperimentEvent],
        funnel: CompanyExperimentFunnel
    ) -> [String] {
        var warnings: [String] = []
        if scoped.contains(where: \.isBot) {
            warnings.append("botTrafficFiltered")
        }
        if scoped.contains(where: \.isSelfClick) {
            warnings.append("selfClicksFiltered")
        }
        if scoped.contains(where: \.isDuplicateLead) {
            warnings.append("duplicateLeadsFiltered")
        }
        if funnel.impressions + funnel.visits > 0 && funnel.attributedConversions == 0 {
            warnings.append("vanityMetricsOnly")
        }
        if clean.contains(where: { $0.channel == "paid" && $0.attributedToEventID == nil && $0.kind != .impression }) {
            warnings.append("paidTrafficAttributionLeakage")
        }
        return warnings.sorted()
    }

    private static func uncertaintyNotes(
        template: CompanyExperimentTemplate,
        sampleSize: Int,
        attributedConversions: Int,
        funnel: CompanyExperimentFunnel,
        warnings: [String]
    ) -> [String] {
        var notes: [String] = []
        if sampleSize < template.minimumSampleSize {
            notes.append("sampleSizeBelowMinimum:\(sampleSize)/\(template.minimumSampleSize)")
        }
        if attributedConversions < template.minimumAttributedConversions {
            notes.append(
                "attributedConversionsBelowMinimum:\(attributedConversions)/\(template.minimumAttributedConversions)"
            )
        }
        if funnel.purchases == 0 && funnel.revenueUSD == 0 {
            notes.append("noVerifiedRevenue")
        }
        notes += warnings
        return Array(Set(notes)).sorted()
    }

    private static func confidenceScore(
        sampleSize: Int,
        attributedConversions: Int,
        template: CompanyExperimentTemplate,
        warnings: [String]
    ) -> Double {
        let sample = min(1, Double(sampleSize) / Double(max(1, template.minimumSampleSize)))
        let conversion = min(1, Double(attributedConversions) / Double(max(1, template.minimumAttributedConversions)))
        let penalty = min(0.6, Double(warnings.count) * 0.15)
        return max(0, min(1, sample * 0.45 + conversion * 0.55 - penalty))
    }

    private static func evidenceStrength(
        confidence: Double,
        uncertaintyNotes: [String]
    ) -> CompanyExperimentResult.EvidenceStrength {
        if confidence >= 0.85 && uncertaintyNotes.isEmpty {
            return .strong
        }
        if confidence >= 0.5 {
            return .moderate
        }
        return .weak
    }

    private static func reproducibilityHash(_ events: [CompanyExperimentEvent]) -> String {
        let canonical = events
            .sorted { $0.id < $1.id }
            .map {
                [
                    $0.id,
                    $0.companyID,
                    $0.experimentID,
                    $0.cohortID,
                    $0.subjectID ?? "",
                    $0.kind.rawValue,
                    $0.channel,
                    "\($0.occurredAt.timeIntervalSince1970)",
                    $0.attributedToEventID ?? "",
                    "\($0.isBot)",
                    "\($0.isSelfClick)",
                    "\($0.isDuplicateLead)",
                    "\($0.revenueUSD)",
                ].joined(separator: "|")
            }
            .joined(separator: "\n")
        return CompanyEvent.inputHash(for: canonical)
    }
}
