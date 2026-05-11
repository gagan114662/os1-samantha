import Foundation
import Testing
@testable import OS1

struct CompanyContentReviewTests {
    @Test
    func publicContentCannotPublishWithoutPassingClaimsAndApproval() {
        let artifact = content(
            body: "Our product helps teams reconcile invoices.",
            claims: [
                .init(id: "fact", type: .factual, text: "helps teams reconcile invoices", risk: .medium)
            ],
            evidence: [
                .init(id: "evidence", claimID: "fact", sourceURL: "https://example.com/demo", note: "Demo")
            ],
            approvalDecisionID: nil
        )

        let unapproved = CompanyContentReviewEngine.review(artifact: artifact)
        var approvedArtifact = artifact
        approvedArtifact.approvalDecisionID = "approval-1"
        let approved = CompanyContentReviewEngine.review(artifact: approvedArtifact)

        #expect(unapproved.status == .passed)
        #expect(!unapproved.canPublish)
        #expect(approved.status == .passed)
        #expect(approved.canPublish)
        #expect(approved.evidenceURLs == ["https://example.com/demo"])
        #expect(approved.approvalDecisionID == "approval-1")
    }

    @Test
    func misleadingGuaranteeIsBlocked() {
        let artifact = content(
            body: "We guarantee 100% results in 7 days with no risk.",
            claims: [],
            evidence: [],
            approvalDecisionID: nil
        )

        let decision = CompanyContentReviewEngine.review(artifact: artifact)

        #expect(decision.status == .blocked)
        #expect(!decision.canPublish)
        #expect(decision.findings.contains { $0.claimType == .guarantee && $0.status == .blocked })
    }

    @Test
    func unsupportedTestimonialIsBlocked() {
        let artifact = content(
            body: "A customer said this doubled revenue overnight.",
            claims: [],
            evidence: [],
            approvalDecisionID: "approval-1"
        )

        let decision = CompanyContentReviewEngine.review(artifact: artifact)

        #expect(decision.status == .blocked)
        #expect(decision.findings.contains { $0.claimType == .testimonial && $0.evidenceRequired })
    }

    @Test
    func regulatedClaimEscalatesAndBlocksWithoutApproval() {
        let artifact = content(
            channel: .seoPage,
            body: "This tax strategy eliminates audit risk for real estate investors.",
            claims: [],
            evidence: [
                .init(
                    id: "irs",
                    claimID: "inferred-regulated",
                    sourceURL: "https://irs.gov/example",
                    note: "Tax source"
                )
            ],
            approvalDecisionID: nil
        )

        let decision = CompanyContentReviewEngine.review(artifact: artifact)

        #expect(decision.status == .blocked)
        #expect(decision.findings.contains { $0.claimType == .regulatedIndustry })
        #expect(!decision.canPublish)
    }

    @Test
    func reviewGatesCoverAllPublicChannelsAndStyleGuides() {
        let gated = CompanyContentReviewEngine.reviewGateChannels()
        var artifact = content(
            channel: .supportMacro,
            body: "This was written with AI.",
            claims: [],
            evidence: [],
            approvalDecisionID: "approval-1"
        )
        artifact.styleGuide = CompanyBrandStyleGuide(
            companyID: "co",
            voice: "Plainspoken and specific",
            bannedPhrases: ["magic"],
            requiredDisclosures: ["written with AI"]
        )
        let clean = CompanyContentReviewEngine.review(artifact: artifact)
        artifact.body = "This magic answer hides the disclosure."
        let flagged = CompanyContentReviewEngine.review(artifact: artifact)

        #expect(gated == Set(CompanyContentChannel.allCases))
        #expect(clean.status == .passed)
        #expect(flagged.status == .needsReview)
    }

    @Test
    func performanceComplaintsEscalateContentReview() {
        let artifact = content(
            body: "Helpful support macro.",
            claims: [],
            evidence: [],
            approvalDecisionID: "approval-1",
            performance: CompanyContentPerformance(
                impressions: 100,
                clicks: 10,
                conversions: 2,
                complaints: [
                    CompanyContentComplaint(
                        id: "complaint-1",
                        receivedAt: Date(timeIntervalSince1970: 1_700_000_000),
                        category: "misleading",
                        summary: "Customer says macro overpromised."
                    ),
                    CompanyContentComplaint(
                        id: "complaint-2",
                        receivedAt: Date(timeIntervalSince1970: 1_700_000_100),
                        category: "quality",
                        summary: "Customer says it was not useful."
                    )
                ]
            )
        )

        let decision = CompanyContentReviewEngine.review(artifact: artifact)

        #expect(decision.status == .needsReview)
        #expect(decision.findings.contains { $0.id == "performance-complaint-rate" })
    }

    private func content(
        channel: CompanyContentChannel = .landingPage,
        body: String,
        claims: [CompanyContentClaim],
        evidence: [CompanyContentEvidence],
        approvalDecisionID: String?,
        performance: CompanyContentPerformance? = nil
    ) -> CompanyContentArtifact {
        CompanyContentArtifact(
            id: "content-1",
            companyID: "co",
            channel: channel,
            title: "Content",
            body: body,
            claims: claims,
            evidence: evidence,
            approvalDecisionID: approvalDecisionID,
            styleGuide: nil,
            performance: performance
        )
    }
}
