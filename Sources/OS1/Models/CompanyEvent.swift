import Foundation

struct CompanyEvent: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case companyCreated
        case heartbeatStarted
        case heartbeatFinished
        case heartbeatQueued
        case budgetBlocked
        case lifecycleChanged
        case userInstruction
        case companyPaused
        case companyResumed
        case companyKilled
        case fleetPaused
        case fleetResumed
        case approvalRequested
        case approvalApproved
        case approvalDenied
        case approvalChangesRequested
        case stateBackupCreated
    }

    let id: UUID
    let occurredAt: Date
    let companyID: String?
    let actor: String
    let kind: Kind
    let summary: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        companyID: String? = nil,
        actor: String = "os1",
        kind: Kind,
        summary: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.companyID = companyID
        self.actor = actor
        self.kind = kind
        self.summary = Self.redact(summary)
        self.metadata = Self.sanitizedMetadata(metadata)
    }

    static func sanitizedMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [:]) { result, pair in
            let key = pair.key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { return }
            result[key] = shouldRedact(key: key, value: pair.value) ? "[redacted]" : redact(pair.value)
        }
    }

    static func redact(_ value: String) -> String {
        var sanitized = value
        let tokenPatterns = [
            #"ghp_[A-Za-z0-9_]{20,}"#,
            #"github_pat_[A-Za-z0-9_]{20,}"#,
            #"sk-[A-Za-z0-9_-]{20,}"#,
            #"xox[baprs]-[A-Za-z0-9-]{20,}"#
        ]
        for pattern in tokenPatterns {
            sanitized = sanitized.replacingOccurrences(
                of: pattern,
                with: "[redacted]",
                options: .regularExpression
            )
        }
        return sanitized
    }

    private static func shouldRedact(key: String, value: String) -> Bool {
        let lowerKey = key.lowercased()
        if lowerKey.contains("token")
            || lowerKey.contains("secret")
            || lowerKey.contains("password")
            || lowerKey == "pat"
            || lowerKey.contains("credential")
            || lowerKey.contains("authorization")
            || lowerKey.contains("api_key")
            || lowerKey.contains("apikey") {
            return true
        }

        return redact(value) != value
    }
}
