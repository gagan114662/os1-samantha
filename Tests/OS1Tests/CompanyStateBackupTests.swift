import Foundation
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
    }

    @Test
    func backupManifestSkipsMissingCandidates() throws {
        let root = FileManager.default.temporaryDirectory
        let manifest = try CompanyStateBackupBuilder.makeManifest(
            backupID: "backup-empty",
            sourceRoot: root,
            candidates: [
                .init(sourceURL: root.appendingPathComponent("missing.json"), relativePath: "missing.json", kind: .sessions)
            ]
        )

        #expect(manifest.entries.isEmpty)
    }
}
