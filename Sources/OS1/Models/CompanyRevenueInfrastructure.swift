import Foundation

struct CompanyDunningRunner: Codable, Hashable {
    var companyID: String
    var retryOffsetsDays: [Int] = [1, 3, 7]

    func nextAttempt(after failureDate: Date, attemptsSent: Int) -> Date? {
        guard attemptsSent < retryOffsetsDays.count else { return nil }
        return failureDate.addingTimeInterval(Double(retryOffsetsDays[attemptsSent]) * 86_400)
    }

    func subscriptionState(failureDate: Date, now: Date, resolved: Bool) -> String {
        if resolved { return "active" }
        return now.timeIntervalSince(failureDate) >= 7 * 86_400 ? "paused" : "dunning"
    }
}

struct CompanyAbandonedCheckout: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var checkoutID: String
    var customerEmail: String
    var cartValueUSD: Double
    var expiredAt: Date
    var touchesSent: Int
    var recoveredAt: Date?

    var recoveredRevenueEntry: CompanyLedgerEntry? {
        guard let recoveredAt else { return nil }
        return CompanyLedgerEntry(
            id: "recovery-\(checkoutID)",
            companyID: companyID,
            occurredAt: recoveredAt,
            kind: .revenue,
            category: .sales,
            amountUSD: cartValueUSD,
            source: "abandoned-checkout",
            sourceReference: checkoutID,
            confidence: .verified,
            note: "attribution=recovery checkout=\(checkoutID)"
        )
    }
}

struct CompanyPromoCode: Codable, Hashable, Identifiable {
    enum Discount: Codable, Hashable {
        case percentOff(Int)
        case amountOffUSD(Double)
    }

    let id: String
    var companyID: String
    var code: String
    var discount: Discount
    var totalRedemptionCap: Int
    var redemptions: Int

    var isExhausted: Bool { redemptions >= totalRedemptionCap }

    mutating func redeem() -> Bool {
        guard !isExhausted else { return false }
        redemptions += 1
        return true
    }
}

enum CompanyTaxJurisdiction: String, Codable, CaseIterable, Hashable {
    case usCA
    case euDE
    case uk
    case canadaON
}

struct CompanyTaxComputation: Codable, Hashable {
    var companyID: String
    var jurisdiction: CompanyTaxJurisdiction
    var subtotalUSD: Double
    var taxUSD: Double
    var reverseCharge: Bool
    var provider: String
}

struct CompanyTaxNexus: Codable, Hashable {
    var companyID: String
    var jurisdiction: CompanyTaxJurisdiction
    var revenueUSD: Double
    var thresholdUSD: Double

    var requiresApprovalEvent: Bool { revenueUSD >= thresholdUSD }
}

enum CompanyTaxEngine {
    static func computeTax(
        companyID: String,
        subtotalUSD: Double,
        jurisdiction: CompanyTaxJurisdiction,
        hasValidVATID: Bool = false
    ) -> CompanyTaxComputation {
        let rate: Double
        switch jurisdiction {
        case .usCA:
            rate = 0.0725
        case .euDE:
            rate = hasValidVATID ? 0 : 0.19
        case .uk:
            rate = hasValidVATID ? 0 : 0.20
        case .canadaON:
            rate = 0.13
        }
        return CompanyTaxComputation(
            companyID: companyID,
            jurisdiction: jurisdiction,
            subtotalUSD: subtotalUSD,
            taxUSD: (subtotalUSD * rate * 100).rounded() / 100,
            reverseCharge: hasValidVATID && (jurisdiction == .euDE || jurisdiction == .uk),
            provider: "stripe-tax"
        )
    }
}

struct CompanyInvoiceGenerator {
    static func renderMarkdown(customer: String, computation: CompanyTaxComputation) -> String {
        let note = computation.reverseCharge ? "\nReverse charge: customer VAT ID validated." : ""
        return """
        # Invoice
        Customer: \(customer)
        Subtotal: $\(String(format: "%.2f", computation.subtotalUSD))
        Tax: $\(String(format: "%.2f", computation.taxUSD))
        Total: $\(String(format: "%.2f", computation.subtotalUSD + computation.taxUSD))\(note)
        """
    }
}

struct CompanyDigitalProduct: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var name: String
    var assetPath: String
    var requiresLicenseKey: Bool
    var downloadTTLSeconds: TimeInterval
    var downloadCap: Int
}

struct CompanyLicenseKey: Codable, Hashable, Identifiable {
    enum State: String, Codable, CaseIterable, Hashable {
        case active
        case revoked
    }

    let id: String
    var companyID: String
    var productID: String
    var orderID: String
    var value: String
    var state: State
}

struct CompanySignedDownload: Codable, Hashable {
    var url: URL
    var expiresAt: Date
    var downloadCap: Int
}

enum FulfillmentService {
    static func signedURL(product: CompanyDigitalProduct, orderID: String, at date: Date = Date()) -> CompanySignedDownload {
        let token = CompanyEvent.inputHash(for: "\(product.id):\(orderID):\(date.timeIntervalSince1970)").prefix(16)
        return CompanySignedDownload(
            url: URL(string: "https://downloads.os1.local/\(product.id)?order=\(orderID)&token=\(token)")!,
            expiresAt: date.addingTimeInterval(product.downloadTTLSeconds),
            downloadCap: product.downloadCap
        )
    }

    static func licenseKey(product: CompanyDigitalProduct, orderID: String) -> CompanyLicenseKey? {
        guard product.requiresLicenseKey else { return nil }
        let value = CompanyEvent.inputHash(for: "\(product.companyID):\(product.id):\(orderID)").prefix(24).uppercased()
        return CompanyLicenseKey(id: "lic-\(orderID)", companyID: product.companyID, productID: product.id, orderID: orderID, value: String(value), state: .active)
    }

    static func revoke(_ key: CompanyLicenseKey) -> CompanyLicenseKey {
        var copy = key
        copy.state = .revoked
        return copy
    }

    static func piracyFlag(downloadIPs: [String], windowSeconds: TimeInterval) -> Bool {
        Set(downloadIPs).count >= 50 && windowSeconds <= 3_600
    }

    static func watermark(text: String, customerEmail: String) -> String {
        "\(text)\n\nLicensed to \(customerEmail)"
    }
}

struct CompanyAdCampaign: Codable, Hashable, Identifiable {
    enum Platform: String, Codable, CaseIterable, Hashable {
        case meta
        case google
        case tiktok
        case reddit
    }

    enum State: String, Codable, CaseIterable, Hashable {
        case draft
        case approvalRequired
        case active
        case paused
    }

    let id: String
    var companyID: String
    var platform: Platform
    var name: String
    var dailyBudgetUSD: Double
    var spendUSD: Double
    var conversions: Int
    var state: State

    var cpaUSD: Double {
        guard conversions > 0 else { return .infinity }
        return spendUSD / Double(conversions)
    }
}

enum CompanyAdAdapter {
    static func createCampaign(_ campaign: CompanyAdCampaign, approvedCampaignCount: Int, dailyCapUSD: Double) -> CompanyAdCampaign {
        var copy = campaign
        if campaign.dailyBudgetUSD > dailyCapUSD {
            copy.state = .approvalRequired
        } else {
            copy.state = approvedCampaignCount < 3 ? .approvalRequired : .active
        }
        return copy
    }

    static func optimize(_ campaigns: [CompanyAdCampaign], monthlyBudgetRemainingUSD: Double) -> [CompanyAdCampaign] {
        guard let best = campaigns.min(by: { $0.cpaUSD < $1.cpaUSD }) else { return [] }
        return campaigns.map { campaign in
            var copy = campaign
            if campaign.cpaUSD > best.cpaUSD * 5 {
                copy.state = .paused
            } else if campaign.id == best.id && monthlyBudgetRemainingUSD > campaign.dailyBudgetUSD * 7 {
                copy.dailyBudgetUSD *= 1.25
            }
            return copy
        }
    }
}

enum EnrichmentProvider: String, Codable, CaseIterable, Hashable {
    case apollo
    case hunter
    case clearbit
    case findymail
}

struct CompanyEnrichedLead: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var name: String
    var email: String?
    var role: String
    var companyName: String
    var provider: EnrichmentProvider
    var verification: EmailVerificationVerdict
    var intentScore: Double
}

enum EmailVerificationVerdict: String, Codable, CaseIterable, Hashable {
    case valid
    case risky
    case invalid
}

enum CompanyLeadScorer {
    static func score(icpFit: Double, intent: Double, verified: EmailVerificationVerdict) -> Double {
        let verificationWeight: Double = verified == .valid ? 1 : (verified == .risky ? 0.6 : 0)
        return min(1, (icpFit * 0.55 + intent * 0.45) * verificationWeight)
    }

    static func blocksOutreach(_ verdict: EmailVerificationVerdict) -> Bool {
        verdict == .invalid
    }
}

enum BookingProvider: String, Codable, CaseIterable, Hashable {
    case calcom
    case calendly
}

struct CompanyBookingLink: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var provider: BookingProvider
    var eventTypeID: String
    var url: URL
    var singleUse: Bool
}

struct CompanyMeeting: Codable, Hashable, Identifiable {
    enum State: String, Codable, CaseIterable, Hashable {
        case proposed
        case scheduled
        case completed
        case noShow
        case canceled
    }

    let id: String
    var companyID: String
    var bookingLinkID: String
    var contactEmail: String
    var startsAt: Date
    var state: State
}

enum CompanyBookingAdapter {
    static func createSingleUseLink(companyID: String, provider: BookingProvider, eventTypeID: String) -> CompanyBookingLink {
        CompanyBookingLink(
            id: "book-\(companyID)-\(eventTypeID)",
            companyID: companyID,
            provider: provider,
            eventTypeID: eventTypeID,
            url: URL(string: "https://cal.com/os1/\(companyID)/\(eventTypeID)")!,
            singleUse: true
        )
    }

    static func brief(for meeting: CompanyMeeting, contact: CompanyCRMContact?) -> String {
        "Meeting with \(contact?.name ?? meeting.contactEmail) at \(meeting.startsAt). Prepare discovery questions and recent activity."
    }
}

enum VoiceProvider: String, Codable, CaseIterable, Hashable {
    case twilio
    case vapi
    case retell
    case bland
}

struct CompanyPhoneNumber: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var provider: VoiceProvider
    var number: String
    var monthlyCostUSD: Double
    var approvalState: CompanyGrowthCampaign.ApprovalState
}

struct CompanyCallSession: Codable, Hashable, Identifiable {
    enum Outcome: String, Codable, CaseIterable, Hashable {
        case lead
        case booked
        case support
        case spam
        case unknown
    }

    let id: String
    var companyID: String
    var provider: VoiceProvider
    var from: String
    var to: String
    var transcript: String
    var outcome: Outcome
}

struct CompanySMSConversation: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var phoneNumberID: String
    var messages: [String]
}

enum CompanyVoiceAgent {
    static func provisionNumber(companyID: String, provider: VoiceProvider, number: String, monthlyCostUSD: Double, approved: Bool) -> CompanyPhoneNumber {
        CompanyPhoneNumber(id: "phone-\(companyID)-\(number)", companyID: companyID, provider: provider, number: number, monthlyCostUSD: monthlyCostUSD, approvalState: approved ? .approved : .approvalRequired)
    }

    static func outcome(from transcript: String) -> CompanyCallSession.Outcome {
        let lower = transcript.lowercased()
        if lower.contains("book") || lower.contains("appointment") { return .booked }
        if lower.contains("price") || lower.contains("quote") { return .lead }
        if lower.contains("refund") || lower.contains("support") { return .support }
        return .unknown
    }
}

struct CompanyClient: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var name: String
    var email: String
    var status: String
}

struct CompanyEngagement: Codable, Hashable, Identifiable {
    enum State: String, Codable, CaseIterable, Hashable {
        case discovery
        case active
        case waitingOnClient
        case complete
    }

    let id: String
    var companyID: String
    var clientID: String
    var state: State
    var monthlyFeeUSD: Double
    var hoursSaved: Double
}

enum ROICalculator {
    static func markdown(engagement: CompanyEngagement, hourlyValueUSD: Double) -> String {
        let value = engagement.hoursSaved * hourlyValueUSD
        return "# ROI\nMonthly fee: $\(engagement.monthlyFeeUSD)\nHours saved: \(engagement.hoursSaved)\nEstimated value: $\(value)"
    }
}

enum DiscoveryInterview {
    static func opsCanvas(from transcript: String) -> String {
        let pain = transcript.lowercased().contains("manual") ? "Manual work bottleneck" : "Discovery needed"
        return "# Ops Canvas\nPain: \(pain)\nSource: \(transcript.prefix(120))"
    }
}

enum CourseProvider: String, Codable, CaseIterable, Hashable {
    case skool
    case teachable
    case thinkific
    case circle
    case kajabi
}

struct CompanyCourse: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var provider: CourseProvider
    var title: String
    var lessons: [String]
}

struct CompanyCommunity: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var provider: CourseProvider
    var name: String
    var bannedPhrases: [String]
}

enum CompanyCourseAdapter {
    static func deliveredLessons(enrolledAt: Date, now: Date, lessons: [String], dripDays: Int = 7) -> [String] {
        let elapsed = max(0, Int(now.timeIntervalSince(enrolledAt) / 86_400))
        let count = min(lessons.count, elapsed / dripDays + 1)
        return Array(lessons.prefix(count))
    }

    static func moderationHit(post: String, community: CompanyCommunity) -> Bool {
        let lower = post.lowercased()
        return community.bannedPhrases.contains { lower.contains($0.lowercased()) }
    }
}
