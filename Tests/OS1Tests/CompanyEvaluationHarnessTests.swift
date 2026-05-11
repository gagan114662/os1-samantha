import Foundation
import Testing
@testable import OS1

struct CompanyEvaluationHarnessTests {
    @Test
    func nonLiveEvalsCoverRequiredScenarioCategoriesAndPass() {
        let report = CompanyEvaluationHarness.runNonLive(now: Date(timeIntervalSince1970: 1_800_000_000))
        let categories = Set(report.results.map(\.scenario.category))

        #expect(report.passed)
        #expect(report.results.count == CompanyEvaluationHarness.nonLiveScenarios.count)
        #expect(categories.contains(.ideaScoring))
        #expect(categories.contains(.validationDecision))
        #expect(categories.contains(.approvalRequest))
        #expect(categories.contains(.outreachDrafting))
        #expect(categories.contains(.budgetHandling))
        #expect(categories.contains(.secretRedaction))
        #expect(categories.contains(.errorRecovery))
        #expect(categories.contains(.toolContract))
        #expect(report.averageScore == 100)
    }

    @Test
    func knownUnsafeToolContractsAreBlockedInEvals() {
        #expect(!CompanyEvaluationHarness.unsafeContractsPass())
        for contract in CompanyEvaluationHarness.validContracts() {
            #expect(contract.validationFindings().isEmpty)
        }

        let unsafeLedger = CompanyToolCallContract(
            tool: .ledgerWrite,
            payload: ["companyID": "company", "amountUSD": "99"]
        )
        #expect(unsafeLedger.validationFindings().contains("missing kind"))
        #expect(unsafeLedger.validationFindings().contains("missing sourceReference"))
    }

    @Test
    func evalReportMarkdownIsCIReadable() {
        let report = CompanyEvaluationHarness.runNonLive(now: Date(timeIntervalSince1970: 1_800_000_000))
        let markdown = report.markdown

        #expect(markdown.contains("# OS1 evaluation report"))
        #expect(markdown.contains("company-agent-non-live"))
        #expect(markdown.contains("| Scenario | Category | Status | Score | Findings |"))
        #expect(markdown.contains("Tool calls include safety contracts"))
    }

    @Test
    func liveSandboxScenariosAreDeclaredButNotRunInNonLiveSuite() {
        let liveScenariosAreLive = CompanyEvaluationHarness.liveSandboxScenarios.allSatisfy { $0.live }
        let nonLiveScenariosAreNonLive = CompanyEvaluationHarness.nonLiveScenarios.allSatisfy { !$0.live }

        #expect(CompanyEvaluationHarness.liveSandboxScenarios.count == 2)
        #expect(liveScenariosAreLive)
        #expect(nonLiveScenariosAreNonLive)
    }
}
