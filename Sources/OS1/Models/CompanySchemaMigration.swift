import Foundation

struct CompanyDurableStateEnvelope: Codable, Hashable {
    static let currentSchemaVersion = 3

    var schemaVersion: Int
    var createdAt: Date
    var migratedAt: Date?
    var records: [CodexSession]

    init(
        schemaVersion: Int = Self.currentSchemaVersion,
        createdAt: Date = Date(),
        migratedAt: Date? = nil,
        records: [CodexSession]
    ) {
        self.schemaVersion = schemaVersion
        self.createdAt = createdAt
        self.migratedAt = migratedAt
        self.records = records
    }
}

struct CompanySchemaMigrationReport: Codable, Hashable {
    enum Status: String, Codable, Hashable {
        case notNeeded
        case migrated
        case failed
    }

    var sourceVersion: Int
    var targetVersion: Int
    var status: Status
    var migratedRecordCount: Int
    var validationErrors: [String]
    var rollbackPath: String?
}

enum CompanySchemaMigrationError: Error, LocalizedError, Equatable {
    case unsupportedVersion(Int)
    case unreadablePayload
    case validationFailed([String])

    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version):
            return "Unsupported durable state schema version \(version)."
        case .unreadablePayload:
            return "State payload is not a known OS1 durable-state schema."
        case .validationFailed(let errors):
            return "Migrated state failed validation: \(errors.joined(separator: ", "))"
        }
    }
}

enum CompanySchemaMigrationEngine {
    private struct Version2Envelope: Codable {
        var schemaVersion: Int
        var createdAt: Date?
        var sessions: [CodexSession]
    }

    static func encodeCurrent(sessions: [CodexSession], now: Date = Date()) throws -> Data {
        let envelope = CompanyDurableStateEnvelope(createdAt: now, records: sessions)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(envelope)
    }

    static func decodeSessions(
        from data: Data,
        now: Date = Date()
    ) throws -> (sessions: [CodexSession], report: CompanySchemaMigrationReport) {
        if let current = try? JSONDecoder().decode(CompanyDurableStateEnvelope.self, from: data),
           current.schemaVersion == CompanyDurableStateEnvelope.currentSchemaVersion {
            let errors = validate(sessions: current.records)
            guard errors.isEmpty else { throw CompanySchemaMigrationError.validationFailed(errors) }
            return (
                current.records,
                CompanySchemaMigrationReport(
                    sourceVersion: current.schemaVersion,
                    targetVersion: CompanyDurableStateEnvelope.currentSchemaVersion,
                    status: .notNeeded,
                    migratedRecordCount: current.records.count,
                    validationErrors: [],
                    rollbackPath: nil
                )
            )
        }

        if let version = try? schemaVersion(in: data),
           version > CompanyDurableStateEnvelope.currentSchemaVersion {
            throw CompanySchemaMigrationError.unsupportedVersion(version)
        }

        let migrated = try migrateToCurrent(from: data, now: now)
        let errors = validate(sessions: migrated.envelope.records)
        guard errors.isEmpty else { throw CompanySchemaMigrationError.validationFailed(errors) }
        return (migrated.envelope.records, migrated.report)
    }

    static func migrateFileAtomically(
        at url: URL,
        now: Date = Date()
    ) throws -> CompanySchemaMigrationReport {
        let original = try Data(contentsOf: url)
        let decoded = try decodeSessions(from: original, now: now)
        if decoded.report.status == .notNeeded {
            return decoded.report
        }

        let rollbackURL = url.deletingLastPathComponent()
            .appendingPathComponent("\(url.lastPathComponent).pre-migration-\(Int(now.timeIntervalSince1970))")
        try original.write(to: rollbackURL, options: [.atomic])

        do {
            let migratedData = try encodeCurrent(sessions: decoded.sessions, now: now)
            try migratedData.write(to: url, options: [.atomic])
            var report = decoded.report
            report.rollbackPath = rollbackURL.path
            return report
        } catch {
            return CompanySchemaMigrationReport(
                sourceVersion: decoded.report.sourceVersion,
                targetVersion: decoded.report.targetVersion,
                status: .failed,
                migratedRecordCount: 0,
                validationErrors: [error.localizedDescription],
                rollbackPath: rollbackURL.path
            )
        }
    }

    static func validate(sessions: [CodexSession]) -> [String] {
        var errors: [String] = []
        var seen = Set<String>()
        for session in sessions {
            if session.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("session.id.empty")
            }
            if !seen.insert(session.id).inserted {
                errors.append("session.id.duplicate:\(session.id)")
            }
            if session.worktreePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("session.worktreePath.empty:\(session.id)")
            }
            if session.branch.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                errors.append("session.branch.empty:\(session.id)")
            }
        }
        return errors.sorted()
    }

    private static func migrateToCurrent(
        from data: Data,
        now: Date
    ) throws -> (envelope: CompanyDurableStateEnvelope, report: CompanySchemaMigrationReport) {
        if let v2 = try? JSONDecoder().decode(Version2Envelope.self, from: data),
           v2.schemaVersion == 2 {
            return (
                CompanyDurableStateEnvelope(
                    createdAt: v2.createdAt ?? now,
                    migratedAt: now,
                    records: v2.sessions
                ),
                CompanySchemaMigrationReport(
                    sourceVersion: 2,
                    targetVersion: CompanyDurableStateEnvelope.currentSchemaVersion,
                    status: .migrated,
                    migratedRecordCount: v2.sessions.count,
                    validationErrors: [],
                    rollbackPath: nil
                )
            )
        }

        if let legacySessions = try? JSONDecoder().decode([CodexSession].self, from: data) {
            return (
                CompanyDurableStateEnvelope(
                    createdAt: now,
                    migratedAt: now,
                    records: legacySessions
                ),
                CompanySchemaMigrationReport(
                    sourceVersion: 1,
                    targetVersion: CompanyDurableStateEnvelope.currentSchemaVersion,
                    status: .migrated,
                    migratedRecordCount: legacySessions.count,
                    validationErrors: [],
                    rollbackPath: nil
                )
            )
        }

        throw CompanySchemaMigrationError.unreadablePayload
    }

    private static func schemaVersion(in data: Data) throws -> Int? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        return object["schemaVersion"] as? Int
    }
}
