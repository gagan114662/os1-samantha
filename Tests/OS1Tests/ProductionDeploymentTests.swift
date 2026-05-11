import CryptoKit
import Foundation
import Testing
@testable import OS1

struct ProductionDeploymentTests {
    @Test
    func updatePlannerRequiresMatchingChannelNotarizationChecksumAndSchema() {
        let stable = release(build: 12, channel: .stable, notarized: true)
        let beta = release(build: 13, channel: .beta, notarized: true)
        let unsigned = release(build: 14, channel: .stable, notarized: false)
        let badChecksum = release(build: 15, channel: .stable, notarized: true, sha256: "bad")
        let schemaBlocked = release(build: 16, channel: .stable, notarized: true, minimumSchemaVersion: 3)

        #expect(decisionStatus(channel: .nightly, available: [stable]) == .channelMismatch)
        #expect(decisionStatus(channel: .stable, available: [unsigned]) == .invalidManifest)
        #expect(decisionStatus(channel: .stable, available: [badChecksum]) == .invalidManifest)
        #expect(decisionStatus(channel: .stable, available: [schemaBlocked]) == .blockedBySchema)

        let decision = OS1UpdatePlanner.decide(
            currentVersion: "1.0.0",
            currentBuild: 10,
            currentSchemaVersion: 1,
            channel: .stable,
            available: [beta, stable]
        )

        #expect(decision.status == .updateAvailable)
        #expect(decision.target?.build == 12)
        #expect(decision.canInstall)
    }

    @Test
    func encryptedBackupEnvelopeRoundTripsWithoutPlaintext() throws {
        let key = SymmetricKey(size: .bits256)
        let plaintext = Data(#"{"companyID":"company","ledger":[{"amountUSD":10}]}"#.utf8)

        let envelope = try OS1EncryptedBackupEnvelope.seal(
            plaintext: plaintext,
            key: key,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )

        #expect(envelope.algorithm == "AES.GCM.256")
        #expect(!envelope.sealedBoxBase64.contains("companyID"))
        #expect(try envelope.open(key: key) == plaintext)
    }

    @Test
    func releaseChecklistBlocksUntilSigningBackupRollbackAndSmokePass() {
        let migration = OS1SchemaMigrationPlan(
            id: "schema-1-2",
            fromVersion: 1,
            toVersion: 2,
            forwardSteps: ["add column"],
            rollbackSteps: ["drop column"],
            destructive: false
        )
        var checklist = OS1ReleaseChecklist(
            signedWithDeveloperID: false,
            notarized: false,
            stapled: false,
            reproducibleArchiveChecksum: nil,
            updateManifestPresent: false,
            encryptedBackupCreated: false,
            rollbackPlanPresent: false,
            smokeTestsPassed: false,
            migrationPlan: migration
        )

        #expect(!checklist.canRelease)
        #expect(checklist.blockers.contains("Developer ID signing is required."))
        #expect(checklist.blockers.contains("Encrypted state backup is required."))

        checklist = OS1ReleaseChecklist(
            signedWithDeveloperID: true,
            notarized: true,
            stapled: true,
            reproducibleArchiveChecksum: String(repeating: "a", count: 64),
            updateManifestPresent: true,
            encryptedBackupCreated: true,
            rollbackPlanPresent: true,
            smokeTestsPassed: true,
            migrationPlan: migration
        )

        #expect(checklist.canRelease)
        #expect(checklist.blockers.isEmpty)
    }

    @Test
    func rollbackRequiresAppStateMigrationAndDaemonSnapshots() {
        let reversible = OS1SchemaMigrationPlan(
            id: "schema-1-2",
            fromVersion: 1,
            toVersion: 2,
            forwardSteps: ["create backup", "migrate"],
            rollbackSteps: ["restore backup"],
            destructive: false
        )
        let destructive = OS1SchemaMigrationPlan(
            id: "schema-2-3",
            fromVersion: 2,
            toVersion: 3,
            forwardSteps: ["drop data"],
            rollbackSteps: [],
            destructive: true
        )

        let good = OS1RollbackPlan(
            appBundleBackupPath: "dist/rollback/OS1-1.0.app",
            encryptedStateBackupID: "backup-1",
            previousVersion: "1.0.0",
            migrationPlan: reversible,
            daemonSnapshots: ["launchd/os1.plist"]
        )
        let bad = OS1RollbackPlan(
            appBundleBackupPath: "dist/rollback/OS1-1.0.app",
            encryptedStateBackupID: "backup-1",
            previousVersion: "1.0.0",
            migrationPlan: destructive,
            daemonSnapshots: []
        )

        #expect(good.canRollback)
        #expect(!bad.canRollback)
    }

    private func release(
        build: Int,
        channel: OS1UpdateChannel,
        notarized: Bool,
        sha256: String = String(repeating: "f", count: 64),
        minimumSchemaVersion: Int = 1
    ) -> OS1ReleaseManifest {
        OS1ReleaseManifest(
            id: "os1-\(build)",
            version: "1.0.\(build)",
            build: build,
            channel: channel,
            minimumSchemaVersion: minimumSchemaVersion,
            downloadURL: URL(string: "https://example.com/os1-\(build).zip")!,
            sha256: sha256,
            notarized: notarized,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000)
        )
    }

    private func decisionStatus(
        channel: OS1UpdateChannel,
        available: [OS1ReleaseManifest]
    ) -> OS1UpdateDecision.Status {
        OS1UpdatePlanner.decide(
            currentVersion: "1.0.0",
            currentBuild: 10,
            currentSchemaVersion: 1,
            channel: channel,
            available: available
        ).status
    }
}
