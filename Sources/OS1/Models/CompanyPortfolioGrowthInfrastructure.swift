import Foundation

struct OperatorPortfolioDigest: Codable, Hashable {
    var generatedAt: Date
    var companyCount: Int
    var openApprovals: Int
    var anomalies: [String]
    var revenueUSD: Double

    var markdown: String {
        """
        # Portfolio Digest
        Companies: \(companyCount)
        Open approvals: \(openApprovals)
        Revenue: $\(String(format: "%.2f", revenueUSD))
        Anomalies: \(anomalies.joined(separator: ", "))
        """
    }
}

struct OS1Operator: Codable, Hashable, Identifiable {
    enum Role: String, Codable, CaseIterable, Hashable {
        case owner
        case approver
        case viewer
        case va
    }

    let id: String
    var email: String
    var role: Role
    var companyScope: Set<String>?
    var vacationBackupID: String?
    var vacationMode: Bool
    var lastSeenAt: Date?
}

enum OperatorRBAC {
    static func canApprove(_ operatorRecord: OS1Operator, companyID: String) -> Bool {
        guard operatorRecord.role == .owner || operatorRecord.role == .approver || operatorRecord.role == .va else {
            return false
        }
        guard let scope = operatorRecord.companyScope else { return true }
        return scope.contains(companyID)
    }

    static func routeApproval(assignedTo: OS1Operator, owner: OS1Operator, now: Date, expiresAt: Date) -> String {
        if assignedTo.vacationMode, let backup = assignedTo.vacationBackupID { return backup }
        return now > expiresAt ? owner.id : assignedTo.id
    }
}

struct CompanyEntity: Codable, Hashable, Identifiable {
    enum EntityType: String, Codable, CaseIterable, Hashable {
        case llc
        case cCorp
        case soleProp
    }

    let id: String
    var companyID: String
    var legalName: String
    var jurisdiction: String
    var type: EntityType
    var ein: String?
    var formationProvider: String?

    var isValidJurisdiction: Bool {
        ["US-DE", "US-WY", "US-CA", "CA-ON", "GB"].contains(jurisdiction)
    }
}

struct TreasurySync {
    static func reconcile(bankTransactions: [CompanyLedgerEntry], ledger: [CompanyLedgerEntry]) -> [CompanyLedgerEntry] {
        let knownRefs = Set(ledger.compactMap(\.sourceReference))
        return bankTransactions.filter { entry in
            guard let ref = entry.sourceReference else { return true }
            return !knownRefs.contains(ref)
        }
    }
}

enum BusinessEmailProvisioner {
    static func dnsRecords(domain: String) -> [String] {
        [
            "\(domain) TXT v=spf1 include:_spf.google.com ~all",
            "google._domainkey.\(domain) TXT k=rsa; p=fixture",
            "_dmarc.\(domain) TXT v=DMARC1; p=quarantine"
        ]
    }

    static func isVerified(records: [String]) -> Bool {
        records.contains { $0.contains("v=spf1") } &&
            records.contains { $0.contains("k=rsa") } &&
            records.contains { $0.contains("v=DMARC1") }
    }
}

struct CompanyMetricSample: Codable, Hashable {
    var companyID: String
    var metric: String
    var value: Double
    var capturedAt: Date
}

struct CompanyAnomaly: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var metric: String
    var value: Double
    var baseline: Double
    var modifiedZScore: Double
    var action: String
}

enum CompanyAnomalyDetector {
    static func detect(samples: [CompanyMetricSample], latest: CompanyMetricSample) -> CompanyAnomaly? {
        let values = samples.filter { $0.metric == latest.metric && $0.companyID == latest.companyID }.map(\.value)
        guard values.count >= 5 else { return nil }
        let median = Self.median(values)
        let deviations = values.map { abs($0 - median) }
        let mad = max(0.0001, Self.median(deviations))
        let score = 0.6745 * (latest.value - median) / mad
        guard abs(score) > 3 else { return nil }
        return CompanyAnomaly(
            id: "anom-\(latest.companyID)-\(latest.metric)-\(Int(latest.capturedAt.timeIntervalSince1970))",
            companyID: latest.companyID,
            metric: latest.metric,
            value: latest.value,
            baseline: median,
            modifiedZScore: score,
            action: score > 0 ? "pauseOutbound" : "notify"
        )
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

struct FleetKillSwitch: Codable, Hashable {
    var active: Bool
    var affecting: String?
    var operatorID: String
    var createdAt: Date

    func blocks(companyDependencies: Set<String>) -> Bool {
        guard active else { return false }
        guard let affecting else { return true }
        return companyDependencies.contains(affecting)
    }
}

enum PlatformPolicyWatcher {
    static let defaultPlatforms = ["stripe", "meta", "apple", "etsy", "linkedin"]

    static func digest(changes: [String]) -> String {
        changes.sorted().map { "- \($0)" }.joined(separator: "\n")
    }

    static func highSeverityAffectsAIContent(_ text: String) -> Bool {
        let lower = text.lowercased()
        return lower.contains("ai") && (lower.contains("prohibit") || lower.contains("high severity") || lower.contains("restricted"))
    }
}

struct CompanyReviewRequest: Codable, Hashable, Identifiable {
    enum TargetPlatform: String, Codable, CaseIterable, Hashable {
        case onPlatform
        case googleBiz
        case trustpilot
        case g2
        case capterra
        case yelp
        case internalReview
    }

    let id: String
    var companyID: String
    var orderID: String
    var customerID: String
    var targetPlatform: TargetPlatform
    var touchCount: Int
    var nextSendAt: Date
    var approvedForDisplay: Bool
}

struct CompanyReview: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var platform: CompanyReviewRequest.TargetPlatform
    var rating: Int
    var text: String
    var provenance: String
}

struct CompanyNPSSurvey: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var customerID: String
    var score: Int
    var comment: String
}

enum NPSSurveyRunner {
    static func route(score: Int) -> [String] {
        if score <= 6 { return ["support-save"] }
        if score >= 9 { return ["review-request", "referral-program"] }
        return ["open-text-followup"]
    }
}

enum TestimonialCollector {
    static func schemaOrg(reviews: [CompanyReview]) -> String {
        let count = reviews.count
        let average = reviews.isEmpty ? 0 : Double(reviews.map(\.rating).reduce(0, +)) / Double(count)
        return #"{"@context":"https://schema.org","@type":"AggregateRating","ratingValue":"\#(String(format: "%.1f", average))","reviewCount":"\#(count)"}"#
    }
}

enum CaseStudyGenerator {
    static func markdown(testimonial: CompanyReview, contact: CompanyCRMContact, knowledge: CompanyKnowledgeBase) -> String {
        "# Case Study\nCustomer: \(contact.name)\nRating: \(testimonial.rating)/5\nProof: \(testimonial.text)\nContext: \(knowledge.chunks.first?.text ?? "")"
    }
}

struct CompanyReferralProgram: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case doubleSided
        case singleSidedReferrer
        case singleSidedFriend
        case leaderboard
        case affiliateLifetime
    }

    enum RewardKind: String, Codable, CaseIterable, Hashable {
        case cashUSD
        case storeCreditUSD
        case freeMonth
    }

    struct Reward: Codable, Hashable {
        var kind: RewardKind
        var value: Double
        var capPerReferrer: Double?
    }

    let id: String
    var companyID: String
    var kind: Kind
    var referrerReward: Reward
    var friendReward: Reward?
    var sameIPBlock: Bool
    var payoutHoldDays: Int
}

struct CompanyReferralCode: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var customerID: String
    var code: String
    var landingURL: URL
}

struct CompanyReferralAttribution: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var referralCode: String
    var referrerCustomerID: String
    var friendCustomerID: String
    var purchaseID: String
    var creditedUSD: Double
    var ipAddress: String
}

enum CompanyReferralEngine {
    static func fraudReason(referrerIP: String, friendIP: String, program: CompanyReferralProgram) -> String? {
        program.sameIPBlock && referrerIP == friendIP ? "same-IP self-referral denied" : nil
    }

    static func credit(program: CompanyReferralProgram, code: CompanyReferralCode, friendCustomerID: String, purchaseID: String, ipAddress: String) -> CompanyReferralAttribution {
        CompanyReferralAttribution(
            id: "ref-\(purchaseID)",
            companyID: program.companyID,
            referralCode: code.code,
            referrerCustomerID: code.customerID,
            friendCustomerID: friendCustomerID,
            purchaseID: purchaseID,
            creditedUSD: program.referrerReward.value,
            ipAddress: ipAddress
        )
    }
}

struct CompanyChurnSignal: Codable, Hashable {
    var customerID: String
    var usageDecline: Double
    var daysSinceLogin: Int
    var npsScore: Int?
    var supportTickets: Int
}

struct CompanyChurnRisk: Codable, Hashable {
    var customerID: String
    var score: Double
    var primaryReason: String
    var recommendedAction: String
}

enum CompanyChurnRiskScorer {
    static func score(_ signal: CompanyChurnSignal) -> CompanyChurnRisk {
        let npsPenalty = (signal.npsScore ?? 10) <= 6 ? 0.25 : 0
        let score = min(1, signal.usageDecline * 0.45 + min(1, Double(signal.daysSinceLogin) / 60) * 0.25 + min(1, Double(signal.supportTickets) / 4) * 0.2 + npsPenalty)
        let reason = signal.usageDecline >= 0.7 ? "usage decline" : (npsPenalty > 0 ? "detractor NPS" : "login gap")
        let action = score >= 0.75 ? "save-offer" : (score >= 0.45 ? "win-back-draft" : "monitor")
        return CompanyChurnRisk(customerID: signal.customerID, score: score, primaryReason: reason, recommendedAction: action)
    }
}

struct SaveOfferLibrary: Codable, Hashable {
    var companyID: String
    var maxFreeMonthsLifetime: Int
    var grantedFreeMonthsByCustomer: [String: Int]

    func canGrant(customerID: String, months: Int) -> Bool {
        (grantedFreeMonthsByCustomer[customerID, default: 0] + months) <= maxFreeMonthsLifetime
    }
}

enum CohortRetentionDashboard {
    static func retention(signups: [String: Date], activeCustomerIDs: Set<String>) -> Double {
        guard !signups.isEmpty else { return 0 }
        let active = signups.keys.filter { activeCustomerIDs.contains($0) }.count
        return Double(active) / Double(signups.count)
    }
}

struct LessonLearned: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case hookPattern
        case audience
        case channel
        case postTime
        case creative
        case offer
    }

    let id: String
    var sourceCompanyID: String
    var niche: String
    var kind: Kind
    var evidence: String
    var confidence: Double
}

enum PortfolioLessonBus {
    static func append(_ lesson: LessonLearned, to url: URL) throws {
        let data = try JSONEncoder().encode(lesson)
        let line = String(data: data, encoding: .utf8)! + "\n"
        if FileManager.default.fileExists(atPath: url.path) {
            let handle = try FileHandle(forWritingTo: url)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(line.utf8))
            try handle.close()
        } else {
            try line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func load(from url: URL) throws -> [LessonLearned] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        return try String(contentsOf: url)
            .split(separator: "\n")
            .compactMap { try JSONDecoder().decode(LessonLearned.self, from: Data($0.utf8)) }
    }

    static func subscriptions(lessons: [LessonLearned], niche: String, kind: LessonLearned.Kind, minimumConfidence: Double) -> [LessonLearned] {
        lessons.filter { $0.niche == niche && $0.kind == kind && $0.confidence >= minimumConfidence }
    }
}

struct CompanyNicheNode: Codable, Hashable, Identifiable {
    let id: String
    var templateID: String
    var audience: String
    var channel: String
}

enum CompanyNicheGraph {
    static func siblingClusters(_ nodes: [CompanyNicheNode]) -> [String: [String]] {
        Dictionary(grouping: nodes, by: { "\($0.audience.lowercased())|\($0.channel.lowercased())" })
            .mapValues { $0.map(\.id).sorted() }
    }
}

struct PortfolioPlaybook: Codable, Hashable, Identifiable {
    let id: String
    var version: Int
    var templateID: String
    var voiceProfile: CompanyVoiceProfile?
    var hookLibrary: CompanyHookLibrary
    var watcherIDs: [String]
    var license: String
    var marketplaceEnabled: Bool
}

enum PlaybookMarketplace {
    static func clone(_ playbook: PortfolioPlaybook, newCompanyID: String, newNiche: String) -> CompanyTemplate {
        CompanyTemplate(
            id: "clone-\(newCompanyID)",
            title: "\(newNiche) clone",
            category: .microSaaS,
            channel: "playbook",
            mission: "Launch a company cloned from portfolio playbook \(playbook.id).",
            validationSignals: ["First qualified lead", "First paid conversion", "Healthy support queue"],
            launchAssets: ["playbook:\(playbook.id)"],
            riskNotes: ["Operator approval required before applying cross-company lessons."],
            suggestedCadenceMinutes: 1_440,
            platform: nil
        )
    }
}
