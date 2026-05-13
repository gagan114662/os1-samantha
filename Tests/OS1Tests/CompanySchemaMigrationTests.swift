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
    @MainActor
    func managerStartupMigratesVersion2FileBeforeUsingSessions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-manager-schema-startup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let session = fixtureSession(id: "startup-v2")
        let encodedSession = String(data: try JSONEncoder().encode(session), encoding: .utf8) ?? "{}"
        let stateURL = root.appendingPathComponent("sessions.json")
        try """
        {
          "schemaVersion": 2,
          "createdAt": 1700000000,
          "sessions": [\(encodedSession)]
        }
        """.write(to: stateURL, atomically: true, encoding: .utf8)

        let manager = CodexSessionManager(testRoot: root)
        manager.flushLogsForTesting()

        let migratedData = try Data(contentsOf: stateURL)
        #expect(try CompanySchemaMigrationEngine.schemaVersion(in: migratedData) == 3)
        #expect(manager.sessions.map(\.id) == ["startup-v2"])
        let rollbackCopies = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("sessions.json.pre-migration-v2-") }
        #expect(rollbackCopies.count == 1)
        #expect(manager.recentEvents().contains { event in
            event.kind == .schemaMigration
                && event.metadata["sourceVersion"] == "2"
                && event.metadata["status"] == "migrated"
        })
    }

    @Test
    func durableStateInspectionReportsVersionsBeforePayloadDecode() throws {
        let current = """
        {
          "schemaVersion": 3,
          "createdAt": 1700000000,
          "records": "not-an-array"
        }
        """.data(using: .utf8) ?? Data()
        let v2 = """
        {
          "schemaVersion": 2,
          "createdAt": 1700000000,
          "sessions": []
        }
        """.data(using: .utf8) ?? Data()
        let legacy = try JSONEncoder().encode([fixtureSession(id: "legacy-v1")])

        let currentStatus = CompanySchemaMigrationEngine.inspectDurableState(data: current)
        let v2Status = CompanySchemaMigrationEngine.inspectDurableState(data: v2)
        let legacyStatus = CompanySchemaMigrationEngine.inspectDurableState(data: legacy)

        #expect(currentStatus.onDiskVersion == 3)
        #expect(currentStatus.state == .current)
        #expect(v2Status.onDiskVersion == 2)
        #expect(v2Status.state == .migrationRequired)
        #expect(legacyStatus.onDiskVersion == nil)
        #expect(legacyStatus.state == .missing)
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
        let rollbackCopies = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix("sessions.json.pre-migration-v99-") }
        #expect(rollbackCopies.count == 1)
    }

    @Test
    func rollbackToVersion2CodeRefusesVersion3StateWithStructuredError() throws {
        let state = try CompanySchemaMigrationEngine.encodeCurrent(
            sessions: [fixtureSession(id: "v3")],
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )

        do {
            _ = try Version2RollbackDecoder.decodeSessions(from: state)
            Issue.record("Expected v2 code to refuse v3 state cleanly")
        } catch CompanySchemaMigrationError.unsupportedVersion(let version) {
            #expect(version == 3)
        }
    }

    @Test
    func doctorSchemaRowSurfacesMismatchWithMigrateAction() {
        let check = DoctorViewModel.durableStateSchemaCheck(
            status: CompanySchemaVersionStatus(
                schema: "CodexSession",
                onDiskVersion: 2,
                expectedVersion: 3,
                state: .migrationRequired,
                warningCode: "schema.version.outdated"
            )
        )

        #expect(check.id == "durable-state-schema")
        #expect(check.severity == .warn)
        #expect(check.summary.contains("On disk v2, expected v3"))
        #expect(check.detail?.contains("warningCode=schema.version.outdated") == true)
        #expect(check.actions == [.migrateSchema])
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

    private enum Version2RollbackDecoder {
        private struct Version2Envelope: Codable {
            var schemaVersion: Int
            var createdAt: Date?
            var sessions: [CodexSession]
        }

        static func decodeSessions(from data: Data) throws -> [CodexSession] {
            guard let version = try CompanySchemaMigrationEngine.schemaVersion(in: data) else {
                throw CompanySchemaMigrationError.missingSchemaVersion
            }
            guard version <= 2 else {
                throw CompanySchemaMigrationError.unsupportedVersion(version)
            }
            return try JSONDecoder().decode(Version2Envelope.self, from: data).sessions
        }
    }
}
