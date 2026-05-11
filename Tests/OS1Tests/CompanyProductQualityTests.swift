import Foundation
import Testing
@testable import OS1

struct CompanyProductQualityTests {
    @Test
    func productCannotLaunchUntilQAGatesPassOrOverrideRecorded() {
        let failing = CompanyProductQualityGate.evaluate(
            companyID: "co",
            checks: passingChecks().filter { $0.kind != .brokenLinks } + [
                check(.brokenLinks, status: .failed, summary: "Pricing page returns 404")
            ],
            smokeTests: passingSmokeTests(),
            artifacts: artifacts()
        )
        let overridden = CompanyProductQualityGate.evaluate(
            companyID: "co",
            checks: failing.checks,
            smokeTests: failing.smokeTests,
            artifacts: failing.artifacts,
            overrideReason: "Temporary private beta launch with known broken marketing link."
        )
        let passing = CompanyProductQualityGate.evaluate(
            companyID: "co",
            checks: passingChecks(),
            smokeTests: passingSmokeTests(),
            artifacts: artifacts()
        )

        #expect(!failing.canLaunch)
        #expect(failing.status == .blocked)
        #expect(overridden.canLaunch)
        #expect(overridden.status == .overrideRecorded)
        #expect(passing.canLaunch)
        #expect(passing.status == .readyToLaunch)
    }

    @Test
    func qaFailuresCreateActionableTasks() {
        let report = CompanyProductQualityGate.evaluate(
            companyID: "co",
            checks: passingChecks().filter { $0.kind != .accessibility },
            smokeTests: passingSmokeTests().filter { $0.kind != .supportContact },
            artifacts: artifacts()
        )

        #expect(report.tasks.contains { $0.title == "Run accessibility QA" })
        #expect(report.tasks.contains { $0.title == "Run supportContact smoke test" })
        #expect(report.tasks.allSatisfy { !$0.detail.isEmpty })
    }

    @Test
    func smokeTestsMustRunInSandboxBeforeLiveLaunch() throws {
        var smoke = passingSmokeTests()
        let index = try #require(smoke.firstIndex { $0.kind == .paymentSandbox })
        smoke[index].ranInSandbox = false

        let report = CompanyProductQualityGate.evaluate(
            companyID: "co",
            checks: passingChecks(),
            smokeTests: smoke,
            artifacts: artifacts()
        )

        #expect(!report.canLaunch)
        #expect(report.tasks.contains { $0.detail.contains("must run in sandbox") })
    }

    @Test
    func qualityStatusIsVisiblePerCompany() {
        let report = CompanyProductQualityGate.evaluate(
            companyID: "co",
            checks: passingChecks(),
            smokeTests: passingSmokeTests(),
            artifacts: artifacts()
        )

        #expect(report.companyID == "co")
        #expect(report.qualityStatusLabel == "QA passed")
        #expect(report.artifacts.map(\.kind).contains(.screenshot))
    }

    private func passingChecks() -> [CompanyProductQACheckResult] {
        CompanyProductQACheckKind.allCases.map { kind in
            check(kind, status: .passed, summary: "\(kind.rawValue) passed")
        }
    }

    private func passingSmokeTests() -> [CompanyProductSmokeTestResult] {
        CompanyProductSmokeTestKind.allCases.map { kind in
            CompanyProductSmokeTestResult(
                id: kind.rawValue,
                kind: kind,
                status: .passed,
                ranInSandbox: true,
                summary: "\(kind.rawValue) passed",
                artifactIDs: ["trace"]
            )
        }
    }

    private func check(
        _ kind: CompanyProductQACheckKind,
        status: CompanyProductQAStatus,
        summary: String
    ) -> CompanyProductQACheckResult {
        CompanyProductQACheckResult(
            id: kind.rawValue,
            kind: kind,
            status: status,
            summary: summary,
            artifactIDs: ["screenshot"]
        )
    }

    private func artifacts() -> [CompanyProductQAArtifact] {
        [
            CompanyProductQAArtifact(
                id: "screenshot",
                kind: .screenshot,
                path: "qa/landing-page.png",
                note: "Desktop and mobile screenshot review"
            ),
            CompanyProductQAArtifact(
                id: "trace",
                kind: .trace,
                path: "qa/smoke-test.trace",
                note: "Signup, payment, login, cancellation, and support smoke tests"
            )
        ]
    }
}
