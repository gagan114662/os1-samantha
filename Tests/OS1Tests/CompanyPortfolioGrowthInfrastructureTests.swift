import Foundation
import Testing
@testable import OS1

struct CompanyPortfolioGrowthInfrastructureTests {
    @Test
    func portfolioDigestRBACEntityTreasuryAndEmailProvisioningWork() {
        let digest = OperatorPortfolioDigest(generatedAt: Date(), companyCount: 100, openApprovals: 7, anomalies: ["stripe spike"], revenueUSD: 1234)
        let owner = OS1Operator(id: "owner", email: "o@example.com", role: .owner, companyScope: nil, vacationBackupID: nil, vacationMode: false, lastSeenAt: nil)
        let va = OS1Operator(id: "va", email: "va@example.com", role: .va, companyScope: ["co"], vacationBackupID: "backup", vacationMode: true, lastSeenAt: nil)
        let entity = CompanyEntity(id: "ent", companyID: "co", legalName: "Acme LLC", jurisdiction: "US-DE", type: .llc, ein: nil, formationProvider: "stripe-atlas")
        let bankEntry = ledger(id: "b1", ref: "bank-1", amount: 10)
        let existing = ledger(id: "l1", ref: "bank-2", amount: 5)
        let records = BusinessEmailProvisioner.dnsRecords(domain: "example.com")

        #expect(digest.markdown.contains("Open approvals: 7"))
        #expect(OperatorRBAC.canApprove(va, companyID: "co"))
        #expect(OperatorRBAC.routeApproval(assignedTo: va, owner: owner, now: Date(), expiresAt: Date().addingTimeInterval(60)) == "backup")
        #expect(entity.isValidJurisdiction)
        #expect(TreasurySync.reconcile(bankTransactions: [bankEntry, existing], ledger: [existing]).map(\.id) == ["b1"])
        #expect(BusinessEmailProvisioner.isVerified(records: records))
    }

    @Test
    func anomalyKillSwitchAndPolicyWatcherProtectFleet() {
        let samples = (0..<7).map {
            CompanyMetricSample(companyID: "co", metric: "spend", value: 10 + Double($0 % 2), capturedAt: Date(timeIntervalSince1970: Double($0)))
        }
        let latest = CompanyMetricSample(companyID: "co", metric: "spend", value: 100, capturedAt: Date(timeIntervalSince1970: 99))
        let anomaly = CompanyAnomalyDetector.detect(samples: samples, latest: latest)
        let freeze = FleetKillSwitch(active: true, affecting: "stripe", operatorID: "system", createdAt: Date())

        #expect(anomaly?.action == "pauseOutbound")
        #expect(freeze.blocks(companyDependencies: ["stripe", "meta"]))
        #expect(!freeze.blocks(companyDependencies: ["etsy"]))
        #expect(PlatformPolicyWatcher.defaultPlatforms.contains("stripe"))
        #expect(PlatformPolicyWatcher.highSeverityAffectsAIContent("High severity: AI content is now restricted"))
    }

    @Test
    func reviewsNPSReferralAndChurnFeedGrowthLoops() {
        let review = CompanyReview(id: "r", companyID: "co", platform: .trustpilot, rating: 5, text: "Great result", provenance: "fixture")
        let schema = TestimonialCollector.schemaOrg(reviews: [review])
        let program = CompanyReferralProgram(
            id: "prog",
            companyID: "co",
            kind: .doubleSided,
            referrerReward: .init(kind: .cashUSD, value: 20, capPerReferrer: 100),
            friendReward: .init(kind: .storeCreditUSD, value: 20, capPerReferrer: nil),
            sameIPBlock: true,
            payoutHoldDays: 14
        )
        let code = CompanyReferralCode(id: "code", companyID: "co", customerID: "cust-a", code: "A20", landingURL: URL(string: "https://example.com/r/A20")!)
        let attr = CompanyReferralEngine.credit(program: program, code: code, friendCustomerID: "cust-b", purchaseID: "pi_1", ipAddress: "1.1.1.1")
        let churn = CompanyChurnRiskScorer.score(.init(customerID: "cust", usageDecline: 0.9, daysSinceLogin: 30, npsScore: 5, supportTickets: 2))
        let offers = SaveOfferLibrary(companyID: "co", maxFreeMonthsLifetime: 3, grantedFreeMonthsByCustomer: ["cust": 2])

        #expect(NPSSurveyRunner.route(score: 10) == ["review-request", "referral-program"])
        #expect(schema.contains("AggregateRating"))
        #expect(CompanyReferralEngine.fraudReason(referrerIP: "1.1.1.1", friendIP: "1.1.1.1", program: program) == "same-IP self-referral denied")
        #expect(attr.creditedUSD == 20)
        #expect(churn.recommendedAction == "save-offer")
        #expect(offers.canGrant(customerID: "cust", months: 1))
        #expect(!offers.canGrant(customerID: "cust", months: 2))
    }

    @Test
    func lessonBusNicheGraphAndPlaybookCloneCompoundAcrossFleet() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lessons-\(UUID().uuidString).jsonl")
        let lesson = LessonLearned(id: "lesson", sourceCompanyID: "a", niche: "roofers", kind: .hookPattern, evidence: "3x CTR", confidence: 0.91)
        try PortfolioLessonBus.append(lesson, to: url)
        let loaded = try PortfolioLessonBus.load(from: url)
        let subscribed = PortfolioLessonBus.subscriptions(lessons: loaded, niche: "roofers", kind: .hookPattern, minimumConfidence: 0.8)
        let clusters = CompanyNicheGraph.siblingClusters([
            .init(id: "a", templateID: "x", audience: "Roofers", channel: "X"),
            .init(id: "b", templateID: "x", audience: "roofers", channel: "x"),
            .init(id: "c", templateID: "li", audience: "dentists", channel: "LinkedIn")
        ])
        let playbook = PortfolioPlaybook(
            id: "pb",
            version: 1,
            templateID: "x",
            voiceProfile: .init(companyID: "a", examples: ["clear"]),
            hookLibrary: .init(companyID: "a", topHooks: ["stop losing jobs"]),
            watcherIDs: ["w"],
            license: "internal",
            marketplaceEnabled: false
        )
        let clone = PlaybookMarketplace.clone(playbook, newCompanyID: "new", newNiche: "plumbers")

        #expect(subscribed.map(\.id) == ["lesson"])
        #expect(clusters["roofers|x"] == ["a", "b"])
        #expect(clone.launchAssets.contains("playbook:pb"))
        #expect(!playbook.marketplaceEnabled)
    }

    private func ledger(id: String, ref: String, amount: Double) -> CompanyLedgerEntry {
        CompanyLedgerEntry(
            id: id,
            companyID: "co",
            occurredAt: Date(),
            kind: .revenue,
            category: .sales,
            amountUSD: amount,
            source: "bank",
            sourceReference: ref,
            confidence: .verified,
            note: "id=\(ref)"
        )
    }
}
