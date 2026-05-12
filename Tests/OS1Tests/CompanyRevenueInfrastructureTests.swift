import Foundation
import Testing
@testable import OS1

struct CompanyRevenueInfrastructureTests {
    @Test
    func dunningAbandonedCheckoutAndPromoCodesRecoverRevenue() {
        let failedAt = Date(timeIntervalSince1970: 0)
        let dunning = CompanyDunningRunner(companyID: "co")
        let checkout = CompanyAbandonedCheckout(
            id: "ab",
            companyID: "co",
            checkoutID: "cs_123",
            customerEmail: "buyer@example.com",
            cartValueUSD: 49,
            expiredAt: failedAt,
            touchesSent: 3,
            recoveredAt: failedAt.addingTimeInterval(4 * 86_400)
        )
        var promo = CompanyPromoCode(id: "p", companyID: "co", code: "SAVE20", discount: .percentOff(20), totalRedemptionCap: 2, redemptions: 0)

        let firstRedeem = promo.redeem()
        let secondRedeem = promo.redeem()
        let thirdRedeem = promo.redeem()

        #expect(dunning.nextAttempt(after: failedAt, attemptsSent: 1)?.timeIntervalSince1970 == Double(3 * 86_400))
        #expect(dunning.subscriptionState(failureDate: failedAt, now: failedAt.addingTimeInterval(8 * 86_400), resolved: false) == "paused")
        #expect(checkout.recoveredRevenueEntry?.note.contains("attribution=recovery") == true)
        #expect(firstRedeem)
        #expect(secondRedeem)
        #expect(!thirdRedeem)
    }

    @Test
    func taxFulfillmentAndAdOptimizationGateRevenueActions() {
        let euTax = CompanyTaxEngine.computeTax(companyID: "co", subtotalUSD: 100, jurisdiction: .euDE, hasValidVATID: true)
        let invoice = CompanyInvoiceGenerator.renderMarkdown(customer: "GmbH", computation: euTax)
        let product = CompanyDigitalProduct(id: "prod", companyID: "co", name: "Prompt Pack", assetPath: "pack.pdf", requiresLicenseKey: true, downloadTTLSeconds: 600, downloadCap: 3)
        let key = FulfillmentService.licenseKey(product: product, orderID: "ord_1")
        let bad = CompanyAdCampaign(id: "bad", companyID: "co", platform: .meta, name: "Bad", dailyBudgetUSD: 20, spendUSD: 500, conversions: 10, state: .active)
        let good = CompanyAdCampaign(id: "good", companyID: "co", platform: .google, name: "Good", dailyBudgetUSD: 20, spendUSD: 50, conversions: 10, state: .active)
        let optimized = CompanyAdAdapter.optimize([bad, good], monthlyBudgetRemainingUSD: 1_000)

        #expect(euTax.taxUSD == 0)
        #expect(euTax.reverseCharge)
        #expect(invoice.contains("Reverse charge"))
        #expect(key?.state == .active)
        #expect(FulfillmentService.revoke(key!).state == .revoked)
        #expect(FulfillmentService.piracyFlag(downloadIPs: (0..<50).map { "10.0.0.\($0)" }, windowSeconds: 3_000))
        #expect(optimized.first { $0.id == "bad" }?.state == .paused)
        #expect((optimized.first { $0.id == "good" }?.dailyBudgetUSD ?? 0) > 20)
    }

    @Test
    func enrichmentBookingVoiceClientAndCoursePrimitivesRoundTrip() throws {
        let score = CompanyLeadScorer.score(icpFit: 0.9, intent: 0.8, verified: .valid)
        let booking = CompanyBookingAdapter.createSingleUseLink(companyID: "co", provider: .calcom, eventTypeID: "intro")
        let phone = CompanyVoiceAgent.provisionNumber(companyID: "co", provider: .twilio, number: "+15551234567", monthlyCostUSD: 3, approved: false)
        let engagement = CompanyEngagement(id: "eng", companyID: "co", clientID: "client", state: .active, monthlyFeeUSD: 2_000, hoursSaved: 40)
        let course = CompanyCourse(id: "course", companyID: "co", provider: .skool, title: "Ops", lessons: ["L1", "L2", "L3", "L4", "L5"])
        let delivered = CompanyCourseAdapter.deliveredLessons(enrolledAt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 15 * 86_400), lessons: course.lessons)

        let encoded = try JSONEncoder().encode(CompanyEnrichedLead(id: "l", companyID: "co", name: "A", email: "a@example.com", role: "Founder", companyName: "Acme", provider: .apollo, verification: .valid, intentScore: score))
        let decoded = try JSONDecoder().decode(CompanyEnrichedLead.self, from: encoded)

        #expect(score > 0.8)
        #expect(!CompanyLeadScorer.blocksOutreach(.valid))
        #expect(decoded.provider == .apollo)
        #expect(booking.singleUse)
        #expect(phone.approvalState == .approvalRequired)
        #expect(CompanyVoiceAgent.outcome(from: "I want to book an appointment") == .booked)
        #expect(ROICalculator.markdown(engagement: engagement, hourlyValueUSD: 100).contains("Estimated value: $4000.0"))
        #expect(DiscoveryInterview.opsCanvas(from: "manual reporting takes hours").contains("Manual work"))
        #expect(delivered == ["L1", "L2", "L3"])
    }
}
