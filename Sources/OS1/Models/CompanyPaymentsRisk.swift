import Foundation

struct CompanyPaymentAccount: Codable, Hashable {
    enum Provider: String, Codable, CaseIterable, Hashable {
        case stripe
        case paypal
        case manualInvoice
    }

    enum Mode: String, Codable, CaseIterable, Hashable {
        case sandbox
        case live
    }

    enum KYCStatus: String, Codable, CaseIterable, Hashable {
        case notStarted
        case pending
        case actionRequired
        case verified
        case rejected
    }

    var companyID: String
    var provider: Provider
    var mode: Mode
    var chargesEnabled: Bool
    var payoutsEnabled: Bool
    var kycStatus: KYCStatus
    var requirementsDue: [String]
    var payoutHoldReasons: [String]
    var liveBillingRequested: Bool
    var sandboxTests: [CompanyPaymentSandboxTest]
}

struct CompanyPaymentSandboxTest: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case checkout
        case webhook
        case refund
        case dispute
    }

    var id: String
    var kind: Kind
    var passed: Bool
    var evidence: String
}

struct CompanyPaymentTransaction: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case charge
        case refund
        case failedPayment
        case chargeback
    }

    enum ProductRisk: String, Codable, CaseIterable, Hashable {
        case low
        case medium
        case high
        case prohibited
    }

    var id: String
    var companyID: String
    var customerID: String?
    var occurredAt: Date
    var kind: Kind
    var amountUSD: Double
    var currency: String
    var country: String?
    var paymentInstrumentCountry: String?
    var productRisk: ProductRisk
    var metadataFlags: [String]
    var providerReference: String
}

struct CompanyPaymentDispute: Codable, Hashable, Identifiable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case needsResponse
        case underReview
        case won
        case lost
    }

    var id: String
    var companyID: String
    var transactionID: String
    var amountUSD: Double
    var reason: String
    var status: Status
    var responseDueAt: Date?
    var providerReference: String
}

struct CompanyPaymentFraudSignal: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case velocity
        case countryMismatch
        case repeatedRefunds
        case suspiciousMetadata
        case highRiskProduct
    }

    enum Severity: String, Codable, CaseIterable, Hashable {
        case medium
        case high
        case critical
    }

    var id: String
    var kind: Kind
    var severity: Severity
    var evidence: String
    var transactionIDs: [String]
}

struct CompanyPaymentSupportTask: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case disputeResponse
        case chargebackReview
        case payoutHoldReview
        case kycFollowUp
    }

    enum Priority: String, Codable, CaseIterable, Hashable {
        case normal
        case high
        case urgent
    }

    var id: String
    var companyID: String
    var kind: Kind
    var priority: Priority
    var title: String
    var dueAt: Date?
    var evidence: String
}

struct CompanyPaymentsRiskPolicy: Codable, Hashable {
    var maxChargesPerHour: Int
    var maxRefundsPerCustomer: Int
    var maxOpenDisputesBeforePause: Int
    var requiredSandboxTests: Set<CompanyPaymentSandboxTest.Kind>

    static let productionDefault = CompanyPaymentsRiskPolicy(
        maxChargesPerHour: 12,
        maxRefundsPerCustomer: 2,
        maxOpenDisputesBeforePause: 1,
        requiredSandboxTests: [.checkout, .webhook, .refund, .dispute]
    )
}

struct CompanyPaymentsRiskReport: Codable, Hashable {
    enum AccountHealth: String, Codable, CaseIterable, Hashable {
        case healthy
        case setupIncomplete
        case kycActionRequired
        case payoutRestricted
        case riskReview
    }

    var companyID: String
    var accountHealth: AccountHealth
    var canEnableLiveBilling: Bool
    var shouldPauseCompany: Bool
    var blockers: [String]
    var fraudSignals: [CompanyPaymentFraudSignal]
    var supportTasks: [CompanyPaymentSupportTask]
    var approvalRequests: [CompanyApprovalRequest]
    var ledgerAdjustments: [CompanyLedgerEntry]
}

enum CompanyPaymentsRiskEngine {
    static func evaluate(
        account: CompanyPaymentAccount,
        transactions: [CompanyPaymentTransaction],
        disputes: [CompanyPaymentDispute],
        policy: CompanyPaymentsRiskPolicy = .productionDefault,
        now: Date = Date()
    ) -> CompanyPaymentsRiskReport {
        let blockers = accountBlockers(account: account, policy: policy)
        let fraudSignals = fraudSignals(transactions: transactions, policy: policy, now: now)
        let supportTasks = supportTasks(account: account, disputes: disputes, transactions: transactions)
        let approvalRequests = approvalRequests(account: account, disputes: disputes, transactions: transactions)
        let openDisputes = disputes.filter { $0.status == .needsResponse || $0.status == .underReview }

        let shouldPause = !blockers.isEmpty && account.mode == .live ||
            openDisputes.count > policy.maxOpenDisputesBeforePause ||
            fraudSignals.contains { $0.severity == .critical }

        return CompanyPaymentsRiskReport(
            companyID: account.companyID,
            accountHealth: accountHealth(account: account, blockers: blockers, fraudSignals: fraudSignals),
            canEnableLiveBilling: blockers.isEmpty && fraudSignals.allSatisfy { $0.severity != .critical },
            shouldPauseCompany: shouldPause,
            blockers: blockers,
            fraudSignals: fraudSignals,
            supportTasks: supportTasks,
            approvalRequests: approvalRequests,
            ledgerAdjustments: ledgerAdjustments(transactions: transactions, disputes: disputes)
        )
    }

    private static func accountBlockers(
        account: CompanyPaymentAccount,
        policy: CompanyPaymentsRiskPolicy
    ) -> [String] {
        var blockers: [String] = []
        if account.liveBillingRequested {
            let passedTests = Set(account.sandboxTests.filter(\.passed).map(\.kind))
            let missingTests = policy.requiredSandboxTests.subtracting(passedTests)
            if !missingTests.isEmpty {
                blockers.append("missingSandboxTests:\(missingTests.map(\.rawValue).sorted().joined(separator: ","))")
            }
        }
        if !account.chargesEnabled {
            blockers.append("chargesDisabled")
        }
        if !account.payoutsEnabled || !account.payoutHoldReasons.isEmpty {
            blockers.append("payoutRestricted")
        }
        if account.kycStatus != .verified {
            blockers.append("kyc:\(account.kycStatus.rawValue)")
        }
        if !account.requirementsDue.isEmpty {
            blockers.append("requirementsDue:\(account.requirementsDue.sorted().joined(separator: ","))")
        }
        return blockers
    }

    private static func accountHealth(
        account: CompanyPaymentAccount,
        blockers: [String],
        fraudSignals: [CompanyPaymentFraudSignal]
    ) -> CompanyPaymentsRiskReport.AccountHealth {
        if fraudSignals.contains(where: { $0.severity == .critical || $0.severity == .high }) {
            return .riskReview
        }
        if account.kycStatus == .actionRequired || account.kycStatus == .rejected {
            return .kycActionRequired
        }
        if !account.payoutsEnabled || !account.payoutHoldReasons.isEmpty {
            return .payoutRestricted
        }
        return blockers.isEmpty ? .healthy : .setupIncomplete
    }

    private static func fraudSignals(
        transactions: [CompanyPaymentTransaction],
        policy: CompanyPaymentsRiskPolicy,
        now: Date
    ) -> [CompanyPaymentFraudSignal] {
        var signals: [CompanyPaymentFraudSignal] = []
        let recentCharges = transactions.filter {
            $0.kind == .charge && now.timeIntervalSince($0.occurredAt) <= 3_600
        }
        if recentCharges.count > policy.maxChargesPerHour {
            signals.append(.init(
                id: "velocity",
                kind: .velocity,
                severity: .high,
                evidence: "\(recentCharges.count) charges in the last hour",
                transactionIDs: recentCharges.map(\.id)
            ))
        }

        let countryMismatches = transactions.filter {
            guard let customerCountry = $0.country,
                  let instrumentCountry = $0.paymentInstrumentCountry
            else { return false }
            return customerCountry.caseInsensitiveCompare(instrumentCountry) != .orderedSame
        }
        if !countryMismatches.isEmpty {
            signals.append(.init(
                id: "countryMismatch",
                kind: .countryMismatch,
                severity: .medium,
                evidence: "Customer country differs from payment instrument country",
                transactionIDs: countryMismatches.map(\.id)
            ))
        }

        let refundsByCustomer = Dictionary(grouping: transactions.filter { $0.kind == .refund }) {
            $0.customerID ?? "unknown"
        }
        let repeatedRefundIDs = refundsByCustomer.values
            .filter { $0.count > policy.maxRefundsPerCustomer }
            .flatMap { $0.map(\.id) }
        if !repeatedRefundIDs.isEmpty {
            signals.append(.init(
                id: "repeatedRefunds",
                kind: .repeatedRefunds,
                severity: .high,
                evidence: "Customer refund count exceeded policy threshold",
                transactionIDs: repeatedRefundIDs
            ))
        }

        let suspiciousMetadata = transactions.filter { !$0.metadataFlags.isEmpty }
        if !suspiciousMetadata.isEmpty {
            signals.append(.init(
                id: "suspiciousMetadata",
                kind: .suspiciousMetadata,
                severity: .high,
                evidence: suspiciousMetadata.flatMap(\.metadataFlags).sorted().joined(separator: ","),
                transactionIDs: suspiciousMetadata.map(\.id)
            ))
        }

        let highRiskProducts = transactions.filter { $0.productRisk == .high || $0.productRisk == .prohibited }
        if !highRiskProducts.isEmpty {
            let hasProhibitedProduct = highRiskProducts.contains { $0.productRisk == .prohibited }
            let severity: CompanyPaymentFraudSignal.Severity = hasProhibitedProduct
                ? .critical
                : .high
            signals.append(.init(
                id: "highRiskProduct",
                kind: .highRiskProduct,
                severity: severity,
                evidence: "High-risk or prohibited product sold through payment flow",
                transactionIDs: highRiskProducts.map(\.id)
            ))
        }
        return signals
    }

    private static func supportTasks(
        account: CompanyPaymentAccount,
        disputes: [CompanyPaymentDispute],
        transactions: [CompanyPaymentTransaction]
    ) -> [CompanyPaymentSupportTask] {
        var tasks = disputes
            .filter { $0.status == .needsResponse || $0.status == .underReview }
            .map {
                CompanyPaymentSupportTask(
                    id: "dispute-\($0.id)",
                    companyID: $0.companyID,
                    kind: .disputeResponse,
                    priority: .urgent,
                    title: "Respond to payment dispute \($0.providerReference)",
                    dueAt: $0.responseDueAt,
                    evidence: "reason=\($0.reason) amountUSD=\($0.amountUSD)"
                )
            }

        tasks += transactions
            .filter { $0.kind == .chargeback }
            .map {
                CompanyPaymentSupportTask(
                    id: "chargeback-\($0.id)",
                    companyID: $0.companyID,
                    kind: .chargebackReview,
                    priority: .urgent,
                    title: "Review chargeback \($0.providerReference)",
                    dueAt: nil,
                    evidence: "amountUSD=\($0.amountUSD)"
                )
            }

        if !account.payoutsEnabled || !account.payoutHoldReasons.isEmpty {
            tasks.append(.init(
                id: "payout-hold-\(account.companyID)",
                companyID: account.companyID,
                kind: .payoutHoldReview,
                priority: .high,
                title: "Resolve payment payout hold",
                dueAt: nil,
                evidence: account.payoutHoldReasons.joined(separator: ",")
            ))
        }
        if account.kycStatus == .actionRequired || account.kycStatus == .rejected {
            tasks.append(.init(
                id: "kyc-\(account.companyID)",
                companyID: account.companyID,
                kind: .kycFollowUp,
                priority: .high,
                title: "Resolve payment KYC requirement",
                dueAt: nil,
                evidence: account.requirementsDue.joined(separator: ",")
            ))
        }
        return tasks
    }

    private static func approvalRequests(
        account: CompanyPaymentAccount,
        disputes: [CompanyPaymentDispute],
        transactions: [CompanyPaymentTransaction]
    ) -> [CompanyApprovalRequest] {
        var requests: [CompanyApprovalRequest] = []
        if account.liveBillingRequested {
            requests.append(.init(
                id: "payments-live-\(account.companyID)",
                companyID: account.companyID,
                actor: "payments-risk-engine",
                riskTier: .high,
                proposedAction: "Enable live billing for \(account.provider.rawValue)",
                expectedEffect: "Customers can be charged real money.",
                rollbackPlan: "Disable live payment links and return to sandbox mode."
            ))
        }

        requests += disputes
            .filter { $0.status == .needsResponse }
            .map {
                CompanyApprovalRequest(
                    id: "dispute-response-\($0.id)",
                    companyID: $0.companyID,
                    actor: "payments-risk-engine",
                    riskTier: .high,
                    proposedAction: "Submit dispute response for \($0.providerReference)",
                    expectedEffect: "Payment provider receives irreversible evidence package.",
                    estimatedCostUSD: $0.amountUSD,
                    destinationAccount: $0.providerReference,
                    rollbackPlan: "Do not submit; refund or concede dispute after human review."
                )
            }

        requests += transactions
            .filter { $0.kind == .refund || $0.kind == .chargeback }
            .map {
                CompanyApprovalRequest(
                    id: "payment-action-\($0.id)",
                    companyID: $0.companyID,
                    actor: "payments-risk-engine",
                    riskTier: .high,
                    proposedAction: "Review irreversible payment action \($0.kind.rawValue)",
                    expectedEffect: "Money movement or provider dispute state may change.",
                    estimatedCostUSD: $0.amountUSD,
                    destinationAccount: $0.providerReference,
                    rollbackPlan: "Hold action until owner approval or customer-support escalation."
                )
            }
        return requests
    }

    private static func ledgerAdjustments(
        transactions: [CompanyPaymentTransaction],
        disputes: [CompanyPaymentDispute]
    ) -> [CompanyLedgerEntry] {
        let transactionEntries = transactions.compactMap { transaction -> CompanyLedgerEntry? in
            switch transaction.kind {
            case .charge:
                return ledgerEntry(transaction: transaction, kind: .revenue, category: .sales)
            case .refund:
                return ledgerEntry(transaction: transaction, kind: .refund, category: .refund)
            case .chargeback:
                return ledgerEntry(transaction: transaction, kind: .refund, category: .refund)
            case .failedPayment:
                return nil
            }
        }
        let lostDisputes = disputes.filter { $0.status == .lost }.map {
            CompanyLedgerEntry(
                id: "dispute-loss-\($0.id)",
                companyID: $0.companyID,
                occurredAt: nil,
                kind: .refund,
                category: .refund,
                amountUSD: $0.amountUSD,
                source: "payments",
                sourceReference: $0.providerReference,
                confidence: .verified,
                note: "dispute lost id=\($0.id)"
            )
        }
        return transactionEntries + lostDisputes
    }

    private static func ledgerEntry(
        transaction: CompanyPaymentTransaction,
        kind: CompanyLedgerEntry.Kind,
        category: CompanyLedgerEntry.Category
    ) -> CompanyLedgerEntry {
        CompanyLedgerEntry(
            id: "payment-\(transaction.id)",
            companyID: transaction.companyID,
            occurredAt: transaction.occurredAt,
            kind: kind,
            category: category,
            amountUSD: transaction.amountUSD,
            source: "payments",
            sourceReference: transaction.providerReference,
            confidence: .verified,
            note: "\(transaction.kind.rawValue) id=\(transaction.id)"
        )
    }
}
