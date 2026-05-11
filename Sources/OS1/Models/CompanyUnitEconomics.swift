import Foundation

struct CompanyUnitEconomicsPolicy: Codable, Hashable {
    var minimumGrossMargin: Double
    var minimumContributionMargin: Double
    var maximumRefundRate: Double
    var maximumChurnRate: Double
    var maximumPaybackDays: Double
    var minimumVerifiedRevenueUSD: Double

    static let productionDefault = CompanyUnitEconomicsPolicy(
        minimumGrossMargin: 0.5,
        minimumContributionMargin: 0.25,
        maximumRefundRate: 0.1,
        maximumChurnRate: 0.12,
        maximumPaybackDays: 60,
        minimumVerifiedRevenueUSD: 50
    )
}

struct CompanyUnitEconomicsCohort: Codable, Hashable, Identifiable {
    var id: String
    var channel: String
    var customersAcquired: Int
    var customersChurned: Int
    var acquisitionSpendUSD: Double
    var observedLTVUSD: Double
}

struct CompanyMetricInterval: Codable, Hashable {
    var low: Double
    var high: Double
}

struct CompanyUnitEconomicsReport: Codable, Hashable {
    enum Confidence: String, Codable, Hashable {
        case verified
        case mixed
        case estimated
        case immature
    }

    var companyID: String
    var verifiedRevenueUSD: Double
    var estimatedRevenueUSD: Double
    var grossMargin: Double?
    var contributionMargin: Double?
    var cacUSD: Double?
    var ltvUSD: Double?
    var churnRate: Double?
    var refundRate: Double
    var supportCostUSD: Double
    var paymentFeesUSD: Double
    var computeCostUSD: Double
    var paybackPeriodDays: Double?
    var confidence: Confidence
    var assumptions: [String]
    var confidenceIntervals: [String: CompanyMetricInterval]
    var channelReports: [String: ChannelReport]
    var reasons: [String]

    struct ChannelReport: Codable, Hashable {
        var channel: String
        var cacUSD: Double?
        var ltvUSD: Double?
        var churnRate: Double?
    }

    var canScale: Bool {
        reasons.isEmpty && confidence != .estimated && confidence != .immature
    }

    var shouldReview: Bool {
        !reasons.isEmpty
    }
}

enum CompanyUnitEconomicsEngine {
    static func evaluate(
        companyID: String,
        ledger: CompanyLedgerSummary,
        cohorts: [CompanyUnitEconomicsCohort] = [],
        policy: CompanyUnitEconomicsPolicy = .productionDefault
    ) -> CompanyUnitEconomicsReport {
        let revenue = ledger.netRevenueUSD
        let verifiedRevenue = ledger.verifiedRevenueUSD
        let estimatedRevenue = ledger.entries
            .filter { $0.kind == .revenue && $0.confidence == .estimated }
            .reduce(0) { $0 + $1.amountUSD }
        let supportCost = cost(ledger, categories: [.manualLabor])
        let paymentFees = cost(ledger, categories: [.paymentFees])
        let computeCost = cost(ledger, categories: [.cloudCompute, .tokenUsage])
        let grossCost = paymentFees + computeCost
        let grossMargin = revenue > 0 ? (revenue - grossCost) / revenue : nil
        let contributionMargin = ledger.contributionMargin
        let acquired = cohorts.map(\.customersAcquired).reduce(0, +)
        let churned = cohorts.map(\.customersChurned).reduce(0, +)
        let acquisitionSpend = cohorts.map(\.acquisitionSpendUSD).reduce(0, +)
        let observedLTV = cohorts.map(\.observedLTVUSD).reduce(0, +)
        let cac = acquired > 0 ? acquisitionSpend / Double(acquired) : nil
        let ltv = acquired > 0 ? observedLTV / Double(acquired) : nil
        let churn = acquired > 0 ? Double(churned) / Double(acquired) : nil
        let refundRate = ledger.revenueUSD > 0 ? ledger.refundUSD / ledger.revenueUSD : 0
        let payback = paybackDays(cac: cac, ltv: ltv, revenue: revenue, acquired: acquired)
        let confidence = confidence(ledger: ledger, cohorts: cohorts)
        let channelReports = Dictionary(
            uniqueKeysWithValues: Dictionary(grouping: cohorts, by: \.channel).map { channel, values in
                (channel, channelReport(channel: channel, cohorts: values))
            }
        )
        let reasons = reviewReasons(
            verifiedRevenue: verifiedRevenue,
            grossMargin: grossMargin,
            contributionMargin: contributionMargin,
            refundRate: refundRate,
            churnRate: churn,
            paybackDays: payback,
            confidence: confidence,
            policy: policy
        )

        return CompanyUnitEconomicsReport(
            companyID: companyID,
            verifiedRevenueUSD: verifiedRevenue,
            estimatedRevenueUSD: estimatedRevenue,
            grossMargin: grossMargin,
            contributionMargin: contributionMargin,
            cacUSD: cac,
            ltvUSD: ltv,
            churnRate: churn,
            refundRate: refundRate,
            supportCostUSD: supportCost,
            paymentFeesUSD: paymentFees,
            computeCostUSD: computeCost,
            paybackPeriodDays: payback,
            confidence: confidence,
            assumptions: assumptions(cac: cac, ltv: ltv, churn: churn),
            confidenceIntervals: intervals(cac: cac, ltv: ltv, churn: churn, confidence: confidence),
            channelReports: channelReports,
            reasons: reasons
        )
    }

    private static func reviewReasons(
        verifiedRevenue: Double,
        grossMargin: Double?,
        contributionMargin: Double?,
        refundRate: Double,
        churnRate: Double?,
        paybackDays: Double?,
        confidence: CompanyUnitEconomicsReport.Confidence,
        policy: CompanyUnitEconomicsPolicy
    ) -> [String] {
        var reasons: [String] = []
        if verifiedRevenue < policy.minimumVerifiedRevenueUSD { reasons.append("verifiedRevenueBelowThreshold") }
        if grossMargin ?? 0 < policy.minimumGrossMargin { reasons.append("grossMarginBelowThreshold") }
        if contributionMargin ?? 0 < policy.minimumContributionMargin {
            reasons.append("contributionMarginBelowThreshold")
        }
        if refundRate > policy.maximumRefundRate { reasons.append("refundRateAboveThreshold") }
        if let churnRate, churnRate > policy.maximumChurnRate { reasons.append("churnRateAboveThreshold") }
        if let paybackDays, paybackDays > policy.maximumPaybackDays { reasons.append("paybackTooSlow") }
        if confidence == .estimated || confidence == .immature { reasons.append("metricsNotVerified") }
        return reasons
    }

    private static func confidence(
        ledger: CompanyLedgerSummary,
        cohorts: [CompanyUnitEconomicsCohort]
    ) -> CompanyUnitEconomicsReport.Confidence {
        if ledger.entries.isEmpty || cohorts.isEmpty { return .immature }
        let hasEstimated = ledger.entries.contains { $0.confidence == .estimated }
        if ledger.hasVerifiedRevenue && !hasEstimated { return .verified }
        if ledger.hasVerifiedRevenue && hasEstimated { return .mixed }
        return .estimated
    }

    private static func assumptions(cac: Double?, ltv: Double?, churn: Double?) -> [String] {
        var values: [String] = []
        if cac == nil { values.append("CAC unavailable until acquisition spend and customers are recorded.") }
        if ltv == nil { values.append("LTV unavailable until cohort revenue is observed.") }
        if churn == nil { values.append("Churn unavailable until cohort retention is tracked.") }
        return values
    }

    private static func intervals(
        cac: Double?,
        ltv: Double?,
        churn: Double?,
        confidence: CompanyUnitEconomicsReport.Confidence
    ) -> [String: CompanyMetricInterval] {
        let width: Double = confidence == .verified ? 0.1 : 0.35
        var intervals: [String: CompanyMetricInterval] = [:]
        if let cac { intervals["cacUSD"] = interval(center: cac, width: width) }
        if let ltv { intervals["ltvUSD"] = interval(center: ltv, width: width) }
        if let churn { intervals["churnRate"] = interval(center: churn, width: width) }
        return intervals
    }

    private static func interval(center: Double, width: Double) -> CompanyMetricInterval {
        CompanyMetricInterval(low: max(0, center * (1 - width)), high: center * (1 + width))
    }

    private static func channelReport(
        channel: String,
        cohorts: [CompanyUnitEconomicsCohort]
    ) -> CompanyUnitEconomicsReport.ChannelReport {
        let acquired = cohorts.map(\.customersAcquired).reduce(0, +)
        let churned = cohorts.map(\.customersChurned).reduce(0, +)
        let spend = cohorts.map(\.acquisitionSpendUSD).reduce(0, +)
        let ltv = cohorts.map(\.observedLTVUSD).reduce(0, +)
        return CompanyUnitEconomicsReport.ChannelReport(
            channel: channel,
            cacUSD: acquired > 0 ? spend / Double(acquired) : nil,
            ltvUSD: acquired > 0 ? ltv / Double(acquired) : nil,
            churnRate: acquired > 0 ? Double(churned) / Double(acquired) : nil
        )
    }

    private static func paybackDays(
        cac: Double?,
        ltv: Double?,
        revenue: Double,
        acquired: Int
    ) -> Double? {
        guard let cac, acquired > 0, revenue > 0 else { return nil }
        if let ltv, ltv > 0 { return min(365, (cac / ltv) * 30) }
        return min(365, (cac / (revenue / Double(acquired))) * 30)
    }

    private static func cost(
        _ ledger: CompanyLedgerSummary,
        categories: Set<CompanyLedgerEntry.Category>
    ) -> Double {
        ledger.entries
            .filter { $0.kind == .cost && $0.category.map { categories.contains($0) } == true }
            .reduce(0) { $0 + $1.amountUSD }
    }
}
