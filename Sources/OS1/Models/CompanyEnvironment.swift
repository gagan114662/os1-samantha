import Foundation

enum CompanyEnvironmentMode: String, Codable, CaseIterable, Hashable {
    case dev
    case sandbox
    case staging
    case production

    var isProductionLike: Bool {
        self == .production
    }

    var banner: String {
        switch self {
        case .dev:
            return "DEV - local only, no customer-visible side effects."
        case .sandbox:
            return "SANDBOX - test resources only, no live customer-visible side effects."
        case .staging:
            return "STAGING - production-shaped test resources; approval required before public side effects."
        case .production:
            return "LIVE PRODUCTION - real customers, real money, real reputation risk."
        }
    }
}

enum CompanySideEffect: String, Codable, CaseIterable, Hashable {
    case localFileWrite
    case networkRead
    case sandboxPayment
    case sandboxOutboundDraft
    case ciEvaluation
    case stagingDeployment
    case productionCredentialRead
    case livePayment
    case liveOutboundSend
    case productionDeployment
    case publicContentPublish
}

struct CompanyEnvironmentResource: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, Hashable {
        case credential
        case paymentProvider
        case domain
        case database
        case browserSession
        case outboundChannel
    }

    var id: String
    var kind: Kind
    var name: String
    var environment: CompanyEnvironmentMode
    var reference: String
}

struct CompanyEnvironmentState: Codable, Hashable {
    var mode: CompanyEnvironmentMode
    var allowedSideEffects: Set<CompanySideEffect>
    var resources: [CompanyEnvironmentResource]
    var allowProductionCredentialsOutsideProduction: Bool
    var migrationSourceCompanyID: String?

    init(
        mode: CompanyEnvironmentMode,
        allowedSideEffects: Set<CompanySideEffect>? = nil,
        resources: [CompanyEnvironmentResource] = [],
        allowProductionCredentialsOutsideProduction: Bool = false,
        migrationSourceCompanyID: String? = nil
    ) {
        self.mode = mode
        self.allowedSideEffects = allowedSideEffects ?? Self.defaultSideEffects(for: mode)
        self.resources = resources
        self.allowProductionCredentialsOutsideProduction = allowProductionCredentialsOutsideProduction
        self.migrationSourceCompanyID = migrationSourceCompanyID
    }

    static let sandbox = CompanyEnvironmentState(mode: .sandbox)

    var banner: String {
        mode.banner
    }

    static func defaultSideEffects(for mode: CompanyEnvironmentMode) -> Set<CompanySideEffect> {
        switch mode {
        case .dev:
            return [.localFileWrite, .networkRead, .ciEvaluation]
        case .sandbox:
            return [.localFileWrite, .networkRead, .sandboxPayment, .sandboxOutboundDraft, .ciEvaluation]
        case .staging:
            return [.localFileWrite, .networkRead, .sandboxPayment, .sandboxOutboundDraft, .stagingDeployment]
        case .production:
            return [
                .localFileWrite, .networkRead, .productionCredentialRead, .livePayment, .liveOutboundSend,
                .productionDeployment, .publicContentPublish
            ]
        }
    }
}

struct CompanyEnvironmentDecision: Codable, Hashable {
    var allowed: Bool
    var requiresApproval: Bool
    var banner: String
    var reasons: [String]
}

enum CompanyEnvironmentGuard {
    static func evaluate(
        state: CompanyEnvironmentState,
        requestedSideEffects: Set<CompanySideEffect>,
        approvalRecorded: Bool = false,
        workflowKind: String? = nil
    ) -> CompanyEnvironmentDecision {
        var reasons: [String] = []
        let disallowed = requestedSideEffects.subtracting(state.allowedSideEffects)
        if !disallowed.isEmpty {
            reasons.append("sideEffectNotAllowed:\(disallowed.map(\.rawValue).sorted().joined(separator: "|"))")
        }
        if workflowKind == "ci" || workflowKind == "eval" {
            let allowedForCI: Set<CompanyEnvironmentMode> = [.dev, .sandbox]
            if !allowedForCI.contains(state.mode) {
                reasons.append("ciEvalMustUseDevOrSandbox")
            }
        }

        let liveEffects: Set<CompanySideEffect> = [
            .livePayment, .liveOutboundSend, .productionDeployment, .publicContentPublish, .productionCredentialRead
        ]
        let touchesLiveProduction = !requestedSideEffects.intersection(liveEffects).isEmpty || state.mode == .production
        let requiresApproval = touchesLiveProduction && !approvalRecorded
        if requiresApproval {
            reasons.append("liveProductionApprovalRequired")
        }

        return CompanyEnvironmentDecision(
            allowed: reasons.isEmpty,
            requiresApproval: requiresApproval,
            banner: state.banner,
            reasons: reasons
        )
    }

    static func filteredCredentials(
        _ credentials: [String: String],
        state: CompanyEnvironmentState
    ) -> (credentials: [String: String], blockedNames: [String]) {
        guard !state.mode.isProductionLike,
              !state.allowProductionCredentialsOutsideProduction
        else { return (credentials, []) }

        var allowed: [String: String] = [:]
        var blocked: [String] = []
        for (name, value) in credentials {
            if looksProductionCredential(name: name, value: value) {
                blocked.append(name)
            } else {
                allowed[name] = value
            }
        }
        return (allowed, blocked.sorted())
    }

    static func migrationPlan(
        sandboxCompanyID: String,
        productionCompanyID: String,
        productionResources: [CompanyEnvironmentResource]
    ) -> CompanyEnvironmentState {
        CompanyEnvironmentState(
            mode: .production,
            resources: productionResources,
            migrationSourceCompanyID: sandboxCompanyID == productionCompanyID ? nil : sandboxCompanyID
        )
    }

    private static func looksProductionCredential(name: String, value: String) -> Bool {
        let combined = "\(name) \(value)".lowercased()
        let productionMarkers = [
            "live", "prod", "production", "sk_live", "pk_live", "rk_live", "whsec_live"
        ]
        let testMarkers = ["test", "sandbox", "dev", "staging", "sk_test", "pk_test"]
        if testMarkers.contains(where: { combined.contains($0) }) {
            return false
        }
        return productionMarkers.contains { combined.contains($0) }
    }
}
