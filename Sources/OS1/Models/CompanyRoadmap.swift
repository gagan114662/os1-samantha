import Foundation

enum CompanyRoadmapPhase: String, Codable, CaseIterable, Hashable {
    case productionFoundation
    case companyFactory
    case fleetScale
    case revenueOperations
    case productionHardening
}

struct CompanyRoadmapIssue: Codable, Hashable, Identifiable {
    enum Status: String, Codable, Hashable {
        case planned
        case inReview
        case active
    }

    var id: Int { number }
    var number: Int
    var title: String
    var phase: CompanyRoadmapPhase
    var status: Status
    var requiredForFirstDollar: Bool
    var requiredForHundredCompanies: Bool
}

struct CompanyProductionMilestoneEvidence: Codable, Hashable {
    var fullEventTrace: Bool
    var boundedSpend: Bool
    var scopedCredentials: Bool
    var humanApprovalForHighRiskActions: Bool
    var profitLossAttribution: Bool
    var killPauseControls: Bool
    var reproducibleRunHistory: Bool
    var schedulerActive: Bool
    var budgetGuardianActive: Bool
    var eventLogActive: Bool
    var approvalConsoleActive: Bool
    var lifecycleGatesActive: Bool
    var complianceLayerActive: Bool
}

struct CompanyRoadmapMilestoneStatus: Codable, Hashable {
    enum Milestone: String, Codable, Hashable {
        case firstVerifiedDollar
        case hundredCompanyScale
    }

    var milestone: Milestone
    var isReady: Bool
    var missingControls: [String]
}

struct CompanyRoadmapReadiness: Codable, Hashable {
    var issues: [CompanyRoadmapIssue]
    var firstDollar: CompanyRoadmapMilestoneStatus
    var hundredCompanyScale: CompanyRoadmapMilestoneStatus

    var canScaleToHundreds: Bool {
        firstDollar.isReady && hundredCompanyScale.isReady
    }
}

enum CompanyRoadmapEngine {
    static let productionIssues: [CompanyRoadmapIssue] = [
        issue(13, "Approval console", .productionFoundation, firstDollar: true, hundred: true),
        issue(15, "Compliance and policy layer", .productionFoundation, firstDollar: true, hundred: true),
        issue(16, "Evaluation harness", .productionFoundation, firstDollar: true, hundred: true),
        issue(17, "Browser automation reliability", .fleetScale, firstDollar: false, hundred: true),
        issue(18, "Production deployment", .productionFoundation, firstDollar: true, hundred: true),
        issue(20, "Legal foundation", .productionFoundation, firstDollar: true, hundred: true),
        issue(21, "Customer support operations", .revenueOperations, firstDollar: true, hundred: true),
        issue(22, "Customer identity and CRM", .revenueOperations, firstDollar: true, hundred: true),
        issue(23, "Payments risk", .revenueOperations, firstDollar: true, hundred: true),
        issue(24, "Data governance", .productionHardening, firstDollar: true, hundred: true),
        issue(25, "Prompt-injection defense", .productionHardening, firstDollar: true, hundred: true),
        issue(26, "Model/provider resilience", .fleetScale, firstDollar: false, hundred: true),
        issue(27, "Experiment statistics", .revenueOperations, firstDollar: false, hundred: true),
        issue(28, "Portfolio strategy", .fleetScale, firstDollar: false, hundred: true),
        issue(29, "Reputation management", .revenueOperations, firstDollar: true, hundred: true),
        issue(30, "Incident response", .productionHardening, firstDollar: true, hundred: true),
        issue(31, "Procurement controls", .productionHardening, firstDollar: true, hundred: true),
        issue(32, "Abuse containment", .productionHardening, firstDollar: true, hundred: true),
        issue(33, "Business model playbooks", .companyFactory, firstDollar: false, hundred: true),
        issue(34, "Unit economics", .revenueOperations, firstDollar: true, hundred: true),
        issue(35, "Bookkeeping export", .revenueOperations, firstDollar: true, hundred: true),
        issue(36, "Environment separation", .productionHardening, firstDollar: true, hundred: true),
        issue(37, "Backup and disaster recovery", .productionHardening, firstDollar: true, hundred: true),
        issue(38, "Schema migrations", .productionHardening, firstDollar: true, hundred: true),
        issue(39, "API-first integrations", .productionHardening, firstDollar: false, hundred: true),
        issue(40, "Content claims review", .revenueOperations, firstDollar: true, hundred: true),
        issue(41, "Product quality gates", .revenueOperations, firstDollar: true, hundred: true),
        issue(42, "Role-based permissions", .productionHardening, firstDollar: true, hundred: true),
        issue(43, "Internal governance", .productionHardening, firstDollar: true, hundred: true)
    ]

    static func readiness(
        evidence: CompanyProductionMilestoneEvidence,
        issueStatuses: [Int: CompanyRoadmapIssue.Status] = [:]
    ) -> CompanyRoadmapReadiness {
        let issues = productionIssues.map { issue in
            var updated = issue
            updated.status = issueStatuses[issue.number] ?? issue.status
            return updated
        }
        return CompanyRoadmapReadiness(
            issues: issues,
            firstDollar: firstDollarStatus(evidence: evidence, issues: issues),
            hundredCompanyScale: scaleStatus(evidence: evidence, issues: issues)
        )
    }

    static func openRequiredIssues(
        for milestone: CompanyRoadmapMilestoneStatus.Milestone,
        issues: [CompanyRoadmapIssue]
    ) -> [CompanyRoadmapIssue] {
        issues.filter { issue in
            let required = milestone == .firstVerifiedDollar
                ? issue.requiredForFirstDollar
                : issue.requiredForHundredCompanies
            return required && issue.status != .active
        }
    }

    private static func firstDollarStatus(
        evidence: CompanyProductionMilestoneEvidence,
        issues: [CompanyRoadmapIssue]
    ) -> CompanyRoadmapMilestoneStatus {
        var missing = missingIssueLabels(for: .firstVerifiedDollar, issues: issues)
        appendMissing(!evidence.fullEventTrace, "full event trace", to: &missing)
        appendMissing(!evidence.boundedSpend, "bounded spend", to: &missing)
        appendMissing(!evidence.scopedCredentials, "scoped credentials", to: &missing)
        appendMissing(!evidence.humanApprovalForHighRiskActions, "high-risk approval", to: &missing)
        appendMissing(!evidence.profitLossAttribution, "profit/loss attribution", to: &missing)
        appendMissing(!evidence.killPauseControls, "kill/pause controls", to: &missing)
        appendMissing(!evidence.reproducibleRunHistory, "reproducible run history", to: &missing)
        return CompanyRoadmapMilestoneStatus(
            milestone: .firstVerifiedDollar,
            isReady: missing.isEmpty,
            missingControls: missing
        )
    }

    private static func scaleStatus(
        evidence: CompanyProductionMilestoneEvidence,
        issues: [CompanyRoadmapIssue]
    ) -> CompanyRoadmapMilestoneStatus {
        var missing = missingIssueLabels(for: .hundredCompanyScale, issues: issues)
        appendMissing(!evidence.schedulerActive, "scheduler", to: &missing)
        appendMissing(!evidence.budgetGuardianActive, "budget guardian", to: &missing)
        appendMissing(!evidence.eventLogActive, "event log", to: &missing)
        appendMissing(!evidence.approvalConsoleActive, "approval console", to: &missing)
        appendMissing(!evidence.lifecycleGatesActive, "lifecycle gates", to: &missing)
        appendMissing(!evidence.complianceLayerActive, "compliance layer", to: &missing)
        return CompanyRoadmapMilestoneStatus(
            milestone: .hundredCompanyScale,
            isReady: missing.isEmpty,
            missingControls: missing
        )
    }

    private static func missingIssueLabels(
        for milestone: CompanyRoadmapMilestoneStatus.Milestone,
        issues: [CompanyRoadmapIssue]
    ) -> [String] {
        openRequiredIssues(for: milestone, issues: issues).map { "#\($0.number) \($0.title)" }
    }

    private static func appendMissing(_ condition: Bool, _ label: String, to missing: inout [String]) {
        if condition { missing.append(label) }
    }

    private static func issue(
        _ number: Int,
        _ title: String,
        _ phase: CompanyRoadmapPhase,
        firstDollar: Bool,
        hundred: Bool
    ) -> CompanyRoadmapIssue {
        CompanyRoadmapIssue(
            number: number,
            title: title,
            phase: phase,
            status: .planned,
            requiredForFirstDollar: firstDollar,
            requiredForHundredCompanies: hundred
        )
    }
}
