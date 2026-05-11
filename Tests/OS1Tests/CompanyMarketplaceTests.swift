import Foundation
import Testing
@testable import OS1

struct CompanyMarketplaceTests {
    @Test
    func nativeMarketplaceAdaptersCreateDraftsWhenAllowlisted() {
        var access = CompanyAccessControl.lockedDown(companyID: "co")
        access.marketplaceAllowlist = ["etsy", "shopify", "gumroad"]

        for marketplace in [MarketplaceKind.etsy, .shopify, .gumroad] {
            let listing = CompanyMarketplaceAdapter.createDraft(
                companyID: "co",
                marketplace: marketplace,
                title: "Budget Spreadsheet",
                priceUSD: 19,
                accessControl: access
            )
            #expect(listing?.state == .awaitingApproval)
            #expect(listing?.auditTrail.first?.kind == .externalSideEffect)
        }
    }

    @Test
    func marketplaceDraftsBlockWithoutAllowlistAndPublishRequiresApproval() {
        let blocked = CompanyMarketplaceAdapter.createDraft(
            companyID: "co",
            marketplace: .etsy,
            title: "Budget Spreadsheet",
            priceUSD: 19,
            accessControl: .lockedDown(companyID: "co")
        )
        #expect(blocked == nil)

        var access = CompanyAccessControl.lockedDown(companyID: "co")
        access.marketplaceAllowlist = ["etsy"]
        let draft = CompanyMarketplaceAdapter.createDraft(companyID: "co", marketplace: .etsy, title: "Budget Spreadsheet", priceUSD: 19, accessControl: access)!
        let pending = CompanyMarketplaceAdapter.publish(draft, approved: false)
        let live = CompanyMarketplaceAdapter.publish(draft, approved: true)

        #expect(pending.state == .awaitingApproval)
        #expect(live.state == .live)
        #expect(live.auditTrail.last?.approvalState == "approved")
    }
}
