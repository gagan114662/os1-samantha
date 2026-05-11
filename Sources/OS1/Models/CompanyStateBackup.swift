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
    let secretsPolicy: String
    let entries: [Entry]

    init(
        schemaVersion: Int = 1,
        createdAt: Date = Date(),
        backupID: String,
        sourceRoot: String,
        recoveryPointObjectiveHours: Int = 24,
        secretsPolicy: String = "Secrets are excluded; restore requires Keychain/credential reauthorization.",
        entries: [Entry]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.backupID = backupID
        self.sourceRoot = sourceRoot
        self.recoveryPointObjectiveHours = recoveryPointObjectiveHours
        self.secretsPolicy = secretsPolicy
        self.entries = entries.sorted { $0.relativePath < $1.relativePath }
    }
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
}
