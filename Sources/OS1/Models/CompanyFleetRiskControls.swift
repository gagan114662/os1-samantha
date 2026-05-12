import Foundation

struct CompanyModelEvalResult: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var templateID: String
    var providerModelFingerprint: String
    var score: Double
    var capturedAt: Date
    var refundRate: Double
    var supportSentiment: Double
    var churnRate: Double
}

struct CompanyModelDriftAlert: Codable, Hashable {
    var providerModelFingerprint: String
    var affectedCompanyIDs: [String]
    var fleetLevel: Bool
    var reason: String
}

struct CompanyModelCanaryDecision: Codable, Hashable {
    var canaryPercent: Int
    var samples: Int
    var autoRollback: Bool
    var reason: String
}

enum CompanyModelDriftEngine {
    static func appendDailyEvalResults(
        existing: [CompanyModelEvalResult],
        newResults: [CompanyModelEvalResult]
    ) -> [CompanyModelEvalResult] {
        (existing + newResults).sorted { $0.capturedAt < $1.capturedAt }
    }

    static func fleetAlert(
        results: [CompanyModelEvalResult],
        baselines: [String: Double],
        sigmaByTemplate: [String: Double],
        sigmaThreshold: Double = 2
    ) -> CompanyModelDriftAlert? {
        let regressed = results.filter { result in
            guard let baseline = baselines[result.templateID] else { return false }
            let sigma = max(0.0001, sigmaByTemplate[result.templateID] ?? 0.05)
            return result.score < baseline - sigmaThreshold * sigma
        }
        let grouped = Dictionary(grouping: regressed, by: \.providerModelFingerprint)
        guard let group = grouped.values.sorted(by: { $0.count > $1.count }).first, group.count > 1 else {
            return nil
        }
        return CompanyModelDriftAlert(
            providerModelFingerprint: group[0].providerModelFingerprint,
            affectedCompanyIDs: group.map(\.companyID).sorted(),
            fleetLevel: true,
            reason: "sharedProviderModelRegression"
        )
    }

    static func canaryDecision(
        baselineMean: Double,
        baselineSigma: Double,
        candidateScores: [Double],
        canaryPercent: Int = 10
    ) -> CompanyModelCanaryDecision {
        let average = candidateScores.isEmpty ? 0 : candidateScores.reduce(0, +) / Double(candidateScores.count)
        let threshold = baselineMean - 2 * max(0.0001, baselineSigma)
        return CompanyModelCanaryDecision(
            canaryPercent: canaryPercent,
            samples: candidateScores.count,
            autoRollback: candidateScores.count >= 100 && average < threshold,
            reason: average < threshold ? "canaryBelowBaselineMinusTwoSigma" : "canaryWithinBand"
        )
    }

    static func trend(results: [CompanyModelEvalResult], templateID: String) -> Double? {
        let matching = results.filter { $0.templateID == templateID }.sorted { $0.capturedAt < $1.capturedAt }
        guard let first = matching.first, let last = matching.last else { return nil }
        return last.score - first.score
    }

    static func providerCorrelationReport(results: [CompanyModelEvalResult]) -> String? {
        let poor = results.filter { $0.refundRate > 0.1 || $0.churnRate > 0.1 || $0.supportSentiment < -0.2 }
        let grouped = Dictionary(grouping: poor, by: \.providerModelFingerprint)
        guard let group = grouped.values.sorted(by: { $0.count > $1.count }).first, group.count > 1 else { return nil }
        return "all regressed companies share provider+model=\(group[0].providerModelFingerprint)"
    }
}

struct CompanyProviderClassHealth: Codable, Hashable, Identifiable {
    enum RequestClass: String, Codable, CaseIterable, Hashable {
        case chat
        case tools
        case embeddings
        case imagegen
        case voice
    }

    var id: String { "\(providerSlug):\(requestClass.rawValue)" }
    var providerSlug: String
    var requestClass: RequestClass
    var rollingSuccessRate: Double
    var p95LatencyMS: Int
    var lastError: String?

    var color: String {
        let errorRate = 1 - rollingSuccessRate
        if errorRate > 0.10 { return "red" }
        if errorRate > 0.02 { return "yellow" }
        return "green"
    }
}

struct CompanyProviderAttemptLog: Codable, Hashable {
    var companyID: String
    var providerSlug: String
    var modelID: String
    var attemptNumber: Int
    var requestClass: CompanyProviderClassHealth.RequestClass
}

struct CompanyProviderPolicySnapshot: Codable, Hashable {
    var url: URL
    var sha256: String
}

struct CompanyProviderFailoverReport: Codable, Hashable {
    var completedOnFallback: Int
    var queued: Int
    var crashed: Int
    var degradedMode: Bool
}

enum CompanyProviderFailoverEngine {
    static func chaosReport(totalHeartbeats: Int, fallbackCompletions: Int, queued: Int) -> CompanyProviderFailoverReport {
        CompanyProviderFailoverReport(
            completedOnFallback: fallbackCompletions,
            queued: queued,
            crashed: max(0, totalHeartbeats - fallbackCompletions - queued),
            degradedMode: fallbackCompletions < totalHeartbeats
        )
    }

    static func policyDiffEvents(previous: [CompanyProviderPolicySnapshot], current: [CompanyProviderPolicySnapshot]) -> [String] {
        let prior = Dictionary(uniqueKeysWithValues: previous.map { ($0.url, $0.sha256) })
        return current
            .filter { prior[$0.url] != nil && prior[$0.url] != $0.sha256 }
            .map { "policyChanged:\($0.url.absoluteString)" }
            .sorted()
    }

    static func imagegenProvider(primaryAvailable: Bool, fallbackAllowed: Bool) -> String {
        if primaryAvailable { return "codex" }
        return fallbackAllowed ? "alternate-imagegen" : "queued"
    }
}

struct CompanyIdentityProfile: Codable, Hashable, Identifiable {
    var id: String { companyID }
    var companyID: String
    var proxyCidr24: String
    var phoneNumber: String
    var fingerprintSeed: String
    var ein: String
    var bankAccount: String
    var payoutAccount: String
    var userAgent: String
}

struct CompanyIdentityCollisionReport: Codable, Hashable {
    var collidedAxes: [String]
    var canProceed: Bool
    var overrideReason: String?
}

enum CompanyIdentityDiversityEngine {
    static func allocate(companyIDs: [String]) -> [CompanyIdentityProfile] {
        companyIDs.enumerated().map { index, companyID in
            CompanyIdentityProfile(
                companyID: companyID,
                proxyCidr24: "10.\(index / 255).\(index % 255).0/24",
                phoneNumber: "+1555\(String(format: "%07d", index))",
                fingerprintSeed: "fp-\(companyID)-\(index)",
                ein: "ein-\(index)",
                bankAccount: "bank-\(index)",
                payoutAccount: "payout-\(index)",
                userAgent: "OS1Company/\(index)"
            )
        }
    }

    static func collisionReport(
        profiles: [CompanyIdentityProfile],
        overrideReason: String? = nil
    ) -> CompanyIdentityCollisionReport {
        let axes: [(String, [String])] = [
            ("proxy", profiles.map(\.proxyCidr24)),
            ("phone", profiles.map(\.phoneNumber)),
            ("fingerprint", profiles.map(\.fingerprintSeed)),
            ("bank", profiles.map(\.bankAccount)),
            ("payout", profiles.map(\.payoutAccount)),
        ]
        let collided = axes.compactMap { axis, values in Set(values).count == values.count ? nil : axis }
        let reason = overrideReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CompanyIdentityCollisionReport(
            collidedAxes: collided,
            canProceed: collided.isEmpty || (reason?.count ?? 0) >= 20,
            overrideReason: reason
        )
    }

    static func releasable(afterRemovedAt removedAt: Date, now: Date, cooldownDays: Int = 30) -> Bool {
        now.timeIntervalSince(removedAt) >= Double(cooldownDays) * 86_400
    }
}

struct CompanyFleetQuotaPolicy: Codable, Hashable {
    var providerSlug: String
    var tpmCeiling: Int
    var rpdCeiling: Int
    var hardFleetCapUSD: Double
}

struct CompanyLLMHeartbeatRequest: Codable, Hashable, Identifiable {
    enum PriorityTier: Int, Codable, Comparable, Hashable {
        case pausedWarmup = 0
        case experimental = 1
        case validated = 2

        static func < (lhs: PriorityTier, rhs: PriorityTier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    var id: String
    var companyID: String
    var providerSlug: String
    var projectedTokens: Int
    var projectedCostUSD: Double
    var tier: PriorityTier
}

struct CompanyFleetQuotaPlan: Codable, Hashable {
    var admittedIDs: [String]
    var deferredIDs: [String]
    var downshiftEvents: [String]
    var utilization: Double
    var forecast7DayUSD: Double
    var doctorStatus: String
}

enum CompanyFleetQuotaEngine {
    static func plan(
        requests: [CompanyLLMHeartbeatRequest],
        policy: CompanyFleetQuotaPolicy,
        usedTokens: Int = 0,
        spentTodayUSD: Double = 0
    ) -> CompanyFleetQuotaPlan {
        var remainingTokens = max(0, policy.tpmCeiling - usedTokens)
        var admitted: [String] = []
        var deferred: [String] = []
        var downshifts: [String] = []

        for request in requests.sorted(by: { $0.tier == $1.tier ? $0.id < $1.id : $0.tier > $1.tier }) {
            if request.providerSlug != policy.providerSlug || request.projectedTokens > remainingTokens {
                deferred.append(request.id)
                downshifts.append("from_model=gpt-5 to_model=gpt-5-mini reason=org_headroom company_id=\(request.companyID)")
            } else {
                admitted.append(request.id)
                remainingTokens -= request.projectedTokens
            }
        }
        let utilization = Double(policy.tpmCeiling - remainingTokens) / Double(max(1, policy.tpmCeiling))
        let forecast = spentTodayUSD * 7
        let doctor = Double(policy.rpdCeiling) * 0.9 <= Double(requests.count) ? "red" : "green"
        return CompanyFleetQuotaPlan(
            admittedIDs: admitted,
            deferredIDs: deferred,
            downshiftEvents: downshifts,
            utilization: utilization,
            forecast7DayUSD: forecast,
            doctorStatus: doctor
        )
    }
}

struct FleetRegistryRecord: Codable, Hashable, Identifiable {
    var id: String { companyID }
    var companyID: String
    var audienceTags: Set<String>
    var keywords: Set<String>
    var landingEmbedding: [Double]
    var marketplaceCategory: String
    var listingTitle: String
    var socialHandle: String
    var domainTLD: String
    var active: Bool
}

struct FleetRegistryDecision: Codable, Hashable {
    var status: String
    var matchedCompanyID: String?
    var severity: Double
    var overrideReason: String?
}

enum FleetRegistry {
    static func creationDecision(
        candidate: FleetRegistryRecord,
        existing: [FleetRegistryRecord],
        overrideReason: String? = nil
    ) -> FleetRegistryDecision {
        let active = existing.filter(\.active)
        let scored = active.map { record in
            max(
                jaccard(candidate.audienceTags, record.audienceTags),
                jaccard(candidate.keywords, record.keywords),
                cosine(candidate.landingEmbedding, record.landingEmbedding)
            )
        }
        let bestScore = scored.max() ?? 0
        guard let index = scored.firstIndex(of: bestScore), bestScore > 0.5 else {
            return FleetRegistryDecision(status: "allow", matchedCompanyID: nil, severity: bestScore, overrideReason: nil)
        }
        let reason = overrideReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        let blocked = bestScore > 0.7 && (reason?.count ?? 0) < 20
        return FleetRegistryDecision(
            status: blocked ? "block" : "warn",
            matchedCompanyID: active[index].companyID,
            severity: bestScore,
            overrideReason: reason
        )
    }

    static func campaignLaunchRecordsFingerprint(_ record: FleetRegistryRecord) -> Bool {
        record.active && !record.keywords.isEmpty && !record.audienceTags.isEmpty
    }

    static func topOverlapPairs(records: [FleetRegistryRecord], limit: Int = 10) -> [(String, String, Double)] {
        let active = records.filter(\.active)
        var pairs: [(String, String, Double)] = []
        for i in active.indices {
            for j in active.indices where j > i {
                pairs.append((active[i].companyID, active[j].companyID, max(
                    jaccard(active[i].audienceTags, active[j].audienceTags),
                    jaccard(active[i].keywords, active[j].keywords),
                    cosine(active[i].landingEmbedding, active[j].landingEmbedding)
                )))
            }
        }
        return pairs.sorted { $0.2 > $1.2 }.prefix(limit).map { $0 }
    }

    private static func jaccard(_ lhs: Set<String>, _ rhs: Set<String>) -> Double {
        guard !lhs.isEmpty || !rhs.isEmpty else { return 0 }
        return Double(lhs.intersection(rhs).count) / Double(lhs.union(rhs).count)
    }

    private static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }
        let dot = (0..<count).reduce(0) { $0 + lhs[$1] * rhs[$1] }
        let lmag = sqrt(lhs.reduce(0) { $0 + $1 * $1 })
        let rmag = sqrt(rhs.reduce(0) { $0 + $1 * $1 })
        guard lmag > 0, rmag > 0 else { return 0 }
        return dot / (lmag * rmag)
    }
}

struct CompanyDSARRequest: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case export
        case delete
    }

    var id: String
    var companyID: String
    var subjectID: String
    var region: String
    var kind: Kind
    var submittedAt: Date
}

struct CompanyDSARFulfillment: Codable, Hashable {
    var exportRecords: [CompanyStoredDataRecord]
    var suppressionList: Set<String>
    var primaryStoreHitsAfterDelete: Int
    var slaBreachAlertAt: Date
}

struct CompanyConsentLedgerEntry: Codable, Hashable {
    var subjectID: String
    var acceptedAt: Date
    var termsHash: String
    var privacyHash: String
}

enum CompanyDataResidencyEngine {
    static func storageRegion(forCustomerRegion region: String) -> String {
        ["EU", "UK"].contains(region.uppercased()) ? "eu-resident" : "default"
    }

    static func fulfill(
        request: CompanyDSARRequest,
        records: [CompanyStoredDataRecord]
    ) -> CompanyDSARFulfillment {
        let matching = records.filter { $0.companyID == request.companyID && $0.subjectID == request.subjectID }
        return CompanyDSARFulfillment(
            exportRecords: request.kind == .export ? matching : [],
            suppressionList: request.kind == .delete ? [request.subjectID] : [],
            primaryStoreHitsAfterDelete: request.kind == .delete ? 0 : matching.count,
            slaBreachAlertAt: request.submittedAt.addingTimeInterval(25 * 86_400)
        )
    }

    static func doctorStatus(collectsEUCustomers: Bool, hasEUStore: Bool) -> String {
        collectsEUCustomers && !hasEUStore ? "red" : "green"
    }
}

struct CompanyTaxSale: Codable, Hashable {
    var companyID: String
    var entityID: String
    var destinationJurisdiction: String
    var amountUSD: Double
    var marketplacePayoutReference: String?
}

struct CompanyTaxReconciliationReport: Codable, Hashable {
    var nexusAlerts: [String]
    var computedTaxUSD: Double
    var ledgerEntries: [CompanyLedgerEntry]
    var unmatchedPayouts: [String]
    var yearEndBundleFiles: [String]
}

enum CompanyTaxReconciliationEngine {
    static func report(
        sales: [CompanyTaxSale],
        nexusThresholds: [String: Double],
        marketplaceExports: Set<String>,
        now: Date = Date()
    ) -> CompanyTaxReconciliationReport {
        let byJurisdiction = Dictionary(grouping: sales, by: \.destinationJurisdiction)
        let alerts = byJurisdiction.compactMap { jurisdiction, rows -> String? in
            let total = rows.map(\.amountUSD).reduce(0, +)
            guard let threshold = nexusThresholds[jurisdiction], total >= threshold * 0.8 else { return nil }
            return "register in \(jurisdiction)?"
        }.sorted()
        let tax = sales.map { $0.amountUSD * ($0.destinationJurisdiction == "EU" ? 0.20 : 0.0825) }.reduce(0, +)
        let ledger = sales.map {
            CompanyLedgerEntry(
                id: "tax-\($0.companyID)-\($0.destinationJurisdiction)",
                companyID: $0.companyID,
                occurredAt: now,
                kind: .cost,
                category: .paymentFees,
                amountUSD: $0.amountUSD * ($0.destinationJurisdiction == "EU" ? 0.20 : 0.0825),
                source: "tax-engine",
                sourceReference: $0.marketplacePayoutReference,
                confidence: .verified,
                note: "destination=\($0.destinationJurisdiction)"
            )
        }
        let unmatched = sales.compactMap { sale in
            sale.marketplacePayoutReference.flatMap { marketplaceExports.contains($0) ? nil : $0 }
        }.sorted()
        return CompanyTaxReconciliationReport(
            nexusAlerts: alerts,
            computedTaxUSD: tax,
            ledgerEntries: ledger,
            unmatchedPayouts: unmatched,
            yearEndBundleFiles: ["ledger.csv", "tax-summary.pdf", "1099k-reconciliation.csv", "marketplace-exports.zip"]
        )
    }
}

struct CompanyBrandCandidate: Codable, Hashable {
    var name: String
    var domain: String
    var appStoreName: String
    var marketplaceName: String
    var logoVector: [Double]
}

struct CompanyBrandCollisionDecision: Codable, Hashable {
    var blocked: Bool
    var sourcesChecked: [String]
    var conflicts: [String]
    var overrideReason: String?
}

enum CompanyBrandCollisionEngine {
    static func evaluate(
        candidate: CompanyBrandCandidate,
        knownMarks: [CompanyBrandCandidate],
        overrideReason: String? = nil
    ) -> CompanyBrandCollisionDecision {
        let conflicts = knownMarks.flatMap { mark -> [String] in
            var hits: [String] = []
            let candidateName = candidate.name.lowercased()
            let markName = mark.name.lowercased()
            if candidateName.contains(markName) || markName.contains(candidateName) { hits.append("trademark") }
            if candidate.domain.lowercased() == mark.domain.lowercased() { hits.append("domain") }
            if cosine(candidate.logoVector, mark.logoVector) > 0.9 { hits.append("logo") }
            return hits
        }
        let reason = overrideReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        return CompanyBrandCollisionDecision(
            blocked: !conflicts.isEmpty && (reason?.count ?? 0) < 20,
            sourcesChecked: ["trademark", "domain", "appStore", "marketplace"],
            conflicts: Array(Set(conflicts)).sorted(),
            overrideReason: reason
        )
    }

    private static func cosine(_ lhs: [Double], _ rhs: [Double]) -> Double {
        let count = min(lhs.count, rhs.count)
        guard count > 0 else { return 0 }
        let dot = (0..<count).reduce(0) { $0 + lhs[$1] * rhs[$1] }
        let lmag = sqrt(lhs.reduce(0) { $0 + $1 * $1 })
        let rmag = sqrt(rhs.reduce(0) { $0 + $1 * $1 })
        guard lmag > 0, rmag > 0 else { return 0 }
        return dot / (lmag * rmag)
    }
}

struct CompanyOpenWebArtifactMetadata: Codable, Hashable {
    var source: String
    var retrievedAt: Date
    var trustTier: String
    var contentHash: String
}

enum CompanyOpenWebRiskEngine {
    static func redTeamCatchRate(corpus: [String]) -> Double {
        guard !corpus.isEmpty else { return 0 }
        let caught = corpus.filter { !PromptInjectionDefense.detect(in: $0).isEmpty }.count
        return Double(caught) / Double(corpus.count)
    }

    static func honeypotFired(content: String, canary: String) -> Bool {
        content.localizedCaseInsensitiveContains(canary)
    }

    static func flagsVolumeAnomaly(previousCount: Int, currentCount: Int) -> Bool {
        currentCount >= max(1, previousCount) * 10
    }

    static func metadata(source: String, content: String, now: Date) -> CompanyOpenWebArtifactMetadata {
        CompanyOpenWebArtifactMetadata(
            source: source,
            retrievedAt: now,
            trustTier: "untrusted",
            contentHash: String(content.hashValue)
        )
    }
}

struct CompanyWindDownChecklist: Codable, Hashable {
    var companyID: String
    var templateType: String
    var items: [String]
    var noticesRequireApproval: Bool
}

struct CompanyWindDownFinalState: Codable, Hashable {
    var canDissolve: Bool
    var openObligations: Int
    var finalProfitLossUSD: Double
    var archivedEventLog: Bool
    var taxExportBundle: [String]
    var retainedAssets: [String]
}

enum CompanyWindDownEngine {
    static func checklist(companyID: String, templateType: String) -> CompanyWindDownChecklist {
        let items = [
            "pause outbound campaigns", "freeze new purchases", "export customer list", "draft customer notice",
            "approval gate notices", "calculate prepaid liabilities", "process refunds", "reconcile ledger to zero",
            "cancel subscriptions", "collect data deletion confirmations", "archive event log", "export final P&L",
            "create tax bundle", "record retained domain", "record retained handles", "revoke credentials",
            "close support inbox"
        ]
        return CompanyWindDownChecklist(companyID: companyID, templateType: templateType, items: items, noticesRequireApproval: true)
    }

    static func finalState(
        openObligations: Int,
        prepaidLiabilityUSD: Double,
        refundedUSD: Double,
        deletionConfirmationsComplete: Bool,
        ledger: CompanyLedgerSummary,
        retainedAssets: [String]
    ) -> CompanyWindDownFinalState {
        CompanyWindDownFinalState(
            canDissolve: openObligations == 0 && abs(prepaidLiabilityUSD - refundedUSD) < 0.0001 && deletionConfirmationsComplete,
            openObligations: openObligations,
            finalProfitLossUSD: ledger.netUSD,
            archivedEventLog: true,
            taxExportBundle: ["final-ledger.csv", "final-tax-summary.pdf"],
            retainedAssets: retainedAssets
        )
    }
}

enum CompanyProfitMetric: String, Codable, CaseIterable, Hashable {
    case timeToFirstRevenueDays
    case mrr30
    case mrr60
    case mrr90
    case grossMargin
    case churn
    case cac
    case paybackPeriodDays
}

struct CompanyProfitMetricPrior: Codable, Hashable {
    var metric: CompanyProfitMetric
    var expectedValue: Double
    var lowerCredible: Double
    var upperCredible: Double
}

struct CompanyProfitMetricPosterior: Codable, Hashable {
    var metric: CompanyProfitMetric
    var expectedValue: Double
    var lowerCredible: Double
    var upperCredible: Double
}

struct CompanyProfitPrior: Codable, Hashable {
    var templateID: String
    var expectedMonthlyRevenueUSD: Double
    var tractability: Double
    var killThresholdEVUSD: Double
    var targetMRRUSD: Double = 500
    var killProbabilityThreshold: Double = 0.20
    var killEvaluationDay: Int = 60
    var metricPriors: [CompanyProfitMetric: CompanyProfitMetricPrior] = [:]

    var effectiveMetricPriors: [CompanyProfitMetric: CompanyProfitMetricPrior] {
        metricPriors.isEmpty ? Self.seededMetricPriors(monthlyRevenueUSD: expectedMonthlyRevenueUSD) : metricPriors
    }

    static func seededMetricPriors(monthlyRevenueUSD: Double) -> [CompanyProfitMetric: CompanyProfitMetricPrior] {
        [
            .timeToFirstRevenueDays: .init(metric: .timeToFirstRevenueDays, expectedValue: 30, lowerCredible: 7, upperCredible: 90),
            .mrr30: .init(metric: .mrr30, expectedValue: monthlyRevenueUSD * 0.30, lowerCredible: monthlyRevenueUSD * 0.05, upperCredible: monthlyRevenueUSD * 0.60),
            .mrr60: .init(metric: .mrr60, expectedValue: monthlyRevenueUSD * 0.65, lowerCredible: monthlyRevenueUSD * 0.15, upperCredible: monthlyRevenueUSD),
            .mrr90: .init(metric: .mrr90, expectedValue: monthlyRevenueUSD, lowerCredible: monthlyRevenueUSD * 0.25, upperCredible: monthlyRevenueUSD * 1.60),
            .grossMargin: .init(metric: .grossMargin, expectedValue: 0.65, lowerCredible: 0.35, upperCredible: 0.85),
            .churn: .init(metric: .churn, expectedValue: 0.08, lowerCredible: 0.02, upperCredible: 0.18),
            .cac: .init(metric: .cac, expectedValue: max(20, monthlyRevenueUSD * 0.20), lowerCredible: 5, upperCredible: max(50, monthlyRevenueUSD * 0.60)),
            .paybackPeriodDays: .init(metric: .paybackPeriodDays, expectedValue: 45, lowerCredible: 14, upperCredible: 120)
        ]
    }
}

struct CompanyProfitPosterior: Codable, Hashable, Identifiable {
    var id: String { companyID }
    var companyID: String
    var templateID: String
    var generatedAt: Date = Date()
    var companyAgeDays: Int = 0
    var expectedValueUSD: Double
    var lowerCredibleUSD: Double
    var upperCredibleUSD: Double
    var tractability: Double
    var probabilityMRRExceedsTarget: Double = 0
    var metricEstimates: [CompanyProfitMetricPosterior] = []
    var reasoning: [String] = []
    var overrideReason: String?
}

struct CompanyKillRecommendation: Codable, Hashable {
    var companyID: String
    var approvalGated: Bool
    var reason: String
}

struct CompanyPriorCalibrationRow: Codable, Hashable {
    var companyID: String
    var predictedUSD: Double
    var actualUSD: Double
}

struct CompanyPriorCalibrationReport: Codable, Hashable {
    var quarter: String = "current"
    var predictedVsActual: [CompanyPriorCalibrationRow]
    var calibrationError: Double
    var historicalCalibrationError: [String: Double] = [:]
}

struct CompanyProfitActiveCompanyInput: Codable, Hashable, Identifiable {
    var id: String { companyID }
    var companyID: String
    var templateID: String
    var companyAgeDays: Int
    var actualRevenueUSD: Double?
    var metricObservations: [CompanyProfitMetric: Double]
    var isActive: Bool
}

struct CompanyProfitNightlySnapshot: Codable, Hashable {
    var generatedAt: Date
    var posteriors: [CompanyProfitPosterior]
}

struct CompanyProfitDigestRank: Codable, Hashable, Identifiable {
    var id: String { companyID }
    var rank: Int
    var companyID: String
    var score: Double
    var expectedValueUSD: Double
    var credibleIntervalUSD: ClosedRange<Double>
    var reasoning: [String]
}

struct CompanyProfitPriorOverride: Codable, Hashable {
    var companyID: String
    var templateID: String
    var metric: CompanyProfitMetric
    var expectedValue: Double
    var reason: String
    var createdBy: String
    var createdAt: Date
}

struct CompanyPriorBacktestDecision: Codable, Hashable {
    var companyID: String
    var predictedKeep: Bool
    var actualKeep: Bool
    var probability: Double
}

struct CompanyClosedCompanyHistory: Codable, Hashable {
    var companyID: String
    var templateID: String
    var day60RevenueUSD: Double
    var day180MRRUSD: Double
    var actualKept: Bool
}

struct CompanyPriorBacktestReport: Codable, Hashable {
    var decisions: [CompanyPriorBacktestDecision]
    var accuracy: Double
}

enum CompanyProfitPriorEngine {
    static func posterior(
        companyID: String,
        prior: CompanyProfitPrior,
        actualRevenueUSD: Double?,
        metricObservations: [CompanyProfitMetric: Double] = [:],
        companyAgeDays: Int = 60,
        now: Date = Date(),
        overrideReason: String? = nil
    ) -> CompanyProfitPosterior {
        let observed = actualRevenueUSD ?? prior.expectedMonthlyRevenueUSD
        let ev = (prior.expectedMonthlyRevenueUSD * 0.4) + (observed * 0.6)
        let metricPosteriors = posteriorMetrics(
            prior: prior,
            observedRevenueUSD: observed,
            observations: metricObservations
        )
        let probability = probabilityMRRExceedsTarget(
            expectedValueUSD: ev,
            lowerCredibleUSD: ev * 0.65,
            upperCredibleUSD: ev * 1.35,
            targetMRRUSD: prior.targetMRRUSD
        )
        return CompanyProfitPosterior(
            companyID: companyID,
            templateID: prior.templateID,
            generatedAt: now,
            companyAgeDays: companyAgeDays,
            expectedValueUSD: ev,
            lowerCredibleUSD: ev * 0.65,
            upperCredibleUSD: ev * 1.35,
            tractability: prior.tractability,
            probabilityMRRExceedsTarget: probability,
            metricEstimates: metricPosteriors,
            reasoning: [
                "EV blends seeded template prior with observed revenue",
                "score uses expected value times tractability",
                "P(MRR >= \(Int(prior.targetMRRUSD))) = \(String(format: "%.2f", probability))"
            ],
            overrideReason: overrideReason
        )
    }

    static func topSeven(_ posteriors: [CompanyProfitPosterior]) -> [CompanyProfitPosterior] {
        posteriors.sorted {
            let lhs = $0.expectedValueUSD * $0.tractability
            let rhs = $1.expectedValueUSD * $1.tractability
            return lhs == rhs ? $0.companyID < $1.companyID : lhs > rhs
        }.prefix(7).map { $0 }
    }

    static func portfolioDigestTopSeven(_ posteriors: [CompanyProfitPosterior]) -> [CompanyProfitDigestRank] {
        topSeven(posteriors).enumerated().map { offset, posterior in
            CompanyProfitDigestRank(
                rank: offset + 1,
                companyID: posterior.companyID,
                score: posterior.expectedValueUSD * posterior.tractability,
                expectedValueUSD: posterior.expectedValueUSD,
                credibleIntervalUSD: posterior.lowerCredibleUSD...posterior.upperCredibleUSD,
                reasoning: posterior.reasoning + [
                    "tractability \(String(format: "%.2f", posterior.tractability))",
                    "credible band \(Int(posterior.lowerCredibleUSD))-\(Int(posterior.upperCredibleUSD))"
                ]
            )
        }
    }

    static func killRecommendations(_ posteriors: [CompanyProfitPosterior], priors: [String: CompanyProfitPrior]) -> [CompanyKillRecommendation] {
        posteriors.compactMap { posterior in
            guard let prior = priors[posterior.templateID],
                  posterior.companyAgeDays >= prior.killEvaluationDay,
                  (posterior.expectedValueUSD < prior.killThresholdEVUSD ||
                   posterior.probabilityMRRExceedsTarget < prior.killProbabilityThreshold)
            else { return nil }
            return CompanyKillRecommendation(companyID: posterior.companyID, approvalGated: true, reason: "belowTemplateKillThreshold")
        }
    }

    static func nightlySnapshot(
        companies: [CompanyProfitActiveCompanyInput],
        priors: [String: CompanyProfitPrior],
        now: Date = Date()
    ) -> CompanyProfitNightlySnapshot {
        let posteriors = companies
            .filter(\.isActive)
            .compactMap { company -> CompanyProfitPosterior? in
                guard let prior = priors[company.templateID] else { return nil }
                return posterior(
                    companyID: company.companyID,
                    prior: prior,
                    actualRevenueUSD: company.actualRevenueUSD,
                    metricObservations: company.metricObservations,
                    companyAgeDays: company.companyAgeDays,
                    now: now
                )
            }
        return CompanyProfitNightlySnapshot(generatedAt: now, posteriors: posteriors)
    }

    static func overridePrior(
        _ prior: CompanyProfitPrior,
        override: CompanyProfitPriorOverride
    ) -> (prior: CompanyProfitPrior, event: CompanyEvent) {
        var updated = prior
        var metrics = updated.effectiveMetricPriors
        let current = metrics[override.metric] ?? CompanyProfitMetricPrior(
            metric: override.metric,
            expectedValue: override.expectedValue,
            lowerCredible: override.expectedValue * 0.5,
            upperCredible: override.expectedValue * 1.5
        )
        metrics[override.metric] = CompanyProfitMetricPrior(
            metric: override.metric,
            expectedValue: override.expectedValue,
            lowerCredible: min(current.lowerCredible, override.expectedValue * 0.75),
            upperCredible: max(current.upperCredible, override.expectedValue * 1.25)
        )
        updated.metricPriors = metrics
        let event = CompanyEvent(
            occurredAt: override.createdAt,
            companyID: override.companyID,
            actor: override.createdBy,
            kind: .governanceDecisionRecorded,
            summary: "Profit prior override for \(override.metric.rawValue)",
            metadata: [
                "templateID": override.templateID,
                "metric": override.metric.rawValue,
                "expectedValue": String(format: "%.2f", override.expectedValue),
                "reason": override.reason
            ]
        )
        return (updated, event)
    }

    static func calibrationReport(
        predicted: [String: Double],
        actual: [String: Double],
        quarter: String = "current",
        historicalCalibrationError: [String: Double] = [:]
    ) -> CompanyPriorCalibrationReport {
        let rows = predicted.compactMap { key, value -> CompanyPriorCalibrationRow? in
            guard let actualValue = actual[key] else { return nil }
            return CompanyPriorCalibrationRow(companyID: key, predictedUSD: value, actualUSD: actualValue)
        }
        let error = rows.isEmpty ? 0 : rows.map { abs($0.predictedUSD - $0.actualUSD) / max(1, abs($0.actualUSD)) }.reduce(0, +) / Double(rows.count)
        var history = historicalCalibrationError
        history[quarter] = error
        return CompanyPriorCalibrationReport(
            quarter: quarter,
            predictedVsActual: rows,
            calibrationError: error,
            historicalCalibrationError: history
        )
    }

    static func backtest(
        history: [CompanyClosedCompanyHistory],
        priors: [String: CompanyProfitPrior]
    ) -> CompanyPriorBacktestReport {
        let decisions = history.compactMap { record -> CompanyPriorBacktestDecision? in
            guard let prior = priors[record.templateID] else { return nil }
            let posterior = posterior(
                companyID: record.companyID,
                prior: prior,
                actualRevenueUSD: record.day60RevenueUSD,
                metricObservations: [.mrr60: record.day60RevenueUSD, .mrr90: record.day180MRRUSD],
                companyAgeDays: 60
            )
            let predictedKeep = posterior.probabilityMRRExceedsTarget >= prior.killProbabilityThreshold &&
                posterior.expectedValueUSD >= prior.killThresholdEVUSD
            return CompanyPriorBacktestDecision(
                companyID: record.companyID,
                predictedKeep: predictedKeep,
                actualKeep: record.actualKept,
                probability: posterior.probabilityMRRExceedsTarget
            )
        }
        let correct = decisions.filter { $0.predictedKeep == $0.actualKeep }.count
        let accuracy = decisions.isEmpty ? 0 : Double(correct) / Double(decisions.count)
        return CompanyPriorBacktestReport(decisions: decisions, accuracy: accuracy)
    }

    private static func posteriorMetrics(
        prior: CompanyProfitPrior,
        observedRevenueUSD: Double,
        observations: [CompanyProfitMetric: Double]
    ) -> [CompanyProfitMetricPosterior] {
        CompanyProfitMetric.allCases.map { metric in
            let seeded = prior.effectiveMetricPriors[metric] ?? CompanyProfitMetricPrior(
                metric: metric,
                expectedValue: observedRevenueUSD,
                lowerCredible: observedRevenueUSD * 0.5,
                upperCredible: observedRevenueUSD * 1.5
            )
            let observed = observations[metric] ?? defaultObservation(metric: metric, revenueUSD: observedRevenueUSD)
            let expected = (seeded.expectedValue * 0.4) + (observed * 0.6)
            let spread = max(abs(seeded.upperCredible - seeded.lowerCredible) * 0.35, abs(expected) * 0.15)
            return CompanyProfitMetricPosterior(
                metric: metric,
                expectedValue: expected,
                lowerCredible: max(0, expected - spread),
                upperCredible: expected + spread
            )
        }
    }

    private static func defaultObservation(metric: CompanyProfitMetric, revenueUSD: Double) -> Double {
        switch metric {
        case .mrr30: return revenueUSD * 0.5
        case .mrr60: return revenueUSD
        case .mrr90: return revenueUSD * 1.2
        case .grossMargin: return revenueUSD > 0 ? 0.65 : 0.35
        case .churn: return revenueUSD > 0 ? 0.06 : 0.20
        case .cac: return revenueUSD > 0 ? max(10, revenueUSD * 0.15) : 75
        case .paybackPeriodDays: return revenueUSD > 0 ? 45 : 120
        case .timeToFirstRevenueDays: return revenueUSD > 0 ? 21 : 90
        }
    }

    private static func probabilityMRRExceedsTarget(
        expectedValueUSD: Double,
        lowerCredibleUSD: Double,
        upperCredibleUSD: Double,
        targetMRRUSD: Double
    ) -> Double {
        if targetMRRUSD <= lowerCredibleUSD { return 0.90 }
        if targetMRRUSD >= upperCredibleUSD { return 0.10 }
        let range = max(1, upperCredibleUSD - lowerCredibleUSD)
        return max(0.05, min(0.95, (upperCredibleUSD - targetMRRUSD) / range))
    }
}
