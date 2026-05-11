import Foundation
import Testing
@testable import OS1

struct CompanyLegalTests {
    @Test
    func legalReadinessBlocksMissingOwnerPoliciesRefundTermsAndTaxPosture() {
        let readiness = CompanyLegalReadinessEngine.evaluate(nil)

        #expect(!readiness.canAcceptPayment)
        #expect(readiness.blockers.contains("Legal metadata is required before paid launch."))
    }

    @Test
    func completeLegalMetadataCanAcceptPayment() {
        let readiness = CompanyLegalReadinessEngine.evaluate(completeMetadata())

        #expect(readiness.canAcceptPayment)
        #expect(readiness.blockers.isEmpty)
        #expect(readiness.policyLinks["terms"]?.absoluteString.contains("terms") == true)
        #expect(readiness.policyLinks["privacy"]?.absoluteString.contains("privacy") == true)
    }

    @Test
    func requiredTemplatePathsCoverCoreLegalDocuments() {
        let paths = Set(CompanyLegalReadinessEngine.requiredTemplatePaths)

        #expect(paths.contains("docs/legal/terms-of-service-template.md"))
        #expect(paths.contains("docs/legal/privacy-policy-template.md"))
        #expect(paths.contains("docs/legal/refund-policy-template.md"))
        #expect(paths.contains("docs/legal/acceptable-use-policy-template.md"))
        #expect(paths.contains("docs/legal/data-processing-addendum-template.md"))
    }

    private func completeMetadata() -> CompanyLegalMetadata {
        CompanyLegalMetadata(
            companyID: "company-1",
            legalOwner: "OS1 Labs LLC",
            entityName: "OS1 Labs LLC",
            jurisdiction: "Delaware, United States",
            termsOfServiceURL: URL(string: "https://example.com/terms")!,
            privacyPolicyURL: URL(string: "https://example.com/privacy")!,
            refundPolicyURL: URL(string: "https://example.com/refunds")!,
            acceptableUsePolicyURL: URL(string: "https://example.com/aup")!,
            dataProcessingAddendumURL: URL(string: "https://example.com/dpa")!,
            refundTerms: "Refunds available within 14 days for unused service.",
            taxPosture: CompanyTaxPosture(
                salesTaxNexus: ["US"],
                vatGSTExposure: [],
                requires1099Collection: false,
                invoiceTemplateURL: URL(string: "https://example.com/invoice")!,
                bookkeepingCategories: ["softwareRevenue", "paymentFees"]
            ),
            executedContractLinks: [URL(string: "https://example.com/customer-contract")!],
            reviewedAt: Date(timeIntervalSince1970: 1_800_000_000),
            approvalRequestID: "approval-legal-1"
        )
    }
}
