import Foundation
import CryptoKit

struct CompanyStateBackupManifest: Codable, Hashable {
    struct Entry: Codable, Hashable, Identifiable {
        enum Kind: String, Codable, CaseIterable, Hashable {
            case sessions
            case events
            case lessons
            case journal
            case audit
            case revenue
            case ledger
            case approval
            case log
        }

        var id: String { relativePath }
        let relativePath: String
        let kind: Kind
        let sizeBytes: Int
        let sha256: String
    }

    let schemaVersion: Int
    let createdAt: Date
    let backupID: String
    let sourceRoot: String
    let recoveryPointObjectiveHours: Int
    let recoveryTimeObjectiveHours: Int
    let backupFrequencyHours: Int
    let retentionDays: Int
    let storageLocation: String
    let restorePermissions: [String]
    let encryption: String
    let secretsPolicy: String
    let entries: [Entry]

    init(
        schemaVersion: Int = 1,
        createdAt: Date = Date(),
        backupID: String,
        sourceRoot: String,
        recoveryPointObjectiveHours: Int = 24,
        recoveryTimeObjectiveHours: Int = 4,
        backupFrequencyHours: Int = 24,
        retentionDays: Int = 30,
        storageLocation: String = "~/.os1/codex-tasks/backups",
        restorePermissions: [String] = ["local OS1 operator"],
        encryption: String = "AES-GCM envelope; secrets excluded",
        secretsPolicy: String = "Secrets are excluded; restore requires Keychain/credential reauthorization.",
        entries: [Entry]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.backupID = backupID
        self.sourceRoot = sourceRoot
        self.recoveryPointObjectiveHours = recoveryPointObjectiveHours
        self.recoveryTimeObjectiveHours = recoveryTimeObjectiveHours
        self.backupFrequencyHours = backupFrequencyHours
        self.retentionDays = retentionDays
        self.storageLocation = storageLocation
        self.restorePermissions = restorePermissions
        self.encryption = encryption
        self.secretsPolicy = secretsPolicy
        self.entries = entries.sorted { $0.relativePath < $1.relativePath }
    }
}

struct CompanyBackupIntegrityReport: Codable, Hashable {
    enum Status: String, Codable, Hashable {
        case passed
        case failed
    }

    var status: Status
    var checkedAt: Date
    var verifiedEntryCount: Int
    var missingPaths: [String]
    var checksumMismatches: [String]

    var isPassing: Bool {
        status == .passed
    }
}

struct CompanyEncryptedBackupEntry: Codable, Hashable, Identifiable {
    var id: String { relativePath }
    let relativePath: String
    let kind: CompanyStateBackupManifest.Entry.Kind
    let sealedBase64: String
}

struct CompanyEncryptedStateBackup: Codable, Hashable {
    let manifest: CompanyStateBackupManifest
    let algorithm: String
    let entries: [CompanyEncryptedBackupEntry]
}

struct CompanyRestoreDrillReport: Codable, Hashable {
    enum Status: String, Codable, Hashable {
        case passed
        case failed
    }

    var status: Status
    var drilledAt: Date
    var backupID: String
    var restoredEntryCount: Int
    var recoveryPointObjectiveHours: Int
    var recoveryTimeObjectiveHours: Int
    var integrity: CompanyBackupIntegrityReport
    var restoreRoot: String
    var notes: [String]
}

enum CompanyStateBackupBuilder {
    struct Candidate: Hashable {
        let sourceURL: URL
        let relativePath: String
        let kind: CompanyStateBackupManifest.Entry.Kind
    }

    static func makeManifest(
        backupID: String,
        sourceRoot: URL,
        candidates: [Candidate],
        createdAt: Date = Date()
    ) throws -> CompanyStateBackupManifest {
        let entries = try candidates.compactMap { candidate -> CompanyStateBackupManifest.Entry? in
            guard FileManager.default.fileExists(atPath: candidate.sourceURL.path) else { return nil }
            let data = try Data(contentsOf: candidate.sourceURL)
            return CompanyStateBackupManifest.Entry(
                relativePath: candidate.relativePath,
                kind: candidate.kind,
                sizeBytes: data.count,
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            )
        }
        return CompanyStateBackupManifest(
            createdAt: createdAt,
            backupID: backupID,
            sourceRoot: sourceRoot.path,
            entries: entries
        )
    }

    static func makeEncryptedBackup(
        backupID: String,
        sourceRoot: URL,
        candidates: [Candidate],
        key: SymmetricKey,
        createdAt: Date = Date()
    ) throws -> CompanyEncryptedStateBackup {
        let manifest = try makeManifest(
            backupID: backupID,
            sourceRoot: sourceRoot,
            candidates: candidates,
            createdAt: createdAt
        )
        let entries = try candidates.compactMap { candidate -> CompanyEncryptedBackupEntry? in
            guard FileManager.default.fileExists(atPath: candidate.sourceURL.path) else { return nil }
            let data = try Data(contentsOf: candidate.sourceURL)
            let sealed = try AES.GCM.seal(data, using: key)
            guard let combined = sealed.combined else { return nil }
            return CompanyEncryptedBackupEntry(
                relativePath: candidate.relativePath,
                kind: candidate.kind,
                sealedBase64: combined.base64EncodedString()
            )
        }.sorted { $0.relativePath < $1.relativePath }
        return CompanyEncryptedStateBackup(
            manifest: manifest,
            algorithm: "AES-GCM",
            entries: entries
        )
    }

    static func verifyManifest(
        _ manifest: CompanyStateBackupManifest,
        backupRoot: URL,
        checkedAt: Date = Date()
    ) -> CompanyBackupIntegrityReport {
        var verified = 0
        var missing: [String] = []
        var mismatches: [String] = []

        for entry in manifest.entries {
            let url = backupRoot.appendingPathComponent(entry.relativePath)
            guard let data = try? Data(contentsOf: url) else {
                missing.append(entry.relativePath)
                continue
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if digest == entry.sha256 {
                verified += 1
            } else {
                mismatches.append(entry.relativePath)
            }
        }

        return CompanyBackupIntegrityReport(
            status: missing.isEmpty && mismatches.isEmpty ? .passed : .failed,
            checkedAt: checkedAt,
            verifiedEntryCount: verified,
            missingPaths: missing.sorted(),
            checksumMismatches: mismatches.sorted()
        )
    }

    static func verifyEncryptedBackup(
        _ backup: CompanyEncryptedStateBackup,
        key: SymmetricKey,
        checkedAt: Date = Date()
    ) -> CompanyBackupIntegrityReport {
        let encryptedByPath = Dictionary(uniqueKeysWithValues: backup.entries.map { ($0.relativePath, $0) })
        var verified = 0
        var missing: [String] = []
        var mismatches: [String] = []

        for entry in backup.manifest.entries {
            guard let encrypted = encryptedByPath[entry.relativePath],
                  let sealedData = Data(base64Encoded: encrypted.sealedBase64),
                  let box = try? AES.GCM.SealedBox(combined: sealedData),
                  let data = try? AES.GCM.open(box, using: key) else {
                missing.append(entry.relativePath)
                continue
            }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if digest == entry.sha256 {
                verified += 1
            } else {
                mismatches.append(entry.relativePath)
            }
        }

        return CompanyBackupIntegrityReport(
            status: missing.isEmpty && mismatches.isEmpty ? .passed : .failed,
            checkedAt: checkedAt,
            verifiedEntryCount: verified,
            missingPaths: missing.sorted(),
            checksumMismatches: mismatches.sorted()
        )
    }

    static func restoreEncryptedBackup(
        _ backup: CompanyEncryptedStateBackup,
        key: SymmetricKey,
        destinationRoot: URL,
        drilledAt: Date = Date()
    ) throws -> CompanyRestoreDrillReport {
        let integrity = verifyEncryptedBackup(backup, key: key, checkedAt: drilledAt)
        guard integrity.isPassing else {
            return CompanyRestoreDrillReport(
                status: .failed,
                drilledAt: drilledAt,
                backupID: backup.manifest.backupID,
                restoredEntryCount: 0,
                recoveryPointObjectiveHours: backup.manifest.recoveryPointObjectiveHours,
                recoveryTimeObjectiveHours: backup.manifest.recoveryTimeObjectiveHours,
                integrity: integrity,
                restoreRoot: destinationRoot.path,
                notes: ["Integrity failed; restore blocked before writing files."]
            )
        }

        let encryptedByPath = Dictionary(uniqueKeysWithValues: backup.entries.map { ($0.relativePath, $0) })
        var restored = 0
        for entry in backup.manifest.entries {
            guard let encrypted = encryptedByPath[entry.relativePath],
                  let sealedData = Data(base64Encoded: encrypted.sealedBase64) else { continue }
            let box = try AES.GCM.SealedBox(combined: sealedData)
            let data = try AES.GCM.open(box, using: key)
            let destination = destinationRoot.appendingPathComponent(entry.relativePath)
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: destination, options: [.atomic])
            restored += 1
        }

        return CompanyRestoreDrillReport(
            status: .passed,
            drilledAt: drilledAt,
            backupID: backup.manifest.backupID,
            restoredEntryCount: restored,
            recoveryPointObjectiveHours: backup.manifest.recoveryPointObjectiveHours,
            recoveryTimeObjectiveHours: backup.manifest.recoveryTimeObjectiveHours,
            integrity: integrity,
            restoreRoot: destinationRoot.path,
            notes: ["Clean-machine restore drill completed without secrets."]
        )
    }
}
