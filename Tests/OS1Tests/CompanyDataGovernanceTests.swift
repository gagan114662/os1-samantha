import Foundation
import Testing
@testable import OS1

struct CompanyDataGovernanceTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test
    func recordsRequireRetentionPoliciesAndExposeExpiredRecords() {
        let records = [
            record(
                id: "known",
                retentionPolicyID: "customer-pii-365",
                createdAt: now.addingTimeInterval(-400 * 86_400)
            ),
            record(id: "missing", retentionPolicyID: "unknown-policy", createdAt: now)
        ]

        let report = CompanyDataGovernanceEngine.validate(
            companyID: "company-1",
            records: records,
            deletionWorkflowConfigured: true,
            now: now
        )

        #expect(report.missingRetentionRecordIDs == ["missing"])
        #expect(report.expiredRecordIDs == ["known"])
        #expect(!report.isConfigured)
    }

    @Test
    func customerDeletionDeletesAnonymizesAndAuditsRecords() {
        let records = [
            record(id: "pii", category: .customerPII, retentionPolicyID: "customer-pii-365"),
            record(id: "payment", category: .paymentMetadata, retentionPolicyID: "payment-metadata-1095"),
            record(id: "other-subject", subjectID: "subject-2", retentionPolicyID: "customer-pii-365")
        ]
        let request = CompanyDataDeletionRequest(
            id: "delete-1",
            companyID: "company-1",
            subjectID: "subject-1",
            requestedAt: now,
            requestedBy: "customer",
            status: .requested
        )

        let result = CompanyDataGovernanceEngine.executeDeletion(
            request: request,
            records: records,
            now: now
        )

        #expect(result.request.status == .completed)
        #expect(!result.remainingRecords.contains { $0.id == "pii" })
        #expect(result.remainingRecords.contains { $0.id == "payment" && $0.subjectID == nil })
        #expect(result.remainingRecords.contains { $0.id == "other-subject" })
        #expect(result.auditEvents.contains { $0.kind == .deletionRequested })
        #expect(result.auditEvents.contains { $0.kind == .recordDeleted && $0.recordID == "pii" })
        #expect(result.auditEvents.contains { $0.kind == .recordAnonymized && $0.recordID == "payment" })
    }

    @Test
    func legalHoldBlocksDeletionAndIsAudited() {
        let request = CompanyDataDeletionRequest(
            id: "delete-2",
            companyID: "company-1",
            subjectID: "subject-1",
            requestedAt: now,
            requestedBy: "customer",
            status: .requested
        )
        let result = CompanyDataGovernanceEngine.executeDeletion(
            request: request,
            records: [record(id: "held", legalHold: true)],
            now: now
        )

        #expect(result.request.status == .blockedByLegalHold)
        #expect(result.remainingRecords.contains { $0.id == "held" })
        #expect(result.auditEvents.contains { $0.kind == .legalHoldRetained && $0.recordID == "held" })
    }

    @Test
    func customerExportReturnsOnlyMatchingSubjectAndAudits() {
        let export = CompanyDataGovernanceEngine.exportSubjectData(
            companyID: "company-1",
            subjectID: "subject-1",
            records: [
                record(id: "one"),
                record(id: "two", subjectID: "subject-2"),
                record(id: "three", companyID: "company-2")
            ],
            now: now
        )

        #expect(export.records.map(\.id) == ["one"])
        #expect(export.auditEvent.kind == .exportCreated)
        #expect(export.auditEvent.subjectID == "subject-1")
    }

    @Test
    func sensitivePromptPayloadIsWithheldUnlessExplicitlyAllowed() {
        let blocked = CompanyDataGovernanceEngine.promptPayload(
            text: "Email person@example.com and use ghp_123456789012345678901234567890123456",
            category: .customerPII,
            companyID: "company-1",
            explicitAllowed: false,
            now: now
        )
        let allowed = CompanyDataGovernanceEngine.promptPayload(
            text: "Email person@example.com and use ghp_123456789012345678901234567890123456",
            category: .customerPII,
            companyID: "company-1",
            explicitAllowed: true,
            now: now
        )

        #expect(!blocked.copiedToPrompt)
        #expect(blocked.sanitizedText == "[redacted:customerPII]")
        #expect(blocked.auditEvent?.kind == .promptRedacted)
        #expect(allowed.copiedToPrompt)
        #expect(!allowed.sanitizedText.contains("person@example.com"))
        #expect(!allowed.sanitizedText.contains("ghp_"))
        #expect(allowed.sanitizedText.contains("[redacted]"))
    }

    @Test
    func breachChecklistHasNotificationDeadlineAndAuditEvent() {
        let checklist = CompanyDataGovernanceEngine.breachResponseChecklist(
            companyID: "company-1",
            suspectedAt: now,
            severity: .critical
        )

        #expect(checklist.notificationDeadlineHours == 72)
        #expect(checklist.steps.contains { $0.contains("Pause affected company agents") })
        #expect(checklist.auditEvent.kind == .breachChecklistCreated)
    }

    @Test
    func doctorFlagsMissingDataGovernanceSections() {
        let missing = DoctorViewModel.dataGovernanceMissingSections(in: """
        # OS1 Company Data Governance
        Version: 1
        ## Data Categories
        """)

        #expect(missing.contains("## Retention Policies"))
        #expect(missing.contains("## Customer Deletion Workflow"))
        #expect(missing.contains("## Prompt Redaction Rules"))
        #expect(missing.contains("## Doctor Configuration"))
    }

    @Test
    func dataGovernanceDocumentContainsRequiredSections() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/data-governance.md")
        let document = try String(contentsOf: url, encoding: .utf8)

        let missing = DoctorViewModel.dataGovernanceMissingSections(in: document)

        #expect(missing.isEmpty)
    }

    private func record(
        id: String,
        companyID: String = "company-1",
        subjectID: String? = "subject-1",
        category: CompanyDataCategory = .customerPII,
        retentionPolicyID: String = "customer-pii-365",
        createdAt: Date? = nil,
        legalHold: Bool = false
    ) -> CompanyStoredDataRecord {
        CompanyStoredDataRecord(
            id: id,
            companyID: companyID,
            subjectID: subjectID,
            category: category,
            retentionPolicyID: retentionPolicyID,
            sourcePath: "crm.csv",
            createdAt: createdAt ?? now,
            promptUseAllowed: false,
            legalHold: legalHold,
            summary: "Customer record"
        )
    }
}
