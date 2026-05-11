import CryptoKit
import Foundation

struct CompanyEvent: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case companyCreated
        case externalSideEffect
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
        case secretAccessed
        case complianceChecked
        case complianceBlocked
        case approvalRequested
        case approvalApproved
        case approvalDenied
        case approvalChangesRequested
        case permissionChanged
        case permissionDenied
        case permissionEscalated
        case stateBackupCreated
        case ledgerEntryRecorded
        case untrustedContentInfluencedDecision
    }

    let id: UUID
    let occurredAt: Date
    let companyID: String?
    let actor: String
    let kind: Kind
    let summary: String
    let runID: String?
    let tool: String?
    let inputHash: String?
    let outputSummary: String?
    let costUSD: Double?
    let latencyMS: Int?
    let riskTier: String?
    let approvalState: String?
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        occurredAt: Date = Date(),
        companyID: String? = nil,
        actor: String = "os1",
        kind: Kind,
        summary: String,
        runID: String? = nil,
        tool: String? = nil,
        inputHash: String? = nil,
        outputSummary: String? = nil,
        costUSD: Double? = nil,
        latencyMS: Int? = nil,
        riskTier: String? = nil,
        approvalState: String? = nil,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.occurredAt = occurredAt
        self.companyID = companyID
        self.actor = actor
        self.kind = kind
        self.summary = Self.redact(summary)
        self.runID = runID
        self.tool = tool
        self.inputHash = inputHash
        self.outputSummary = outputSummary.map(Self.redact)
        self.costUSD = costUSD
        self.latencyMS = latencyMS
        self.riskTier = riskTier
        self.approvalState = approvalState
        self.metadata = Self.sanitizedMetadata(metadata)
    }

    var isFailedHeartbeat: Bool {
        guard kind == .heartbeatFinished else { return false }
        if metadata["status"] == CodexSession.Status.failed.rawValue { return true }
        if metadata["status"] == CodexSession.Status.killed.rawValue { return true }
        return (Int(metadata["exitCode"] ?? "0") ?? 0) != 0
    }

    var isSuccessfulHeartbeat: Bool {
        guard kind == .heartbeatFinished else { return false }
        return !isFailedHeartbeat
    }

    static func inputHash(for value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
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

struct CompanyMetricsSnapshot: Codable, Hashable {
    let eventCount: Int
    let heartbeatStartedCount: Int
    let heartbeatSucceededCount: Int
    let heartbeatFailedCount: Int
    let successRate: Double
    let errorRate: Double
    let averageLatencyMS: Int?
    let manualInterventionCount: Int
    let totalObservedCostUSD: Double
    let revenueUSD: Double
    let costUSD: Double
    let profitUSD: Double
    let lastEventAt: Date?

    static func summarize(
        events: [CompanyEvent],
        revenueUSD: Double = 0,
        costUSD: Double = 0
    ) -> CompanyMetricsSnapshot {
        let started = events.filter { $0.kind == .heartbeatStarted }.count
        let finished = events.filter { $0.kind == .heartbeatFinished }
        let failed = finished.filter(\.isFailedHeartbeat).count
        let succeeded = finished.filter(\.isSuccessfulHeartbeat).count
        let latencies = finished.compactMap(\.latencyMS)
        let averageLatency = latencies.isEmpty ? nil : latencies.reduce(0, +) / latencies.count
        let manualInterventions = events.filter {
            $0.kind == .userInstruction
                || $0.kind == .approvalApproved
                || $0.kind == .approvalDenied
                || $0.kind == .approvalChangesRequested
        }.count
        let observedCost = events.compactMap(\.costUSD).reduce(0, +)
        let denominator = max(1, finished.count)

        return CompanyMetricsSnapshot(
            eventCount: events.count,
            heartbeatStartedCount: started,
            heartbeatSucceededCount: succeeded,
            heartbeatFailedCount: failed,
            successRate: Double(succeeded) / Double(denominator),
            errorRate: Double(failed) / Double(denominator),
            averageLatencyMS: averageLatency,
            manualInterventionCount: manualInterventions,
            totalObservedCostUSD: observedCost,
            revenueUSD: revenueUSD,
            costUSD: costUSD,
            profitUSD: revenueUSD - costUSD - observedCost,
            lastEventAt: events.map(\.occurredAt).max()
        )
    }
}
