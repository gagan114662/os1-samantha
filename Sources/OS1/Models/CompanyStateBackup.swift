import Foundation
import CryptoKit
import Security

struct CompanyStateBackupManifest: Codable, Hashable, Sendable {
    struct Entry: Codable, Hashable, Identifiable, Sendable {
        enum Kind: String, Codable, CaseIterable, Hashable, Sendable {
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

struct CompanyBackupIntegrityReport: Codable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
        case passed
        case failed
    }

    var status: Status
    var checkedAt: Date
    var verifiedEntryCount: Int
    var missingPaths: [String]
    var checksumMismatches: [String]
    var manifestHashMismatch: String? = nil

    var isPassing: Bool {
        status == .passed && manifestHashMismatch == nil
    }
}

struct CompanyBackupEncryptionKeyDescriptor: Codable, Hashable, Sendable {
    enum Kind: String, Codable, Hashable, Sendable {
        case operatorSupplied
        case keychainManaged
    }

    let kind: Kind
    let identifier: String
    let keychainService: String?
    let keychainAccount: String?

    static func operatorSupplied(identifier: String = "operator-supplied") -> Self {
        Self(kind: .operatorSupplied, identifier: identifier, keychainService: nil, keychainAccount: nil)
    }

    static func keychainManaged(
        service: String = CompanyStateBackupKeychainStore.defaultService,
        account: String = CompanyStateBackupKeychainStore.defaultAccount
    ) -> Self {
        Self(
            kind: .keychainManaged,
            identifier: "\(service):\(account)",
            keychainService: service,
            keychainAccount: account
        )
    }
}

struct CompanyEncryptedBackupEntry: Codable, Hashable, Identifiable, Sendable {
    var id: String { relativePath }
    let relativePath: String
    let kind: CompanyStateBackupManifest.Entry.Kind
    let sealedBase64: String
}

struct CompanyEncryptedStateBackup: Codable, Hashable, Sendable {
    let manifest: CompanyStateBackupManifest
    let manifestSHA256: String
    let algorithm: String
    let keyDescriptor: CompanyBackupEncryptionKeyDescriptor
    let entries: [CompanyEncryptedBackupEntry]
}

enum CompanyStateBackupRestoreError: LocalizedError, Hashable, Sendable {
    case manifestHashMismatch(expected: String, actual: String)
    case integrityCheckFailed(backupID: String, missingPaths: [String], checksumMismatches: [String])
    case invalidRelativePath(String)

    var code: String {
        switch self {
        case .manifestHashMismatch: "manifest_hash_mismatch"
        case .integrityCheckFailed: "backup_integrity_check_failed"
        case .invalidRelativePath: "invalid_backup_relative_path"
        }
    }

    var errorDescription: String? {
        switch self {
        case .manifestHashMismatch(let expected, let actual):
            return "Backup manifest hash mismatch (expected \(expected), actual \(actual))."
        case .integrityCheckFailed(let backupID, let missingPaths, let checksumMismatches):
            let missing = missingPaths.isEmpty ? "none" : missingPaths.joined(separator: ", ")
            let mismatches = checksumMismatches.isEmpty ? "none" : checksumMismatches.joined(separator: ", ")
            return "Backup \(backupID) failed integrity checks. Missing: \(missing). Mismatches: \(mismatches)."
        case .invalidRelativePath(let path):
            return "Backup entry has an unsafe relative path: \(path)."
        }
    }
}

enum CompanyStateBackupCodec {
    static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    static func manifestHash(_ manifest: CompanyStateBackupManifest) throws -> String {
        try sha256Hex(encoder().encode(manifest))
    }

    static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum CompanyStateBackupKeyMaterial {
    static func operatorSupplied(_ secret: String) -> SymmetricKey {
        if let decoded = Data(base64Encoded: secret), decoded.count == 32 {
            return SymmetricKey(data: decoded)
        }
        return SymmetricKey(data: Data(SHA256.hash(data: Data(secret.utf8))))
    }
}

enum CompanyStateBackupKeychainStore {
    enum StoreError: LocalizedError {
        case saveFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Couldn't save the OS1 backup encryption key to Keychain (status \(status))."
            }
        }
    }

    static let defaultService = "ai.os1.state-backup-key"
    static let defaultAccount = "default"

    static func loadOrCreateKey(service: String = defaultService, account: String = defaultAccount) throws -> SymmetricKey {
        if let stored = KeychainSecret.read(service: service, account: account),
           let data = Data(base64Encoded: stored),
           data.count == 32 {
            return SymmetricKey(data: data)
        }
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = bytes.withUnsafeMutableBytes { rawBuffer in
            SecRandomCopyBytes(kSecRandomDefault, bytes.count, rawBuffer.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed with status \(status)")
        let data = Data(bytes)
        try saveKeyData(data, service: service, account: account)
        return SymmetricKey(data: data)
    }

    private static func saveKeyData(_ data: Data, service: String, account: String) throws {
        let payload = Data(data.base64EncodedString().utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [kSecValueData as String: payload]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = payload
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw StoreError.saveFailed(addStatus) }
        default:
            throw StoreError.saveFailed(updateStatus)
        }
    }
}

struct CompanyRestoreDrillReport: Codable, Hashable, Sendable {
    enum Status: String, Codable, Hashable, Sendable {
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
    struct Candidate: Hashable, Sendable {
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
        keyDescriptor: CompanyBackupEncryptionKeyDescriptor = .operatorSupplied(),
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
            manifestSHA256: try CompanyStateBackupCodec.manifestHash(manifest),
            algorithm: "AES-GCM",
            keyDescriptor: keyDescriptor,
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
            checksumMismatches: mismatches.sorted(),
            manifestHashMismatch: nil
        )
    }

    static func verifyEncryptedBackup(
        _ backup: CompanyEncryptedStateBackup,
        key: SymmetricKey,
        checkedAt: Date = Date()
    ) -> CompanyBackupIntegrityReport {
        if let mismatch = manifestHashMismatch(in: backup) {
            return CompanyBackupIntegrityReport(
                status: .failed,
                checkedAt: checkedAt,
                verifiedEntryCount: 0,
                missingPaths: [],
                checksumMismatches: [],
                manifestHashMismatch: mismatch
            )
        }
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
            checksumMismatches: mismatches.sorted(),
            manifestHashMismatch: nil
        )
    }

    static func manifestHashMismatch(in backup: CompanyEncryptedStateBackup) -> String? {
        guard let actual = try? CompanyStateBackupCodec.manifestHash(backup.manifest),
              actual != backup.manifestSHA256 else { return nil }
        return "expected \(backup.manifestSHA256), actual \(actual)"
    }

    static func validateEncryptedBackupBundle(_ backup: CompanyEncryptedStateBackup) throws {
        if let actual = try? CompanyStateBackupCodec.manifestHash(backup.manifest),
           actual != backup.manifestSHA256 {
            throw CompanyStateBackupRestoreError.manifestHashMismatch(
                expected: backup.manifestSHA256,
                actual: actual
            )
        }
    }

    static func restoreEncryptedBackup(
        _ backup: CompanyEncryptedStateBackup,
        key: SymmetricKey,
        destinationRoot: URL,
        drilledAt: Date = Date()
    ) throws -> CompanyRestoreDrillReport {
        try validateEncryptedBackupBundle(backup)
        let integrity = verifyEncryptedBackup(backup, key: key, checkedAt: drilledAt)
        guard integrity.isPassing else {
            throw CompanyStateBackupRestoreError.integrityCheckFailed(
                backupID: backup.manifest.backupID,
                missingPaths: integrity.missingPaths,
                checksumMismatches: integrity.checksumMismatches
            )
        }

        let encryptedByPath = Dictionary(uniqueKeysWithValues: backup.entries.map { ($0.relativePath, $0) })
        var restored = 0
        for entry in backup.manifest.entries {
            guard let encrypted = encryptedByPath[entry.relativePath],
                  let sealedData = Data(base64Encoded: encrypted.sealedBase64) else { continue }
            let box = try AES.GCM.SealedBox(combined: sealedData)
            let data = try AES.GCM.open(box, using: key)
            let destination = try restoredDestination(for: entry.relativePath, destinationRoot: destinationRoot)
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

    private static func restoredDestination(for relativePath: String, destinationRoot: URL) throws -> URL {
        guard !relativePath.hasPrefix("/"),
              !relativePath.split(separator: "/").contains("..") else {
            throw CompanyStateBackupRestoreError.invalidRelativePath(relativePath)
        }
        return destinationRoot.appendingPathComponent(relativePath)
    }
}

enum CompanyEncryptedBackupBundleStore {
    static let bundleFilename = "bundle.json"
    static let manifestFilename = "manifest.json"
    static let manifestHashFilename = "manifest.sha256"

    static func store(_ backup: CompanyEncryptedStateBackup, storageRoot: URL) throws -> URL {
        try CompanyStateBackupBuilder.validateEncryptedBackupBundle(backup)
        let backupRoot = storageRoot.appendingPathComponent(backup.manifest.backupID, isDirectory: true)
        try FileManager.default.createDirectory(at: backupRoot, withIntermediateDirectories: true)

        let encoder = CompanyStateBackupCodec.encoder()
        try encoder.encode(backup).write(to: backupRoot.appendingPathComponent(bundleFilename), options: [.atomic])
        try encoder.encode(backup.manifest).write(to: backupRoot.appendingPathComponent(manifestFilename), options: [.atomic])
        try (backup.manifestSHA256 + "\n").write(
            to: backupRoot.appendingPathComponent(manifestHashFilename),
            atomically: true,
            encoding: .utf8
        )
        return backupRoot
    }

    static func retrieve(backupID: String, storageRoot: URL) throws -> CompanyEncryptedStateBackup {
        let backupRoot = storageRoot.appendingPathComponent(backupID, isDirectory: true)
        let data = try Data(contentsOf: backupRoot.appendingPathComponent(bundleFilename))
        let backup = try CompanyStateBackupCodec.decoder().decode(CompanyEncryptedStateBackup.self, from: data)
        try CompanyStateBackupBuilder.validateEncryptedBackupBundle(backup)
        return backup
    }
}

enum OS1BackupCommand {
    static func backup(
        sourceRoot: URL,
        candidates: [CompanyStateBackupBuilder.Candidate],
        key: SymmetricKey,
        keyDescriptor: CompanyBackupEncryptionKeyDescriptor = .operatorSupplied(),
        backupID: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> CompanyEncryptedStateBackup {
        try CompanyStateBackupBuilder.makeEncryptedBackup(
            backupID: backupID,
            sourceRoot: sourceRoot,
            candidates: candidates,
            key: key,
            keyDescriptor: keyDescriptor,
            createdAt: createdAt
        )
    }

    static func backupWithOperatorSuppliedKey(
        sourceRoot: URL,
        candidates: [CompanyStateBackupBuilder.Candidate],
        operatorSecret: String,
        backupID: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> CompanyEncryptedStateBackup {
        try backup(
            sourceRoot: sourceRoot,
            candidates: candidates,
            key: CompanyStateBackupKeyMaterial.operatorSupplied(operatorSecret),
            keyDescriptor: .operatorSupplied(),
            backupID: backupID,
            createdAt: createdAt
        )
    }

    static func backupWithKeychainManagedKey(
        sourceRoot: URL,
        candidates: [CompanyStateBackupBuilder.Candidate],
        service: String = CompanyStateBackupKeychainStore.defaultService,
        account: String = CompanyStateBackupKeychainStore.defaultAccount,
        backupID: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> CompanyEncryptedStateBackup {
        try backup(
            sourceRoot: sourceRoot,
            candidates: candidates,
            key: CompanyStateBackupKeychainStore.loadOrCreateKey(service: service, account: account),
            keyDescriptor: .keychainManaged(service: service, account: account),
            backupID: backupID,
            createdAt: createdAt
        )
    }

    static func store(
        backup: CompanyEncryptedStateBackup,
        storageRoot: URL
    ) throws -> URL {
        try CompanyEncryptedBackupBundleStore.store(backup, storageRoot: storageRoot)
    }

    static func retrieve(
        backupID: String,
        storageRoot: URL
    ) throws -> CompanyEncryptedStateBackup {
        try CompanyEncryptedBackupBundleStore.retrieve(backupID: backupID, storageRoot: storageRoot)
    }

    static func restore(
        backup: CompanyEncryptedStateBackup,
        key: SymmetricKey,
        destinationRoot: URL,
        registry: CompanySchemaMigrationRegistry = .current,
        drilledAt: Date = Date()
    ) throws -> CompanyRestoreDrillReport {
        let report = try CompanyStateBackupBuilder.restoreEncryptedBackup(
            backup,
            key: key,
            destinationRoot: destinationRoot,
            drilledAt: drilledAt
        )
        guard report.status == .passed else { return report }
        let quarantineMessages = backup.manifest.entries.compactMap { entry -> String? in
            registry.quarantineMessage(schema: entry.kind.rawValue, version: backup.manifest.schemaVersion)
        }
        if quarantineMessages.isEmpty { return report }
        return CompanyRestoreDrillReport(
            status: .failed,
            drilledAt: drilledAt,
            backupID: report.backupID,
            restoredEntryCount: report.restoredEntryCount,
            recoveryPointObjectiveHours: report.recoveryPointObjectiveHours,
            recoveryTimeObjectiveHours: report.recoveryTimeObjectiveHours,
            integrity: report.integrity,
            restoreRoot: report.restoreRoot,
            notes: quarantineMessages
        )
    }
}
