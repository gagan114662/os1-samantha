import Foundation

enum MarketplaceKind: String, Codable, CaseIterable, Hashable {
    case etsy
    case shopify
    case gumroad
    case lemonSqueezy
    case kdp
    case appStore
    case playStore
}

struct MarketplaceListing: Codable, Hashable, Identifiable {
    enum State: String, Codable, CaseIterable, Hashable {
        case draft
        case awaitingApproval
        case live
        case paused
        case takenDown
    }

    var id: String
    var companyID: String
    var marketplace: MarketplaceKind
    var productID: String?
    var state: State
    var listingPayload: [String: String]
    var mediaAttachments: [URL]
    var auditTrail: [CompanyEvent]
}

enum CompanyMarketplaceAdapter {
    static func createDraft(
        companyID: String,
        marketplace: MarketplaceKind,
        title: String,
        priceUSD: Double,
        accessControl: CompanyAccessControl,
        now: Date = Date()
    ) -> MarketplaceListing? {
        guard accessControl.marketplaceAllowlist.contains(marketplace.rawValue) else { return nil }
        let id = "\(companyID)-\(marketplace.rawValue)-\(title.lowercased().replacingOccurrences(of: " ", with: "-"))"
        let event = CompanyEvent(
            occurredAt: now,
            companyID: companyID,
            kind: .externalSideEffect,
            summary: "Created marketplace draft for \(marketplace.rawValue)",
            tool: marketplace.rawValue,
            approvalState: "draft"
        )
        return MarketplaceListing(
            id: id,
            companyID: companyID,
            marketplace: marketplace,
            productID: nil,
            state: .awaitingApproval,
            listingPayload: [
                "title": title,
                "priceUSD": String(format: "%.2f", priceUSD)
            ],
            mediaAttachments: [],
            auditTrail: [event]
        )
    }

    static func publish(_ listing: MarketplaceListing, approved: Bool, now: Date = Date()) -> MarketplaceListing {
        var updated = listing
        updated.state = approved ? .live : .awaitingApproval
        updated.auditTrail.append(
            CompanyEvent(
                occurredAt: now,
                companyID: listing.companyID,
                kind: approved ? .approvalApproved : .approvalRequested,
                summary: approved ? "Published \(listing.marketplace.rawValue) listing." : "Marketplace publish awaits approval.",
                tool: listing.marketplace.rawValue,
                approvalState: approved ? "approved" : "approval-required"
            )
        )
        return updated
    }

    static func fixtureResponse(marketplace: MarketplaceKind, payload: Data) throws -> MarketplaceListing {
        try JSONDecoder().decode(MarketplaceListing.self, from: payload)
    }
}
