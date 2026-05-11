import Foundation
import Testing
@testable import OS1

struct CompanySchemaMigrationTests {
    @Test
    func currentEnvelopeDecodesWithoutMigration() throws {
        let session = fixtureSession(id: "current")
        let data = try CompanySchemaMigrationEngine.encodeCurrent(
            sessions: [session],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let decoded = try CompanySchemaMigrationEngine.decodeSessions(from: data)

        #expect(decoded.sessions.map(\.id) == ["current"])
        #expect(decoded.report.status == .notNeeded)
        #expect(decoded.report.sourceVersion == CompanyDurableStateEnvelope.currentSchemaVersion)
    }

    @Test
    func migratesPreviousTwoDurableVersions() throws {
        let session = fixtureSession(id: "legacy")
        let encoder = JSONEncoder()
        let legacyArray = try encoder.encode([session])
        let encodedSession = String(data: try encoder.encode(session), encoding: .utf8) ?? "{}"
        let version2 = """
        {
          "schemaVersion": 2,
          "createdAt": 1700000000,
          "sessions": [\(encodedSession)]
        }
        """.data(using: .utf8) ?? Data()

        let v1 = try CompanySchemaMigrationEngine.decodeSessions(from: legacyArray)
        let v2 = try CompanySchemaMigrationEngine.decodeSessions(from: version2)

        #expect(v1.report.sourceVersion == 1)
        #expect(v1.report.status == .migrated)
        #expect(v1.sessions.first?.id == "legacy")
        #expect(v2.report.sourceVersion == 2)
        #expect(v2.report.status == .migrated)
        #expect(v2.sessions.first?.id == "legacy")
    }

    @Test
    func startupValidationRejectsCorruptMigratedState() throws {
        let first = fixtureSession(id: "duplicate")
        let second = fixtureSession(id: "duplicate")
        let data = try JSONEncoder().encode([first, second])

        do {
            _ = try CompanySchemaMigrationEngine.decodeSessions(from: data)
            Issue.record("Expected duplicate session IDs to fail validation")
        } catch CompanySchemaMigrationError.validationFailed(let errors) {
            #expect(errors.contains("session.id.duplicate:duplicate"))
        }
    }

    @Test
    func failedMigrationDoesNotCorruptOriginalFile() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-schema-migration-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let stateURL = root.appendingPathComponent("sessions.json")
        let original = #"{"schemaVersion":99,"records":[]}"#
        try original.write(to: stateURL, atomically: true, encoding: .utf8)

        do {
            _ = try CompanySchemaMigrationEngine.migrateFileAtomically(at: stateURL)
            Issue.record("Expected unsupported schema version to fail")
        } catch CompanySchemaMigrationError.unsupportedVersion(let version) {
            #expect(version == 99)
        }

        let after = try String(contentsOf: stateURL, encoding: .utf8)
        #expect(after == original)
    }

    @Test
    func releaseChecklistIncludesMigrationVerification() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/production-operating-model.md")
        let document = try String(contentsOf: url, encoding: .utf8)

        #expect(document.contains("## Schema Migration Release Checklist"))
        #expect(document.contains("previous two durable-state versions"))
        #expect(document.contains("rollback copy"))
    }

    @Test
    func migrationRegistryTracksNoopMigrationsAndDowngradeQuarantine() throws {
        let envelope = CompanyPersistedArtifactEnvelope(version: 1, schema: "CompanyLedgerEntry", payload: ["id": "ledger-1"])
        let data = try JSONEncoder().encode(envelope)
        let decoded = try JSONDecoder().decode(CompanyPersistedArtifactEnvelope<[String: String]>.self, from: data)
        let registry = CompanySchemaMigrationRegistry.current

        #expect(decoded.schema == "CompanyLedgerEntry")
        #expect(registry.pendingMigrationCount(schema: "CodexSession", version: 2) >= 1)
        #expect(registry.quarantineMessage(schema: "CodexSession", version: 99)?.contains("supports up to v3") == true)
        #expect(registry.migrations.contains { $0.schema == "CompanyLedgerEntry" && $0.fromVersion == $0.toVersion })
    }

    private func fixtureSession(id: String) -> CodexSession {
        CodexSession(
            id: id,
            title: "Company \(id)",
            task: "Build a durable-state migration fixture",
            worktreePath: "/tmp/os1/\(id)",
            branch: "company/\(id)",
            status: .idle,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: nil,
            exitCode: nil,
            pid: nil
        )
    }
}
