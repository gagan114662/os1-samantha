import Foundation
import CryptoKit
import Testing
@testable import OS1

struct CompanyStateBackupTests {
    @Test
    func backupManifestIncludesStableChecksumsAndSortedEntries() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-backup-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let sessions = root.appendingPathComponent("sessions.json")
        let events = root.appendingPathComponent("events.jsonl")
        try #"[]"#.write(to: sessions, atomically: true, encoding: .utf8)
        try #"{"kind":"companyCreated"}"#.write(to: events, atomically: true, encoding: .utf8)

        let manifest = try CompanyStateBackupBuilder.makeManifest(
            backupID: "backup-test",
            sourceRoot: root,
            candidates: [
                .init(sourceURL: events, relativePath: "events.jsonl", kind: .events),
                .init(sourceURL: sessions, relativePath: "sessions.json", kind: .sessions)
            ],
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        #expect(manifest.schemaVersion == 1)
        #expect(manifest.backupID == "backup-test")
        #expect(manifest.entries.map(\.relativePath) == ["events.jsonl", "sessions.json"])
        #expect(manifest.entries.allSatisfy { $0.sha256.count == 64 })
        #expect(manifest.secretsPolicy.contains("Secrets are excluded"))
        #expect(manifest.encryption.contains("AES-GCM"))
        #expect(manifest.recoveryPointObjectiveHours == 24)
        #expect(manifest.recoveryTimeObjectiveHours == 4)
    }

    @Test
    func backupManifestSkipsMissingCandidates() throws {
        let root = FileManager.default.temporaryDirectory
        let manifest = try CompanyStateBackupBuilder.makeManifest(
            backupID: "backup-empty",
            sourceRoot: root,
            candidates: [
                .init(
                    sourceURL: root.appendingPathComponent("missing.json"),
                    relativePath: "missing.json",
                    kind: .sessions
                )
            ]
        )

        #expect(manifest.entries.isEmpty)
    }

    @Test
    func manifestIntegrityDetectsTamperedBackupFiles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-backup-integrity-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ledger = root.appendingPathComponent("LEDGER.json")
        try #"[]"#.write(to: ledger, atomically: true, encoding: .utf8)
        let manifest = try CompanyStateBackupBuilder.makeManifest(
            backupID: "backup-integrity",
            sourceRoot: root,
            candidates: [.init(sourceURL: ledger, relativePath: "sessions/co/LEDGER.json", kind: .ledger)]
        )

        let backupRoot = root.appendingPathComponent("backup", isDirectory: true)
        let destination = backupRoot.appendingPathComponent("sessions/co/LEDGER.json")
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.copyItem(at: ledger, to: destination)

        let passing = CompanyStateBackupBuilder.verifyManifest(manifest, backupRoot: backupRoot)
        try #"[{"tampered":true}]"#.write(to: destination, atomically: true, encoding: .utf8)
        let failing = CompanyStateBackupBuilder.verifyManifest(manifest, backupRoot: backupRoot)

        #expect(passing.isPassing)
        #expect(!failing.isPassing)
        #expect(failing.checksumMismatches == ["sessions/co/LEDGER.json"])
    }

    @Test
    func encryptedBackupCanRestoreCleanMachineState() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-encrypted-backup-\(UUID().uuidString)", isDirectory: true)
        let restoreRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-restore-drill-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: restoreRoot)
        }

        let sessions = root.appendingPathComponent("sessions.json")
        let ledger = root.appendingPathComponent("sessions/co/LEDGER.json")
        try FileManager.default.createDirectory(
            at: ledger.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try #"[]"#.write(to: sessions, atomically: true, encoding: .utf8)
        try #"[{"kind":"revenue","amountUSD":25}]"#.write(to: ledger, atomically: true, encoding: .utf8)

        let key = SymmetricKey(size: .bits256)
        let backup = try CompanyStateBackupBuilder.makeEncryptedBackup(
            backupID: "backup-encrypted",
            sourceRoot: root,
            candidates: [
                .init(sourceURL: sessions, relativePath: "sessions.json", kind: .sessions),
                .init(sourceURL: ledger, relativePath: "sessions/co/LEDGER.json", kind: .ledger)
            ],
            key: key,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let drill = try CompanyStateBackupBuilder.restoreEncryptedBackup(
            backup,
            key: key,
            destinationRoot: restoreRoot,
            drilledAt: Date(timeIntervalSince1970: 1_700_000_100)
        )

        let restoredLedger = try String(
            contentsOf: restoreRoot.appendingPathComponent("sessions/co/LEDGER.json"),
            encoding: .utf8
        )
        #expect(backup.entries.allSatisfy { !$0.sealedBase64.contains("revenue") })
        #expect(drill.status == .passed)
        #expect(drill.restoredEntryCount == 2)
        #expect(drill.recoveryPointObjectiveHours == 24)
        #expect(drill.recoveryTimeObjectiveHours == 4)
        #expect(restoredLedger.contains("amountUSD"))
    }

    @Test
    func doctorFlagsStaleFailingAndMissingBackupState() throws {
        let now = Date(timeIntervalSince1970: 1_700_100_000)
        let fresh = CompanyStateBackupManifest(
            createdAt: now.addingTimeInterval(-3_600),
            backupID: "fresh",
            sourceRoot: "/tmp/os1",
            entries: []
        )
        let stale = CompanyStateBackupManifest(
            createdAt: now.addingTimeInterval(-90_000),
            backupID: "stale",
            sourceRoot: "/tmp/os1",
            recoveryPointObjectiveHours: 12,
            entries: []
        )
        let failingIntegrity = CompanyBackupIntegrityReport(
            status: .failed,
            checkedAt: now,
            verifiedEntryCount: 0,
            missingPaths: ["sessions.json"],
            checksumMismatches: ["events.jsonl"]
        )

        #expect(DoctorViewModel.stateBackupProblems(latestManifest: nil, integrityReport: nil, now: now).count == 1)
        #expect(DoctorViewModel.stateBackupProblems(
            latestManifest: fresh,
            integrityReport: CompanyBackupIntegrityReport(
                status: .passed,
                checkedAt: now,
                verifiedEntryCount: 0,
                missingPaths: [],
                checksumMismatches: []
            ),
            now: now
        ).isEmpty)
        #expect(DoctorViewModel.stateBackupProblems(latestManifest: stale, integrityReport: nil, now: now)
            .contains { $0.contains("RPO") })
        #expect(DoctorViewModel.stateBackupProblems(
            latestManifest: fresh,
            integrityReport: failingIntegrity,
            now: now
        ).contains { $0.contains("Checksum mismatches") })
    }
}
