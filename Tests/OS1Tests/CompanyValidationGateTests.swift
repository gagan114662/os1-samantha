import Foundation
import Testing
@testable import OS1

struct CompanyValidationGateTests {
    @Test
    func validationGateScoresInterviewsFakeDoorAndWillingnessToPay() {
        let interviews = [
            CustomerInterview(id: "i1", companyID: "co", participant: "a", transcript: "manual work hurts", painScore: 9, willingnessToPayUSD: 50),
            CustomerInterview(id: "i2", companyID: "co", participant: "b", transcript: "need it now", painScore: 8, willingnessToPayUSD: 40)
        ]
        let fakeDoor = FakeDoorExperiment(
            id: "fd",
            companyID: "co",
            landingPageURL: URL(string: "https://example.com")!,
            visitors: 100,
            signups: 15,
            checkoutClicks: 5
        )
        let survey = WillingnessToPaySurvey(id: "wtp", companyID: "co", responsesUSD: [20, 40, 50])
        let score = PMFSignalScorer.score(interviews: interviews, fakeDoor: fakeDoor, survey: survey, targetPriceUSD: 40)
        let gate = ValidationGate(companyID: "co", state: .pricingSurvey, minimumScore: 0.55)

        #expect(CustomerInterviewRunner.summarizePain(interviews).contains("average_pain=8.5"))
        #expect(FakeDoorRunner.conversionRate(fakeDoor) == 0.15)
        #expect(survey.medianWTPUSD == 40)
        #expect(score.total >= 0.55)
        #expect(gate.decision(score: score) == .readyToBuild)
    }
}
