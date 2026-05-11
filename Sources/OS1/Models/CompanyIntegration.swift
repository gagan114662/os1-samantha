import Foundation

enum CompanyIntegrationDomain: String, Codable, CaseIterable, Hashable {
    case email
    case calendar
    case crm
    case payments
    case analytics
    case hosting
    case domains
    case support
    case social
    case video
    case audio
    case affiliate
    case marketplace
}

enum CompanyIntegrationPathKind: String, Codable, CaseIterable, Hashable {
    case officialAPI
    case stableConnector
    case mcpTool
    case browserAutomation
    case manualTask

    var fragility: CompanyIntegrationFragility {
        switch self {
        case .officialAPI:
            return .low
        case .stableConnector:
            return .medium
        case .mcpTool:
            return .medium
        case .browserAutomation:
            return .high
        case .manualTask:
            return .manual
        }
    }
}

enum CompanyIntegrationFragility: String, Codable, Hashable {
    case low
    case medium
    case high
    case manual
}

struct CompanyIntegrationPermission: Codable, Hashable, Identifiable {
    var id: String { scope }
    var scope: String
    var required: Bool
    var granted: Bool
}

struct CompanyIntegrationRateLimit: Codable, Hashable {
    var limit: Int
    var remaining: Int
    var resetAt: Date?

    var isExhausted: Bool {
        remaining <= 0
    }

    var isNearLimit: Bool {
        limit > 0 && Double(max(0, remaining)) / Double(limit) <= 0.1
    }
}

struct CompanyIntegrationPath: Codable, Hashable, Identifiable {
    var id: String
    var kind: CompanyIntegrationPathKind
    var provider: String
    var toolName: String?
    var permissions: [CompanyIntegrationPermission]
    var rateLimit: CompanyIntegrationRateLimit?

    var isAvailable: Bool {
        permissions.allSatisfy { !$0.required || $0.granted } && rateLimit?.isExhausted != true
    }
}

struct CompanyWorkflowIntegrationPlan: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var domain: CompanyIntegrationDomain
    var workflowName: String
    var preferredPaths: [CompanyIntegrationPath]

    var selectedPath: CompanyIntegrationPath? {
        preferredPaths.first(where: \.isAvailable)
    }

    var usesBrowserFallback: Bool {
        selectedPath?.kind == .browserAutomation
    }
}

struct CompanyIntegrationFailure: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case authError
        case rateLimited
        case permissionMissing
        case providerUnavailable
        case browserFallbackRequired
    }

    var id: String
    var companyID: String
    var workflowID: String
    var provider: String
    var kind: Kind
    var occurredAt: Date
    var retryAfter: Date?
    var operatorAction: String
}

struct CompanyIntegrationHealthReport: Codable, Hashable {
    var companyID: String
    var workflowPlans: [CompanyWorkflowIntegrationPlan]
    var failures: [CompanyIntegrationFailure]

    var browserFallbackWorkflowIDs: [String] {
        workflowPlans.filter(\.usesBrowserFallback).map(\.id).sorted()
    }

    var blockedReason: String? {
        if let auth = failures.first(where: { $0.kind == .authError || $0.kind == .permissionMissing }) {
            return auth.operatorAction
        }
        if let unavailable = failures.first(where: { $0.kind == .providerUnavailable }) {
            return unavailable.operatorAction
        }
        return nil
    }

    var hasRateLimitPressure: Bool {
        failures.contains { $0.kind == .rateLimited } ||
            workflowPlans.flatMap(\.preferredPaths).contains { $0.rateLimit?.isNearLimit == true }
    }
}

enum CompanyIntegrationPlanner {
    static let fallbackOrder: [CompanyIntegrationPathKind] = [
        .officialAPI,
        .stableConnector,
        .mcpTool,
        .browserAutomation,
        .manualTask
    ]

    static func plan(
        companyID: String,
        domain: CompanyIntegrationDomain,
        workflowName: String,
        paths: [CompanyIntegrationPath]
    ) -> CompanyWorkflowIntegrationPlan {
        let sorted = paths.sorted { lhs, rhs in
            let lhsIndex = fallbackOrder.firstIndex(of: lhs.kind) ?? fallbackOrder.count
            let rhsIndex = fallbackOrder.firstIndex(of: rhs.kind) ?? fallbackOrder.count
            if lhsIndex == rhsIndex { return lhs.provider < rhs.provider }
            return lhsIndex < rhsIndex
        }
        return CompanyWorkflowIntegrationPlan(
            id: "\(companyID)-\(domain.rawValue)-\(workflowName.slugifiedForIntegrationID())",
            companyID: companyID,
            domain: domain,
            workflowName: workflowName,
            preferredPaths: sorted
        )
    }

    static func healthReport(
        companyID: String,
        workflowPlans: [CompanyWorkflowIntegrationPlan],
        failures: [CompanyIntegrationFailure] = []
    ) -> CompanyIntegrationHealthReport {
        var derivedFailures = failures
        for plan in workflowPlans where plan.selectedPath == nil {
            derivedFailures.append(
                CompanyIntegrationFailure(
                    id: "\(plan.id)-blocked",
                    companyID: companyID,
                    workflowID: plan.id,
                    provider: "integration-planner",
                    kind: .permissionMissing,
                    occurredAt: Date(timeIntervalSince1970: 0),
                    retryAfter: nil,
                    operatorAction: "Connect or authorize \(plan.domain.rawValue) for \(plan.workflowName)."
                )
            )
        }
        for plan in workflowPlans where plan.usesBrowserFallback {
            derivedFailures.append(
                CompanyIntegrationFailure(
                    id: "\(plan.id)-browser-fallback",
                    companyID: companyID,
                    workflowID: plan.id,
                    provider: plan.selectedPath?.provider ?? "browser",
                    kind: .browserFallbackRequired,
                    occurredAt: Date(timeIntervalSince1970: 0),
                    retryAfter: nil,
                    operatorAction: "Replace browser automation with API or stable connector for \(plan.workflowName)."
                )
            )
        }
        return CompanyIntegrationHealthReport(
            companyID: companyID,
            workflowPlans: workflowPlans,
            failures: derivedFailures.sorted { $0.id < $1.id }
        )
    }

    static func defaultWorkflowInventory(companyID: String) -> [CompanyWorkflowIntegrationPlan] {
        CompanyIntegrationDomain.allCases.map { domain in
            plan(
                companyID: companyID,
                domain: domain,
                workflowName: "\(domain.rawValue) workflow",
                paths: [
                    CompanyIntegrationPath(
                        id: "\(domain.rawValue)-api",
                        kind: .officialAPI,
                        provider: domain.rawValue,
                        toolName: nil,
                        permissions: [],
                        rateLimit: nil
                    ),
                    CompanyIntegrationPath(
                        id: "\(domain.rawValue)-browser",
                        kind: .browserAutomation,
                        provider: "browser",
                        toolName: nil,
                        permissions: [],
                        rateLimit: nil
                    )
                ]
            )
        }
    }
}

private extension String {
    func slugifiedForIntegrationID() -> String {
        lowercased()
            .map { char in char.isLetter || char.isNumber ? char : "-" }
            .reduce(into: "") { result, char in
                if char == "-", result.last == "-" { return }
                result.append(char)
            }
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }
}
