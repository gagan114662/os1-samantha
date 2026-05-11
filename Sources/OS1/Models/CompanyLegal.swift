import Foundation

struct CompanyTaxPosture: Codable, Hashable {
    var salesTaxNexus: [String]
    var vatGSTExposure: [String]
    var requires1099Collection: Bool
    var invoiceTemplateURL: URL?
    var bookkeepingCategories: [String]

    var blockers: [String] {
        var values: [String] = []
        if bookkeepingCategories.isEmpty { values.append("Bookkeeping categories are required.") }
        if invoiceTemplateURL == nil { values.append("Invoice template link is required.") }
        return values
    }
}

struct CompanyLegalMetadata: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var legalOwner: String
    var entityName: String
    var jurisdiction: String
    var termsOfServiceURL: URL?
    var privacyPolicyURL: URL?
    var refundPolicyURL: URL?
    var acceptableUsePolicyURL: URL?
    var dataProcessingAddendumURL: URL?
    var refundTerms: String
    var taxPosture: CompanyTaxPosture
    var executedContractLinks: [URL]
    var reviewedAt: Date?
    var approvalRequestID: String?

    init(
        id: String = UUID().uuidString,
        companyID: String,
        legalOwner: String,
        entityName: String,
        jurisdiction: String,
        termsOfServiceURL: URL? = nil,
        privacyPolicyURL: URL? = nil,
        refundPolicyURL: URL? = nil,
        acceptableUsePolicyURL: URL? = nil,
        dataProcessingAddendumURL: URL? = nil,
        refundTerms: String,
        taxPosture: CompanyTaxPosture,
        executedContractLinks: [URL] = [],
        reviewedAt: Date? = nil,
        approvalRequestID: String? = nil
    ) {
        self.id = id
        self.companyID = companyID
        self.legalOwner = legalOwner.trimmingCharacters(in: .whitespacesAndNewlines)
        self.entityName = entityName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.jurisdiction = jurisdiction.trimmingCharacters(in: .whitespacesAndNewlines)
        self.termsOfServiceURL = termsOfServiceURL
        self.privacyPolicyURL = privacyPolicyURL
        self.refundPolicyURL = refundPolicyURL
        self.acceptableUsePolicyURL = acceptableUsePolicyURL
        self.dataProcessingAddendumURL = dataProcessingAddendumURL
        self.refundTerms = refundTerms.trimmingCharacters(in: .whitespacesAndNewlines)
        self.taxPosture = taxPosture
        self.executedContractLinks = executedContractLinks
        self.reviewedAt = reviewedAt
        self.approvalRequestID = approvalRequestID
    }
}

struct CompanyLegalReadiness: Codable, Hashable {
    var companyID: String
    var blockers: [String]
    var policyLinks: [String: URL]
    var reviewedAt: Date?
    var approvalRequestID: String?

    var canAcceptPayment: Bool {
        blockers.isEmpty
    }
}

enum CompanyLegalReadinessEngine {
    static let requiredTemplatePaths = [
        "docs/legal/terms-of-service-template.md",
        "docs/legal/privacy-policy-template.md",
        "docs/legal/refund-policy-template.md",
        "docs/legal/acceptable-use-policy-template.md",
        "docs/legal/data-processing-addendum-template.md"
    ]

    static func evaluate(_ metadata: CompanyLegalMetadata?) -> CompanyLegalReadiness {
        guard let metadata else {
            return .init(
                companyID: "",
                blockers: ["Legal metadata is required before paid launch."],
                policyLinks: [:],
                reviewedAt: nil,
                approvalRequestID: nil
            )
        }

        var blockers: [String] = []
        if metadata.legalOwner.isEmpty { blockers.append("Legal owner is required.") }
        if metadata.entityName.isEmpty { blockers.append("Entity name is required.") }
        if metadata.jurisdiction.isEmpty { blockers.append("Jurisdiction is required.") }
        if metadata.termsOfServiceURL == nil { blockers.append("Terms of service link is required.") }
        if metadata.privacyPolicyURL == nil { blockers.append("Privacy policy link is required.") }
        if metadata.refundPolicyURL == nil { blockers.append("Refund policy link is required.") }
        if metadata.acceptableUsePolicyURL == nil { blockers.append("Acceptable use policy link is required.") }
        if metadata.refundTerms.isEmpty { blockers.append("Refund terms are required.") }
        if metadata.reviewedAt == nil { blockers.append("Legal review timestamp is required.") }
        blockers.append(contentsOf: metadata.taxPosture.blockers)

        var links: [String: URL] = [:]
        links["terms"] = metadata.termsOfServiceURL
        links["privacy"] = metadata.privacyPolicyURL
        links["refund"] = metadata.refundPolicyURL
        links["acceptableUse"] = metadata.acceptableUsePolicyURL
        links["dpa"] = metadata.dataProcessingAddendumURL

        return .init(
            companyID: metadata.companyID,
            blockers: blockers,
            policyLinks: links,
            reviewedAt: metadata.reviewedAt,
            approvalRequestID: metadata.approvalRequestID
        )
    }
}
