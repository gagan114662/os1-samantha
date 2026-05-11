import Foundation

enum CompanyProductQACheckKind: String, Codable, CaseIterable, Hashable {
    case accessibility
    case mobileResponsiveness
    case brokenLinks
    case loadingSpeed
    case checkoutFlow
    case analytics
    case errorPages
    case securityHeaders
    case screenshotReview
}

enum CompanyProductSmokeTestKind: String, Codable, CaseIterable, Hashable {
    case signup
    case paymentSandbox
    case login
    case cancellation
    case supportContact
}

enum CompanyProductQAStatus: String, Codable, Hashable {
    case passed
    case failed
    case notRun
    case overridden
}

struct CompanyProductQAArtifact: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case screenshot
        case trace
        case report
        case video
        case log
    }

    var id: String
    var kind: Kind
    var path: String
    var note: String
}

struct CompanyProductQACheckResult: Codable, Hashable, Identifiable {
    var id: String
    var kind: CompanyProductQACheckKind
    var status: CompanyProductQAStatus
    var summary: String
    var artifactIDs: [String]
}

struct CompanyProductSmokeTestResult: Codable, Hashable, Identifiable {
    var id: String
    var kind: CompanyProductSmokeTestKind
    var status: CompanyProductQAStatus
    var ranInSandbox: Bool
    var summary: String
    var artifactIDs: [String]
}

struct CompanyProductQualityTask: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var title: String
    var detail: String
    var sourceCheckID: String
}

struct CompanyProductQualityReport: Codable, Hashable {
    enum Status: String, Codable, Hashable {
        case readyToLaunch
        case blocked
        case overrideRecorded
    }

    var companyID: String
    var status: Status
    var canLaunch: Bool
    var checks: [CompanyProductQACheckResult]
    var smokeTests: [CompanyProductSmokeTestResult]
    var artifacts: [CompanyProductQAArtifact]
    var tasks: [CompanyProductQualityTask]
    var overrideReason: String?

    var qualityStatusLabel: String {
        switch status {
        case .readyToLaunch:
            return "QA passed"
        case .blocked:
            return "QA blocked"
        case .overrideRecorded:
            return "QA override"
        }
    }
}

struct CompanyProductQualityPolicy: Codable, Hashable {
    var requiredChecks: Set<CompanyProductQACheckKind>
    var requiredSmokeTests: Set<CompanyProductSmokeTestKind>
    var maxLoadingTimeMS: Int

    static let productionDefault = CompanyProductQualityPolicy(
        requiredChecks: Set(CompanyProductQACheckKind.allCases),
        requiredSmokeTests: Set(CompanyProductSmokeTestKind.allCases),
        maxLoadingTimeMS: 3_000
    )
}

enum CompanyProductQualityGate {
    static func evaluate(
        companyID: String,
        checks: [CompanyProductQACheckResult],
        smokeTests: [CompanyProductSmokeTestResult],
        artifacts: [CompanyProductQAArtifact],
        policy: CompanyProductQualityPolicy = .productionDefault,
        overrideReason: String? = nil
    ) -> CompanyProductQualityReport {
        let checksByKind = Dictionary(uniqueKeysWithValues: checks.map { ($0.kind, $0) })
        let smokeByKind = Dictionary(uniqueKeysWithValues: smokeTests.map { ($0.kind, $0) })
        var tasks: [CompanyProductQualityTask] = []

        for kind in policy.requiredChecks {
            guard let result = checksByKind[kind] else {
                tasks.append(
                    task(companyID: companyID, id: "missing-\(kind.rawValue)", title: "Run \(kind.rawValue) QA")
                )
                continue
            }
            if result.status != .passed {
                tasks.append(
                    task(
                        companyID: companyID,
                        id: result.id,
                        title: "Fix \(kind.rawValue)",
                        detail: result.summary,
                        sourceCheckID: result.id
                    )
                )
            }
        }

        for kind in policy.requiredSmokeTests {
            guard let result = smokeByKind[kind] else {
                tasks.append(
                    task(companyID: companyID, id: "missing-\(kind.rawValue)", title: "Run \(kind.rawValue) smoke test")
                )
                continue
            }
            if result.status != .passed || !result.ranInSandbox {
                tasks.append(
                    task(
                        companyID: companyID,
                        id: result.id,
                        title: "Fix \(kind.rawValue) smoke test",
                        detail: result.ranInSandbox
                            ? result.summary
                            : "Smoke test must run in sandbox before live launch.",
                        sourceCheckID: result.id
                    )
                )
            }
        }

        let override = overrideReason?.trimmingCharacters(in: .whitespacesAndNewlines)
        if tasks.isEmpty {
            return CompanyProductQualityReport(
                companyID: companyID,
                status: .readyToLaunch,
                canLaunch: true,
                checks: checks,
                smokeTests: smokeTests,
                artifacts: artifacts,
                tasks: [],
                overrideReason: nil
            )
        }

        return CompanyProductQualityReport(
            companyID: companyID,
            status: override?.isEmpty == false ? .overrideRecorded : .blocked,
            canLaunch: override?.isEmpty == false,
            checks: checks,
            smokeTests: smokeTests,
            artifacts: artifacts,
            tasks: tasks.sorted { $0.id < $1.id },
            overrideReason: override?.isEmpty == false ? override : nil
        )
    }

    private static func task(
        companyID: String,
        id: String,
        title: String,
        detail: String = "Required before launch.",
        sourceCheckID: String? = nil
    ) -> CompanyProductQualityTask {
        CompanyProductQualityTask(
            id: "qa-\(id)",
            companyID: companyID,
            title: title,
            detail: detail,
            sourceCheckID: sourceCheckID ?? id
        )
    }
}
