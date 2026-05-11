import Foundation

enum CompanyContentChannel: String, Codable, CaseIterable, Hashable {
    case landingPage
    case ad
    case outreach
    case seoPage
    case supportMacro
}

enum CompanyContentClaimType: String, Codable, CaseIterable, Hashable {
    case factual
    case testimonial
    case guarantee
    case pricing
    case comparative
    case regulatedIndustry
    case plagiarism
    case aiDisclosure
}

enum CompanyContentRisk: String, Codable, Hashable {
    case low
    case medium
    case high
}

struct CompanyContentEvidence: Codable, Hashable, Identifiable {
    var id: String
    var claimID: String
    var sourceURL: String
    var note: String
}

struct CompanyBrandStyleGuide: Codable, Hashable {
    var companyID: String
    var voice: String
    var bannedPhrases: [String]
    var requiredDisclosures: [String]
}

struct CompanyContentComplaint: Codable, Hashable, Identifiable {
    var id: String
    var receivedAt: Date
    var category: String
    var summary: String
}

struct CompanyContentPerformance: Codable, Hashable {
    var impressions: Int
    var clicks: Int
    var conversions: Int
    var complaints: [CompanyContentComplaint]

    var complaintRate: Double {
        guard impressions > 0 else { return 0 }
        return Double(complaints.count) / Double(impressions)
    }
}

struct CompanyContentClaim: Codable, Hashable, Identifiable {
    var id: String
    var type: CompanyContentClaimType
    var text: String
    var risk: CompanyContentRisk
}

struct CompanyContentArtifact: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var channel: CompanyContentChannel
    var title: String
    var body: String
    var claims: [CompanyContentClaim]
    var evidence: [CompanyContentEvidence]
    var approvalDecisionID: String?
    var styleGuide: CompanyBrandStyleGuide?
    var performance: CompanyContentPerformance?

    var evidenceURLs: [String] {
        evidence.map(\.sourceURL).sorted()
    }
}

struct CompanyContentReviewPolicy: Codable, Hashable {
    var requiredEvidenceTypes: Set<CompanyContentClaimType>
    var blockedWithoutApprovalTypes: Set<CompanyContentClaimType>
    var regulatedTerms: [String]
    var guaranteeTerms: [String]
    var testimonialTerms: [String]
    var maxComplaintRate: Double

    static let productionDefault = CompanyContentReviewPolicy(
        requiredEvidenceTypes: [.factual, .testimonial, .pricing, .comparative, .regulatedIndustry],
        blockedWithoutApprovalTypes: [.guarantee, .regulatedIndustry],
        regulatedTerms: [
            "tax", "legal", "medical", "financial advice", "mortgage", "real estate", "insurance", "investment"
        ],
        guaranteeTerms: ["guarantee", "guaranteed", "risk-free", "100%", "no risk"],
        testimonialTerms: ["customer said", "client said", "review says", "testimonial", "case study"],
        maxComplaintRate: 0.01
    )
}

struct CompanyContentFinding: Codable, Hashable, Identifiable {
    enum Status: String, Codable, Hashable {
        case warning
        case blocked
        case escalated
    }

    var id: String
    var status: Status
    var claimType: CompanyContentClaimType
    var message: String
    var evidenceRequired: Bool
}

struct CompanyContentReviewDecision: Codable, Hashable {
    enum Status: String, Codable, Hashable {
        case passed
        case needsReview
        case blocked
    }

    var artifactID: String
    var status: Status
    var canPublish: Bool
    var findings: [CompanyContentFinding]
    var evidenceURLs: [String]
    var approvalDecisionID: String?
}

struct CompanyContentQualityScore: Codable, Hashable {
    var originalityScore: Double
    var hookStrength: Double
    var claimSafety: Double
    var brandFit: Double
    var readability: Double
    var plagiarismRisk: Double
    var hallucinationFlags: [String]

    var dimensions: [String: Double] {
        [
            "originalityScore": originalityScore,
            "hookStrength": hookStrength,
            "claimSafety": claimSafety,
            "brandFit": brandFit,
            "readability": readability,
            "plagiarismRisk": plagiarismRisk
        ]
    }
}

struct CompanyContentQualityPolicy: Codable, Hashable {
    var minimumOriginalityScore: Double
    var minimumHookStrength: Double
    var minimumClaimSafety: Double
    var minimumBrandFit: Double
    var minimumReadability: Double
    var maximumPlagiarismRisk: Double

    static let productionDefault = CompanyContentQualityPolicy(
        minimumOriginalityScore: 0.55,
        minimumHookStrength: 0.45,
        minimumClaimSafety: 0.8,
        minimumBrandFit: 0.5,
        minimumReadability: 0.45,
        maximumPlagiarismRisk: 0.35
    )
}

struct CompanyContentQualityDecision: Codable, Hashable {
    enum Status: String, Codable, Hashable {
        case passed
        case blocked
    }

    var status: Status
    var score: CompanyContentQualityScore
    var flags: [String]

    var canApprove: Bool {
        status == .passed
    }
}

struct CompanyContentQualityInput: Codable, Hashable {
    var draft: String
    var channel: CompanyGrowthCampaign.Channel
    var voiceProfile: String
    var publishedCorpus: [String]
    var knowledgeBaseCorpus: [String]
}

enum CompanyContentQualityScorer {
    static func score(
        input: CompanyContentQualityInput,
        policy: CompanyContentQualityPolicy = .productionDefault
    ) -> CompanyContentQualityDecision {
        let draft = input.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let plagiarismRisk = maxSimilarity(draft, against: input.publishedCorpus)
        let originality = max(0, 1 - plagiarismRisk)
        let hook = hookStrength(draft, channel: input.channel)
        let hallucinationFlags = hallucinationFlags(draft: draft, corpus: input.knowledgeBaseCorpus)
        let claimSafety = claimSafety(draft: draft, channel: input.channel, hallucinationFlags: hallucinationFlags)
        let brandFit = brandFit(draft: draft, voiceProfile: input.voiceProfile)
        let readability = readability(draft)
        let score = CompanyContentQualityScore(
            originalityScore: originality,
            hookStrength: hook,
            claimSafety: claimSafety,
            brandFit: brandFit,
            readability: readability,
            plagiarismRisk: plagiarismRisk,
            hallucinationFlags: hallucinationFlags
        )
        var flags: [String] = []
        if score.originalityScore < policy.minimumOriginalityScore { flags.append("originalityScoreBelowThreshold") }
        if score.hookStrength < policy.minimumHookStrength { flags.append("hookStrengthBelowThreshold") }
        if score.claimSafety < policy.minimumClaimSafety { flags.append("claimSafetyBelowThreshold") }
        if score.brandFit < policy.minimumBrandFit { flags.append("brandFitBelowThreshold") }
        if score.readability < policy.minimumReadability { flags.append("readabilityBelowThreshold") }
        if score.plagiarismRisk > policy.maximumPlagiarismRisk { flags.append("plagiarismRiskAboveThreshold") }
        flags += hallucinationFlags.map { "hallucination:\($0)" }

        return CompanyContentQualityDecision(
            status: flags.isEmpty ? .passed : .blocked,
            score: score,
            flags: Array(Set(flags)).sorted()
        )
    }

    private static func maxSimilarity(_ draft: String, against corpus: [String]) -> Double {
        corpus.map { jaccardSimilarity(tokens(draft), tokens($0)) }.max() ?? 0
    }

    private static func jaccardSimilarity(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        let intersection = lhs.intersection(rhs).count
        let union = lhs.union(rhs).count
        return Double(intersection) / Double(max(1, union))
    }

    private static func tokens(_ value: String) -> Set<String> {
        Set(value.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 })
    }

    private static func hookStrength(_ draft: String, channel: CompanyGrowthCampaign.Channel) -> Double {
        let firstLine = draft.split(whereSeparator: \.isNewline).first.map(String.init) ?? draft
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        var score = 0.35
        if trimmed.contains("?") { score += 0.2 }
        if trimmed.count <= 120 { score += 0.2 }
        if trimmed.range(of: #"\b(how|why|mistake|before|after|checklist|save|stop)\b"#, options: [.regularExpression, .caseInsensitive]) != nil { score += 0.15 }
        if channel == .youtubeUpload || channel == .youtubeShort || channel == .tiktokVideo || channel == .instagramReel { score += 0.1 }
        return min(1, score)
    }

    private static func claimSafety(
        draft: String,
        channel: CompanyGrowthCampaign.Channel,
        hallucinationFlags: [String]
    ) -> Double {
        var score = hallucinationFlags.isEmpty ? 1.0 : 0.45
        let lower = draft.lowercased()
        if lower.contains("guaranteed") || lower.contains("risk-free") || lower.contains("100%") {
            score -= 0.35
        }
        if lower.contains("medical advice") || lower.contains("investment advice") || lower.contains("legal advice") {
            score -= 0.2
        }
        if CompanyDistributionEngine.complianceChannel(for: channel) == .socialPlatform, lower.contains("undisclosed affiliate") {
            score -= 0.2
        }
        return max(0, min(1, score))
    }

    private static func brandFit(draft: String, voiceProfile: String) -> Double {
        let profileTokens = tokens(voiceProfile)
        guard !profileTokens.isEmpty else { return 0.6 }
        let overlap = tokens(draft).intersection(profileTokens).count
        return min(1, 0.35 + Double(overlap) / Double(max(1, profileTokens.count)))
    }

    private static func readability(_ draft: String) -> Double {
        let sentences = draft.split { ".!?\n".contains($0) }.filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let words = draft.components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
        guard !words.isEmpty else { return 0 }
        let averageWords = Double(words.count) / Double(max(1, sentences.count))
        if averageWords <= 18 { return 0.9 }
        if averageWords <= 28 { return 0.65 }
        return 0.35
    }

    private static func hallucinationFlags(draft: String, corpus: [String]) -> [String] {
        let joinedCorpus = corpus.joined(separator: "\n").lowercased()
        let patterns = [
            #"\b\d+(?:\.\d+)?%"#,
            #"\$\d+(?:,\d{3})*(?:\.\d+)?"#
        ]
        var flags: [String] = []
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(draft.startIndex..<draft.endIndex, in: draft)
            for match in regex.matches(in: draft, range: range) {
                guard let tokenRange = Range(match.range, in: draft) else { continue }
                let token = String(draft[tokenRange])
                if !joinedCorpus.contains(token.lowercased()) {
                    flags.append("unsupported-claim-\(token)")
                }
            }
        }
        return flags.sorted()
    }
}

enum CompanyContentReviewEngine {
    static func review(
        artifact: CompanyContentArtifact,
        policy: CompanyContentReviewPolicy = .productionDefault
    ) -> CompanyContentReviewDecision {
        let claims = artifact.claims.isEmpty ? inferredClaims(from: artifact, policy: policy) : artifact.claims
        let evidenceByClaim = Dictionary(grouping: artifact.evidence, by: \.claimID)
        var findings: [CompanyContentFinding] = []

        for claim in claims {
            if policy.requiredEvidenceTypes.contains(claim.type),
               evidenceByClaim[claim.id, default: []].isEmpty {
                findings.append(
                    finding(
                        status: claim.risk == .high ? .blocked : .escalated,
                        claim: claim,
                        message: "Claim requires source evidence before publishing.",
                        evidenceRequired: true
                    )
                )
            }
            if policy.blockedWithoutApprovalTypes.contains(claim.type),
               artifact.approvalDecisionID == nil {
                findings.append(
                    finding(
                        status: .blocked,
                        claim: claim,
                        message: "Risky claim requires approval decision before publishing.",
                        evidenceRequired: policy.requiredEvidenceTypes.contains(claim.type)
                    )
                )
            }
        }

        if let styleGuide = artifact.styleGuide {
            for phrase in styleGuide.bannedPhrases where artifact.body.localizedCaseInsensitiveContains(phrase) {
                findings.append(
                    CompanyContentFinding(
                        id: "style-\(phrase.lowercased())",
                        status: .escalated,
                        claimType: .factual,
                        message: "Content uses banned brand phrase: \(phrase).",
                        evidenceRequired: false
                    )
                )
            }
            for disclosure in styleGuide.requiredDisclosures
                where !artifact.body.localizedCaseInsensitiveContains(disclosure) {
                findings.append(
                    CompanyContentFinding(
                        id: "disclosure-\(disclosure.lowercased())",
                        status: .escalated,
                        claimType: .aiDisclosure,
                        message: "Required disclosure is missing: \(disclosure).",
                        evidenceRequired: false
                    )
                )
            }
        }

        if let performance = artifact.performance,
           performance.complaintRate > policy.maxComplaintRate {
            findings.append(
                CompanyContentFinding(
                    id: "performance-complaint-rate",
                    status: .escalated,
                    claimType: .factual,
                    message: "Complaint rate exceeds content quality threshold.",
                    evidenceRequired: false
                )
            )
        }

        let status: CompanyContentReviewDecision.Status
        if findings.contains(where: { $0.status == .blocked }) {
            status = .blocked
        } else if findings.contains(where: { $0.status == .escalated }) {
            status = .needsReview
        } else {
            status = .passed
        }

        return CompanyContentReviewDecision(
            artifactID: artifact.id,
            status: status,
            canPublish: status == .passed && artifact.approvalDecisionID != nil,
            findings: findings.sorted { $0.id < $1.id },
            evidenceURLs: artifact.evidenceURLs,
            approvalDecisionID: artifact.approvalDecisionID
        )
    }

    static func reviewGateChannels() -> Set<CompanyContentChannel> {
        Set(CompanyContentChannel.allCases)
    }

    private static func inferredClaims(
        from artifact: CompanyContentArtifact,
        policy: CompanyContentReviewPolicy
    ) -> [CompanyContentClaim] {
        let body = artifact.body.lowercased()
        var claims: [CompanyContentClaim] = []
        if policy.guaranteeTerms.contains(where: { body.contains($0) }) {
            claims.append(.init(id: "inferred-guarantee", type: .guarantee, text: artifact.body, risk: .high))
        }
        if policy.testimonialTerms.contains(where: { body.contains($0) }) {
            claims.append(.init(id: "inferred-testimonial", type: .testimonial, text: artifact.body, risk: .high))
        }
        if policy.regulatedTerms.contains(where: { body.contains($0) }) {
            claims.append(
                .init(id: "inferred-regulated", type: .regulatedIndustry, text: artifact.body, risk: .high)
            )
        }
        if body.contains("$") || body.contains("price") || body.contains("discount") {
            claims.append(.init(id: "inferred-pricing", type: .pricing, text: artifact.body, risk: .medium))
        }
        if body.contains("better than") || body.contains("#1") || body.contains("best ") {
            claims.append(.init(id: "inferred-comparative", type: .comparative, text: artifact.body, risk: .medium))
        }
        return claims
    }

    private static func finding(
        status: CompanyContentFinding.Status,
        claim: CompanyContentClaim,
        message: String,
        evidenceRequired: Bool
    ) -> CompanyContentFinding {
        CompanyContentFinding(
            id: "\(claim.id)-\(status.rawValue)",
            status: status,
            claimType: claim.type,
            message: message,
            evidenceRequired: evidenceRequired
        )
    }
}
