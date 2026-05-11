import CryptoKit
import Foundation

enum OS1UpdateChannel: String, Codable, CaseIterable, Hashable {
    case stable
    case beta
    case nightly
}

struct OS1ReleaseManifest: Codable, Hashable, Identifiable {
    let id: String
    var version: String
    var build: Int
    var channel: OS1UpdateChannel
    var minimumSchemaVersion: Int
    var downloadURL: URL
    var sha256: String
    var notarized: Bool
    var createdAt: Date
}

struct OS1UpdateDecision: Codable, Hashable {
    enum Status: String, Codable, CaseIterable, Hashable {
        case upToDate
        case updateAvailable
        case blockedBySchema
        case channelMismatch
        case invalidManifest
    }

    var status: Status
    var target: OS1ReleaseManifest?
    var reasons: [String]

    var canInstall: Bool {
        status == .updateAvailable
    }
}

enum OS1UpdatePlanner {
    static func decide(
        currentVersion: String,
        currentBuild: Int,
        currentSchemaVersion: Int,
        channel: OS1UpdateChannel,
        available: [OS1ReleaseManifest]
    ) -> OS1UpdateDecision {
        let candidates = available
            .filter { $0.channel == channel }
            .sorted { $0.build > $1.build }
        guard let latest = candidates.first else {
            return .init(status: .channelMismatch, target: nil, reasons: ["No release exists for \(channel.rawValue)."])
        }
        guard latest.notarized else {
            return .init(
                status: .invalidManifest,
                target: latest,
                reasons: ["Release \(latest.version) is not notarized."]
            )
        }
        guard latest.sha256.count == 64 else {
            return .init(
                status: .invalidManifest,
                target: latest,
                reasons: ["Release checksum is missing or malformed."]
            )
        }
        guard currentSchemaVersion >= latest.minimumSchemaVersion else {
            return .init(
                status: .blockedBySchema,
                target: latest,
                reasons: ["State schema must migrate before installing \(latest.version)."]
            )
        }
        if latest.build > currentBuild || latest.version != currentVersion {
            return .init(
                status: .updateAvailable,
                target: latest,
                reasons: ["Release \(latest.version) build \(latest.build) is newer."]
            )
        }
        return .init(status: .upToDate, target: latest, reasons: ["Current build is up to date."])
    }
}

struct OS1SchemaMigrationPlan: Codable, Hashable, Identifiable {
    let id: String
    var fromVersion: Int
    var toVersion: Int
    var forwardSteps: [String]
    var rollbackSteps: [String]
    var destructive: Bool

    var isReversible: Bool {
        !destructive && !rollbackSteps.isEmpty
    }
}

struct OS1RollbackPlan: Codable, Hashable {
    var appBundleBackupPath: String
    var encryptedStateBackupID: String
    var previousVersion: String
    var migrationPlan: OS1SchemaMigrationPlan
    var daemonSnapshots: [String]

    var canRollback: Bool {
        !appBundleBackupPath.isEmpty
            && !encryptedStateBackupID.isEmpty
            && migrationPlan.isReversible
            && !daemonSnapshots.isEmpty
    }
}

struct OS1EncryptedBackupEnvelope: Codable, Hashable {
    var algorithm: String
    var nonceBase64: String
    var ciphertextBase64: String
    var sealedBoxBase64: String
    var createdAt: Date

    static func seal(
        plaintext: Data,
        key: SymmetricKey,
        createdAt: Date = Date()
    ) throws -> OS1EncryptedBackupEnvelope {
        let sealed = try AES.GCM.seal(plaintext, using: key)
        guard let combined = sealed.combined else {
            throw CocoaError(.fileWriteUnknown)
        }
        return OS1EncryptedBackupEnvelope(
            algorithm: "AES.GCM.256",
            nonceBase64: sealed.nonce.withUnsafeBytes { Data($0).base64EncodedString() },
            ciphertextBase64: sealed.ciphertext.base64EncodedString(),
            sealedBoxBase64: combined.base64EncodedString(),
            createdAt: createdAt
        )
    }

    func open(key: SymmetricKey) throws -> Data {
        guard let combined = Data(base64Encoded: sealedBoxBase64) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let sealed = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealed, using: key)
    }
}

struct OS1ReleaseChecklist: Codable, Hashable {
    var signedWithDeveloperID: Bool
    var notarized: Bool
    var stapled: Bool
    var reproducibleArchiveChecksum: String?
    var updateManifestPresent: Bool
    var encryptedBackupCreated: Bool
    var rollbackPlanPresent: Bool
    var smokeTestsPassed: Bool
    var migrationPlan: OS1SchemaMigrationPlan?

    var blockers: [String] {
        var values: [String] = []
        if !signedWithDeveloperID { values.append("Developer ID signing is required.") }
        if !notarized { values.append("Notarization is required.") }
        if !stapled { values.append("Stapled notarization ticket is required.") }
        if reproducibleArchiveChecksum?.count != 64 { values.append("Reproducible release checksum is required.") }
        if !updateManifestPresent { values.append("Update manifest is required.") }
        if !encryptedBackupCreated { values.append("Encrypted state backup is required.") }
        if !rollbackPlanPresent { values.append("Rollback plan is required.") }
        if !smokeTestsPassed { values.append("Release smoke tests must pass.") }
        if migrationPlan?.isReversible == false {
            values.append("Migration must be reversible or explicitly blocked from release.")
        }
        return values
    }

    var canRelease: Bool {
        blockers.isEmpty
    }
}
