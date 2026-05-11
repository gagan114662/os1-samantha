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
