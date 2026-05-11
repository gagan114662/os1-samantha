import Foundation

enum CompanyDataCategory: String, Codable, CaseIterable, Hashable {
    case credentials
    case customerPII
    case paymentMetadata
    case sensitiveHealth
    case sensitiveFinancial
    case logs
    case screenshots
    case prompts
    case generatedContent
    case operational

    var isSensitive: Bool {
        switch self {
        case .credentials, .customerPII, .paymentMetadata, .sensitiveHealth, .sensitiveFinancial:
            return true
        case .logs, .screenshots, .prompts, .generatedContent, .operational:
            return false
        }
    }
}

struct CompanyRetentionPolicy: Codable, Hashable, Identifiable {
    enum DisposalAction: String, Codable, CaseIterable, Hashable {
        case delete
        case anonymize
        case archive
    }

    var id: String
    var category: CompanyDataCategory
    var retainForDays: Int
    var disposalAction: DisposalAction
    var legalHoldAllowed: Bool
    var reason: String

    static let productionDefaults: [CompanyRetentionPolicy] = [
        .init(
            id: "credentials-rotate",
            category: .credentials,
            retainForDays: 0,
            disposalAction: .delete,
            legalHoldAllowed: false,
            reason: "Credentials should live in keychain or provider vaults, not company records."
        ),
        .init(
            id: "customer-pii-365",
            category: .customerPII,
            retainForDays: 365,
            disposalAction: .delete,
            legalHoldAllowed: true,
            reason: "Customer PII is retained only while needed for service, support, and legal obligations."
        ),
        .init(
            id: "payment-metadata-1095",
            category: .paymentMetadata,
            retainForDays: 1_095,
            disposalAction: .anonymize,
            legalHoldAllowed: true,
            reason: "Payment references support reconciliation, disputes, taxes, and fraud review."
        ),
        .init(
            id: "sensitive-health-30",
            category: .sensitiveHealth,
            retainForDays: 30,
            disposalAction: .delete,
            legalHoldAllowed: true,
            reason: "Health-like data is minimized unless a reviewed business explicitly requires it."
        ),
        .init(
            id: "sensitive-financial-365",
            category: .sensitiveFinancial,
            retainForDays: 365,
            disposalAction: .delete,
            legalHoldAllowed: true,
            reason: "Financial data is retained for customer support and account reconciliation."
        ),
        .init(
            id: "logs-30",
            category: .logs,
            retainForDays: 30,
            disposalAction: .delete,
            legalHoldAllowed: false,
            reason: "Logs are short-lived operational diagnostics."
        ),
        .init(
            id: "screenshots-14",
            category: .screenshots,
            retainForDays: 14,
            disposalAction: .delete,
            legalHoldAllowed: false,
            reason: "Screenshots can contain incidental PII and should expire quickly."
        ),
        .init(
            id: "prompts-30",
            category: .prompts,
            retainForDays: 30,
            disposalAction: .delete,
            legalHoldAllowed: false,
            reason: "Prompts may contain user data and should be minimized."
        ),
        .init(
            id: "generated-content-730",
            category: .generatedContent,
            retainForDays: 730,
            disposalAction: .archive,
            legalHoldAllowed: true,
            reason: "Published or shippable content may need audit history."
        ),
        .init(
            id: "operational-365",
            category: .operational,
            retainForDays: 365,
            disposalAction: .archive,
            legalHoldAllowed: true,
            reason: "Operational state supports company continuity and incident review."
        ),
    ]
}

struct CompanyStoredDataRecord: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var subjectID: String?
    var category: CompanyDataCategory
    var retentionPolicyID: String
    var sourcePath: String
    var createdAt: Date
    var promptUseAllowed: Bool
    var legalHold: Bool
    var summary: String
}

struct CompanyDataDeletionRequest: Codable, Hashable, Identifiable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case requested
        case completed
        case blockedByLegalHold
    }

    var id: String
    var companyID: String
    var subjectID: String
    var requestedAt: Date
    var requestedBy: String
    var status: Status
}

struct CompanyDataGovernanceAuditEvent: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case deletionRequested
        case recordDeleted
        case recordAnonymized
        case legalHoldRetained
        case exportCreated
        case promptRedacted
        case breachChecklistCreated
    }

    var id: String
    var companyID: String
    var occurredAt: Date
    var kind: Kind
    var recordID: String?
    var subjectID: String?
    var summary: String
}

struct CompanyDataSubjectExport: Codable, Hashable {
    var companyID: String
    var subjectID: String
    var generatedAt: Date
    var records: [CompanyStoredDataRecord]
    var auditEvent: CompanyDataGovernanceAuditEvent
}

struct CompanyDataDeletionResult: Codable, Hashable {
    var request: CompanyDataDeletionRequest
    var remainingRecords: [CompanyStoredDataRecord]
    var auditEvents: [CompanyDataGovernanceAuditEvent]
}

struct CompanyPromptPayload: Codable, Hashable {
    var category: CompanyDataCategory
    var explicitAllowanceRequired: Bool
    var copiedToPrompt: Bool
    var sanitizedText: String
    var auditEvent: CompanyDataGovernanceAuditEvent?
}

struct CompanyBreachResponseChecklist: Codable, Hashable {
    var companyID: String
    var suspectedAt: Date
    var severity: CompanyApprovalRequest.RiskTier
    var steps: [String]
    var notificationDeadlineHours: Int
    var auditEvent: CompanyDataGovernanceAuditEvent
}

struct CompanyDataGovernanceReport: Codable, Hashable {
    var companyID: String
    var missingRetentionRecordIDs: [String]
    var expiredRecordIDs: [String]
    var missingCategoryCount: Int
    var deletionWorkflowConfigured: Bool

    var isConfigured: Bool {
        missingRetentionRecordIDs.isEmpty && missingCategoryCount == 0 && deletionWorkflowConfigured
    }
}

enum CompanyDataGovernanceEngine {
    static func validate(
        companyID: String,
        records: [CompanyStoredDataRecord],
        policies: [CompanyRetentionPolicy] = CompanyRetentionPolicy.productionDefaults,
        deletionWorkflowConfigured: Bool,
        now: Date = Date()
    ) -> CompanyDataGovernanceReport {
        let policyIDs = Set(policies.map(\.id))
        let missingRetention = records
            .filter { !policyIDs.contains($0.retentionPolicyID) }
            .map(\.id)
            .sorted()
        let expired = records
            .filter { record in
                guard let policy = policies.first(where: { $0.id == record.retentionPolicyID }) else {
                    return false
                }
                return expirationDate(for: record, policy: policy) <= now && !record.legalHold
            }
            .map(\.id)
            .sorted()

        return CompanyDataGovernanceReport(
            companyID: companyID,
            missingRetentionRecordIDs: missingRetention,
            expiredRecordIDs: expired,
            missingCategoryCount: 0,
            deletionWorkflowConfigured: deletionWorkflowConfigured
        )
    }

    static func exportSubjectData(
        companyID: String,
        subjectID: String,
        records: [CompanyStoredDataRecord],
        now: Date = Date()
    ) -> CompanyDataSubjectExport {
        let matching = records
            .filter { $0.companyID == companyID && $0.subjectID == subjectID }
            .sorted { $0.id < $1.id }
        let event = CompanyDataGovernanceAuditEvent(
            id: "export-\(companyID)-\(subjectID)-\(Int(now.timeIntervalSince1970))",
            companyID: companyID,
            occurredAt: now,
            kind: .exportCreated,
            recordID: nil,
            subjectID: subjectID,
            summary: "Exported \(matching.count) data record(s)."
        )
        return CompanyDataSubjectExport(
            companyID: companyID,
            subjectID: subjectID,
            generatedAt: now,
            records: matching,
            auditEvent: event
        )
    }

    static func executeDeletion(
        request: CompanyDataDeletionRequest,
        records: [CompanyStoredDataRecord],
        policies: [CompanyRetentionPolicy] = CompanyRetentionPolicy.productionDefaults,
        now: Date = Date()
    ) -> CompanyDataDeletionResult {
        var remaining: [CompanyStoredDataRecord] = []
        var events: [CompanyDataGovernanceAuditEvent] = [
            audit(
                companyID: request.companyID,
                occurredAt: now,
                kind: .deletionRequested,
                subjectID: request.subjectID,
                summary: "Customer deletion request received from \(request.requestedBy)."
            )
        ]
        var retainedByHold = false

        for record in records {
            guard record.companyID == request.companyID, record.subjectID == request.subjectID else {
                remaining.append(record)
                continue
            }
            guard let policy = policies.first(where: { $0.id == record.retentionPolicyID }) else {
                remaining.append(record)
                retainedByHold = true
                events.append(audit(
                    companyID: request.companyID,
                    occurredAt: now,
                    kind: .legalHoldRetained,
                    recordID: record.id,
                    subjectID: request.subjectID,
                    summary: "Record retained because no matching retention policy exists."
                ))
                continue
            }
            if record.legalHold && policy.legalHoldAllowed {
                remaining.append(record)
                retainedByHold = true
                events.append(audit(
                    companyID: request.companyID,
                    occurredAt: now,
                    kind: .legalHoldRetained,
                    recordID: record.id,
                    subjectID: request.subjectID,
                    summary: "Record retained under legal hold."
                ))
                continue
            }
            if policy.disposalAction == .anonymize {
                var anonymized = record
                anonymized.subjectID = nil
                anonymized.summary = "[anonymized]"
                remaining.append(anonymized)
                events.append(audit(
                    companyID: request.companyID,
                    occurredAt: now,
                    kind: .recordAnonymized,
                    recordID: record.id,
                    subjectID: request.subjectID,
                    summary: "Record anonymized under \(policy.id)."
                ))
            } else {
                events.append(audit(
                    companyID: request.companyID,
                    occurredAt: now,
                    kind: .recordDeleted,
                    recordID: record.id,
                    subjectID: request.subjectID,
                    summary: "Record deleted under \(policy.id)."
                ))
            }
        }

        var completed = request
        completed.status = retainedByHold ? .blockedByLegalHold : .completed
        return CompanyDataDeletionResult(
            request: completed,
            remainingRecords: remaining,
            auditEvents: events
        )
    }

    static func promptPayload(
        text: String,
        category: CompanyDataCategory,
        companyID: String = "unknown",
        explicitAllowed: Bool,
        now: Date = Date()
    ) -> CompanyPromptPayload {
        if category.isSensitive && !explicitAllowed {
            let event = audit(
                companyID: companyID,
                occurredAt: now,
                kind: .promptRedacted,
                summary: "Sensitive \(category.rawValue) was withheld from model prompt."
            )
            return CompanyPromptPayload(
                category: category,
                explicitAllowanceRequired: true,
                copiedToPrompt: false,
                sanitizedText: "[redacted:\(category.rawValue)]",
                auditEvent: event
            )
        }

        let redacted = redactPII(CompanyEvent.redact(text))
        let event = redacted == text ? nil : audit(
            companyID: companyID,
            occurredAt: now,
            kind: .promptRedacted,
            summary: "Prompt payload was redacted before model use."
        )
        return CompanyPromptPayload(
            category: category,
            explicitAllowanceRequired: category.isSensitive,
            copiedToPrompt: true,
            sanitizedText: redacted,
            auditEvent: event
        )
    }

    static func breachResponseChecklist(
        companyID: String,
        suspectedAt: Date = Date(),
        severity: CompanyApprovalRequest.RiskTier
    ) -> CompanyBreachResponseChecklist {
        let steps = [
            "Pause affected company agents and revoke unnecessary credentials.",
            "Identify categories, subjects, systems, and time window involved.",
            "Preserve audit logs and evidence without copying secrets into prompts.",
            "Notify owner, payment providers, platforms, and counsel when applicable.",
            "Prepare customer/regulator notice if legal thresholds are met.",
            "Record corrective actions and prevention follow-up before resuming."
        ]
        return CompanyBreachResponseChecklist(
            companyID: companyID,
            suspectedAt: suspectedAt,
            severity: severity,
            steps: steps,
            notificationDeadlineHours: 72,
            auditEvent: audit(
                companyID: companyID,
                occurredAt: suspectedAt,
                kind: .breachChecklistCreated,
                summary: "Breach response checklist created."
            )
        )
    }

    private static func expirationDate(
        for record: CompanyStoredDataRecord,
        policy: CompanyRetentionPolicy
    ) -> Date {
        record.createdAt.addingTimeInterval(TimeInterval(policy.retainForDays) * 86_400)
    }

    private static func redactPII(_ value: String) -> String {
        var sanitized = value
        let patterns = [
            #"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#,
            #"\b\d{3}-\d{2}-\d{4}\b"#,
            #"\b(?:\+?1[-.\s]?)?\(?\d{3}\)?[-.\s]?\d{3}[-.\s]?\d{4}\b"#,
            #"\b(?:\d[ -]*?){13,16}\b"#
        ]
        for pattern in patterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: [.regularExpression, .caseInsensitive]
            )
        }
        return sanitized
    }

    private static func audit(
        companyID: String,
        occurredAt: Date,
        kind: CompanyDataGovernanceAuditEvent.Kind,
        recordID: String? = nil,
        subjectID: String? = nil,
        summary: String
    ) -> CompanyDataGovernanceAuditEvent {
        CompanyDataGovernanceAuditEvent(
            id: "\(kind.rawValue)-\(recordID ?? subjectID ?? companyID)-\(Int(occurredAt.timeIntervalSince1970))",
            companyID: companyID,
            occurredAt: occurredAt,
            kind: kind,
            recordID: recordID,
            subjectID: subjectID,
            summary: CompanyEvent.redact(summary)
        )
    }
}
