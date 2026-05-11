import Foundation
import Testing
@testable import OS1

struct CompanyExperimentStatisticsTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func weakSampleAndAttributionProduceWarnings() {
        let result = CompanyExperimentStatisticsEngine.evaluate(
            companyID: "company-1",
            experimentID: "exp-1",
            template: CompanyExperimentStatisticsEngine.template(kind: .landingPage),
            events: [
                event(id: "visit-1", kind: .visit),
                event(id: "visit-2", kind: .visit),
                event(id: "signup-1", kind: .signup, attributedToEventID: nil)
            ],
            now: now
        )

        #expect(result.evidenceStrength == .weak)
        #expect(result.uncertaintyNotes.contains { $0.hasPrefix("sampleSizeBelowMinimum") })
        #expect(result.uncertaintyNotes.contains { $0.hasPrefix("attributedConversionsBelowMinimum") })
        #expect(result.falseSignalWarnings.contains("vanityMetricsOnly"))
    }

    @Test
    func falseSignalFiltersBotsSelfClicksDuplicatesAndPaidLeakage() {
        let result = CompanyExperimentStatisticsEngine.evaluate(
            companyID: "company-1",
            experimentID: "exp-1",
            template: CompanyExperimentStatisticsEngine.template(kind: .ads),
            events: [
                event(id: "bot", kind: .visit, isBot: true),
                event(id: "self", kind: .visit, isSelfClick: true),
                event(id: "dupe", kind: .signup, isDuplicateLead: true),
                event(id: "paid", kind: .visit, channel: "paid", attributedToEventID: nil)
            ],
            now: now
        )

        #expect(result.falseSignalWarnings.contains("botTrafficFiltered"))
        #expect(result.falseSignalWarnings.contains("selfClicksFiltered"))
        #expect(result.falseSignalWarnings.contains("duplicateLeadsFiltered"))
        #expect(result.falseSignalWarnings.contains("paidTrafficAttributionLeakage"))
    }

    @Test
    func experimentResultsAreReproducibleFromRawEvents() {
        let rawEvents = strongEvents()
        let first = CompanyExperimentStatisticsEngine.evaluate(
            companyID: "company-1",
            experimentID: "exp-1",
            template: CompanyExperimentStatisticsEngine.template(kind: .pricing),
            events: rawEvents.shuffled(),
            now: now
        )
        let second = CompanyExperimentStatisticsEngine.evaluate(
            companyID: "company-1",
            experimentID: "exp-1",
            template: CompanyExperimentStatisticsEngine.template(kind: .pricing),
            events: rawEvents.reversed(),
            now: now
        )

        #expect(first.reproducibilityHash == second.reproducibilityHash)
        #expect(first.rawEventIDs == second.rawEventIDs)
        #expect(first.funnel == second.funnel)
    }

    @Test
    func lifecyclePromotionIncludesEvidenceStrengthAndUncertainty() {
        let result = CompanyExperimentStatisticsEngine.evaluate(
            companyID: "company-1",
            experimentID: "exp-1",
            template: CompanyExperimentStatisticsEngine.template(kind: .pricing),
            events: strongEvents(),
            now: now
        )
        let decision = CompanyLifecycleEngine.decide(snapshot(
            stage: .validating,
            validation: .readyToBuild,
            experimentEvidence: result
        ))

        #expect(decision.action == .promote)
        #expect(decision.rationale.contains("Evidence strength: strong"))
        #expect(decision.rationale.contains("Uncertainty: none"))
    }

    @Test
    func lifecycleCannotAutoScaleOnVanityMetricsAlone() {
        let vanity = CompanyExperimentStatisticsEngine.evaluate(
            companyID: "company-1",
            experimentID: "exp-1",
            template: CompanyExperimentStatisticsEngine.template(kind: .ads),
            events: (0..<200).map { event(id: "visit-\($0)", kind: .visit) },
            now: now
        )
        let ledger = CompanyLedgerSummary(entries: [
            CompanyLedgerEntry(
                id: "revenue",
                companyID: "company-1",
                occurredAt: now,
                kind: .revenue,
                amountUSD: 250,
                source: "manual",
                confidence: .verified,
                note: "invoice=1"
            )
        ])

        let decision = CompanyLifecycleEngine.decide(snapshot(
            stage: .revenuePositive,
            ledger: ledger,
            experimentEvidence: vanity
        ))

        #expect(vanity.falseSignalWarnings.contains("vanityMetricsOnly"))
        #expect(decision.action == .hold)
        #expect(decision.rationale.contains("Scale blocked"))
    }

    private func strongEvents() -> [CompanyExperimentEvent] {
        var events: [CompanyExperimentEvent] = []
        for index in 0..<35 {
            events.append(event(id: "visit-\(index)", kind: .visit, subjectID: "visitor-\(index)"))
        }
        for index in 0..<4 {
            events.append(event(
                id: "purchase-\(index)",
                kind: .purchase,
                subjectID: "buyer-\(index)",
                attributedToEventID: "visit-\(index)",
                revenueUSD: 50
            ))
        }
        return events
    }

    private func snapshot(
        stage: CodexSession.LifecycleStage,
        validation: CompanyValidationResult.Decision? = nil,
        ledger: CompanyLedgerSummary = .empty,
        experimentEvidence: CompanyExperimentResult? = nil
    ) -> CompanyEvidenceSnapshot {
        CompanyEvidenceSnapshot(
            companyID: "company-1",
            stage: stage,
            validationDecision: validation,
            ledger: ledger,
            budgetReport: nil,
            distribution: nil,
            experimentEvidence: experimentEvidence,
            failureCount: 0,
            complianceRisk: .low,
            overrideReason: nil,
            artifactPaths: []
        )
    }

    private func event(
        id: String,
        kind: CompanyExperimentEvent.Kind,
        subjectID: String? = "subject-1",
        channel: String = "organic",
        attributedToEventID: String? = "visit-1",
        isBot: Bool = false,
        isSelfClick: Bool = false,
        isDuplicateLead: Bool = false,
        revenueUSD: Double = 0
    ) -> CompanyExperimentEvent {
        CompanyExperimentEvent(
            id: id,
            companyID: "company-1",
            experimentID: "exp-1",
            cohortID: "a",
            subjectID: subjectID,
            kind: kind,
            channel: channel,
            occurredAt: now.addingTimeInterval(-60),
            attributedToEventID: attributedToEventID,
            isBot: isBot,
            isSelfClick: isSelfClick,
            isDuplicateLead: isDuplicateLead,
            revenueUSD: revenueUSD
        )
    }
}
