import Foundation
import Testing
@testable import OS1

struct CompanyIdeaEngineTests {
    @Test
    func ideaRecordsHaveStructuredSchemaAndScorecard() {
        let idea = CompanyIdeaEngine.candidates(limit: 1)[0]

        #expect(idea.id.hasPrefix("idea-"))
        #expect(!idea.icp.isEmpty)
        #expect(!idea.offer.isEmpty)
        #expect(!idea.channel.isEmpty)
        #expect(!idea.expectedFirstExperiment.isEmpty)
        #expect(!idea.nextAction.isEmpty)
        #expect(idea.scorecard.customerPain > 0)
        #expect(idea.scorecard.willingnessToPay > 0)
        #expect(idea.scorecard.distributionChannel > 0)
        #expect(idea.scorecard.legalComplianceRisk > 0)
        #expect(idea.scorecard.buildComplexity > 0)
        #expect(idea.scorecard.timeToFirstDollar > 0)
        #expect(idea.scorecard.credentialReadiness > 0)
    }

    @Test
    func engineProducesFiftyCandidatesAndRanksTopTenWithEvidence() {
        let candidates = CompanyIdeaEngine.candidates(limit: 50)
        let top = CompanyIdeaEngine.topIdeas(count: 10, from: candidates)

        #expect(candidates.count == 50)
        #expect(top.count == 10)
        #expect(top.allSatisfy { !$0.evidenceLinks.isEmpty })
        #expect(top.map(\.score) == top.map(\.score).sorted(by: >))
    }

    @Test
    func ideasCannotAdvanceWithoutRequiredValidationFields() {
        var idea = CompanyIdeaEngine.candidates(limit: 1)[0]
        #expect(idea.canAdvanceToValidation)
        #expect(CompanyIdeaEngine.advanceToValidation(idea)?.status == .validating)

        idea.icp = ""
        #expect(!idea.canAdvanceToValidation)
        #expect(CompanyIdeaEngine.advanceToValidation(idea) == nil)
    }

    @Test
    func generatorDeduplicatesSimilarIdeas() {
        let template = CompanyTemplateCatalog.all[0]
        let candidates = CompanyIdeaEngine.candidates(from: [template, template], limit: 50)

        #expect(candidates.count == 1)
    }
}
