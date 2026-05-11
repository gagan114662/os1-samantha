import Foundation
import Testing
@testable import OS1

struct CompanyIntegrationTests {
    @Test
    func workflowPlansPreferApiThenConnectorThenMCPBeforeBrowser() {
        let plan = CompanyIntegrationPlanner.plan(
            companyID: "co",
            domain: .payments,
            workflowName: "Create checkout",
            paths: [
                path(id: "browser", kind: .browserAutomation, granted: true),
                path(id: "mcp", kind: .mcpTool, granted: true),
                path(id: "api", kind: .officialAPI, granted: true),
                path(id: "connector", kind: .stableConnector, granted: true)
            ]
        )

        #expect(plan.preferredPaths.map(\.kind) == [.officialAPI, .stableConnector, .mcpTool, .browserAutomation])
        #expect(plan.selectedPath?.kind == .officialAPI)
    }

    @Test
    func browserAutomationIsExplicitHighFragilityFallback() {
        let plan = CompanyIntegrationPlanner.plan(
            companyID: "co",
            domain: .crm,
            workflowName: "Update lead",
            paths: [
                path(id: "api", kind: .officialAPI, granted: false),
                path(id: "browser", kind: .browserAutomation, granted: true)
            ]
        )

        #expect(plan.selectedPath?.kind == .browserAutomation)
        #expect(plan.selectedPath?.kind.fragility == .high)
        #expect(plan.usesBrowserFallback)
    }

    @Test
    func connectorFailuresCreateActionableBlockedReasons() {
        let plan = CompanyIntegrationPlanner.plan(
            companyID: "co",
            domain: .email,
            workflowName: "Send invoice reminder",
            paths: [path(id: "api", kind: .officialAPI, granted: false)]
        )
        let report = CompanyIntegrationPlanner.healthReport(companyID: "co", workflowPlans: [plan])

        #expect(report.blockedReason == "Connect or authorize email for Send invoice reminder.")
        #expect(report.failures.first?.kind == .permissionMissing)
    }

    @Test
    func rateLimitsAndAuthErrorsFeedSchedulerBackpressure() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let authReport = CompanyIntegrationHealthReport(
            companyID: "auth",
            workflowPlans: [],
            failures: [
                CompanyIntegrationFailure(
                    id: "auth-fail",
                    companyID: "auth",
                    workflowID: "email",
                    provider: "gmail",
                    kind: .authError,
                    occurredAt: now,
                    retryAfter: nil,
                    operatorAction: "Reconnect Gmail OAuth for auth."
                )
            ]
        )
        let rateReport = CompanyIntegrationHealthReport(
            companyID: "rate",
            workflowPlans: [
                CompanyWorkflowIntegrationPlan(
                    id: "rate-email",
                    companyID: "rate",
                    domain: .email,
                    workflowName: "Send campaign",
                    preferredPaths: [
                        path(
                            id: "gmail-api",
                            kind: .officialAPI,
                            granted: true,
                            rateLimit: CompanyIntegrationRateLimit(limit: 100, remaining: 5, resetAt: nil)
                        )
                    ]
                )
            ],
            failures: []
        )
        let plan = CompanyScaleScheduler.plan(
            sessions: [
                session(id: "auth", status: .idle),
                session(id: "rate", status: .idle)
            ],
            now: now,
            integrationReports: ["auth": authReport, "rate": rateReport]
        )

        #expect(plan.blockedIDs == ["auth"])
        #expect(plan.backpressureReasons.contains("connectorRateLimit"))
        #expect(plan.queuedIDs.contains("rate"))
    }

    @Test
    func doctorSummarizesConnectorHealthProblems() {
        let report = CompanyIntegrationHealthReport(
            companyID: "co",
            workflowPlans: [
                CompanyWorkflowIntegrationPlan(
                    id: "crm-browser",
                    companyID: "co",
                    domain: .crm,
                    workflowName: "Update lead",
                    preferredPaths: [path(id: "browser", kind: .browserAutomation, granted: true)]
                )
            ],
            failures: [
                CompanyIntegrationFailure(
                    id: "rate",
                    companyID: "co",
                    workflowID: "crm-browser",
                    provider: "crm",
                    kind: .rateLimited,
                    occurredAt: Date(timeIntervalSince1970: 1_700_000_000),
                    retryAfter: nil,
                    operatorAction: "Wait for CRM reset."
                )
            ]
        )

        let problems = DoctorViewModel.connectorHealthProblems(reports: [report])

        #expect(problems.contains { $0.contains("connector rate limit pressure") })
        #expect(problems.contains { $0.contains("browser fallback workflows") })
    }

    private func path(
        id: String,
        kind: CompanyIntegrationPathKind,
        granted: Bool,
        rateLimit: CompanyIntegrationRateLimit? = nil
    ) -> CompanyIntegrationPath {
        CompanyIntegrationPath(
            id: id,
            kind: kind,
            provider: id,
            toolName: nil,
            permissions: [
                CompanyIntegrationPermission(scope: "scope", required: true, granted: granted)
            ],
            rateLimit: rateLimit
        )
    }

    private func session(id: String, status: CodexSession.Status) -> CodexSession {
        CodexSession(
            id: id,
            title: id,
            task: "Run integration workflow",
            worktreePath: "/tmp/\(id)",
            branch: "company/\(id)",
            status: status,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: nil,
            exitCode: nil,
            pid: nil
        )
    }
}
