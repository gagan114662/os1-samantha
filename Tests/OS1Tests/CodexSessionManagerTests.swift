import Foundation
import Testing
@testable import OS1

/// Focused unit tests for `CodexSessionManager`. The integration paths
/// (git worktrees, codex subprocesses, heartbeat timers) need a temp-dir
/// harness that's bigger than this initial batch — these cover the pure
/// functions and persistence boundary, which is where regressions would
/// silently change agent behavior.
struct CodexSessionManagerTests {

    // MARK: - Marker parsing (pure)

    @Test
    func auditCorrectionTakesPrecedenceOverWorkerBlocked() {
        // Worker said BLOCKED, but the next audit cycle disagrees and asks
        // for a correction. Audit must win.
        let journal = """
        ## Heartbeat 5 — couldn't post
        Tried to use Twitter API but no key.
        BLOCKED: need TWITTER_BEARER_TOKEN
        """
        let audit = """
        ## Audit at 2026-05-11
        - [HALLUCINATED] "Twitter posting impossible" — fb-credentials work fine in Composio, agent didn't check
        CORRECTION: Check Composio for a Twitter connection before claiming BLOCKED on it.
        """
        let result = CodexSessionManager.parseMarkers(journal: journal, auditDoc: audit)
        #expect(result.blocked == nil)
        #expect(result.correction?.hasPrefix("AUDITOR FOUND ISSUES") == true)
        #expect(result.correction?.contains("Check Composio") == true)
    }

    @Test
    func auditBlockedFlipsCompanyToBlockedStatus() {
        let audit = """
        ## Audit
        BLOCKED: founder must approve $200/mo Twitter Basic API tier
        """
        let result = CodexSessionManager.parseMarkers(journal: "", auditDoc: audit)
        #expect(result.blocked == "founder must approve $200/mo Twitter Basic API tier")
        #expect(result.correction == nil)
    }

    @Test
    func auditCleanFallsThroughToNoMarkers() {
        // CLEAN means audit was happy — neither blocked nor correction.
        // Journal might have an old BLOCKED in earlier entries but worker's
        // CURRENT entry would be NEXT.
        let journal = """
        ## Heartbeat 4 — fixed
        Wrote tweet queue.
        NEXT: open Composio Twitter
        """
        let audit = "## Audit\nCLEAN: trajectory is on-mission, real metrics, no drift\n"
        let result = CodexSessionManager.parseMarkers(journal: journal, auditDoc: audit)
        #expect(result.blocked == nil)
        #expect(result.correction == nil)
    }

    @Test
    func workerBlockedDetectedWhenNoAuditDoc() {
        // Audit doesn't exist yet (early in a company's life), only journal.
        let journal = """
        ## Heartbeat 1
        Tried to log into Instagram, got CAPTCHA.
        BLOCKED: needs human to solve initial CAPTCHA + 2FA setup
        """
        let result = CodexSessionManager.parseMarkers(journal: journal, auditDoc: "")
        #expect(result.blocked == "needs human to solve initial CAPTCHA + 2FA setup")
        #expect(result.correction == nil)
    }

    @Test
    func workerNextStopsParsingWithoutFalseBlock() {
        // A healthy heartbeat ending with NEXT shouldn't surface anything.
        // Even if an OLDER heartbeat in the same journal had BLOCKED.
        let journal = """
        ## Heartbeat 1
        BLOCKED: needed Stripe
        ## Heartbeat 2
        Founder added Stripe key.
        NEXT: build first checkout link
        """
        let result = CodexSessionManager.parseMarkers(journal: journal, auditDoc: "")
        #expect(result.blocked == nil, "most recent marker is NEXT, must win over older BLOCKED")
    }

    @Test
    func emptyInputsReturnNoMarkers() {
        let result = CodexSessionManager.parseMarkers(journal: "", auditDoc: "")
        #expect(result.blocked == nil)
        #expect(result.correction == nil)
    }

    @Test
    func markersTolerateLeadingWhitespace() {
        let audit = "         BLOCKED:   spacing-tolerant   "
        let result = CodexSessionManager.parseMarkers(journal: "", auditDoc: audit)
        #expect(result.blocked == "spacing-tolerant")
    }

    @Test
    func multipleBlockedTakesMostRecent() {
        let journal = """
        ## hb 1
        BLOCKED: old reason A
        ## hb 2
        BLOCKED: newer reason B
        """
        let result = CodexSessionManager.parseMarkers(journal: journal, auditDoc: "")
        #expect(result.blocked == "newer reason B")
    }

    // MARK: - CodexSession persistence (Codable roundtrip)

    @Test
    func sessionRoundTripsThroughJSONCleanly() throws {
        let original = CodexSession(
            id: "abc12345",
            title: "samantha-content",
            task: "Build a Twitter audience around AI agents",
            worktreePath: "/Users/test/.os1/codex-tasks/sessions/abc12345",
            branch: "company/abc12345",
            status: .blocked,
            startedAt: Date(timeIntervalSince1970: 1_700_000_000),
            finishedAt: nil,
            exitCode: 0,
            pid: 12345,
            cadenceMinutes: 15,
            heartbeatCount: 7,
            lastHeartbeatAt: Date(timeIntervalSince1970: 1_700_001_000),
            nextHeartbeatAt: Date(timeIntervalSince1970: 1_700_001_900),
            pendingUserInstruction: "Focus on shorts",
            blockedReason: "needs Twitter OAuth via Composio"
        )

        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([CodexSession].self, from: data)
        let round = try #require(decoded.first)

        #expect(round.id == "abc12345")
        #expect(round.title == "samantha-content")
        #expect(round.task == original.task)
        #expect(round.status == .blocked)
        #expect(round.heartbeatCount == 7)
        #expect(round.cadenceMinutes == 15)
        #expect(round.pendingUserInstruction == "Focus on shorts")
        #expect(round.blockedReason == "needs Twitter OAuth via Composio")
        #expect(round.nextHeartbeatAt == original.nextHeartbeatAt)
    }

    @Test
    func sessionDecodesEvenWhenOlderFieldsAreMissing() throws {
        // Persisted JSON from before heartbeat/cadence/audit fields existed
        // must still decode (otherwise app launch wipes saved companies after
        // every schema change). All new fields are Optional with defaults, so
        // synthesized Codable decodes legacy records cleanly.
        let legacyJSON = """
        [{
            "id": "deadbeef",
            "title": "legacy-company",
            "task": "do stuff",
            "worktreePath": "/tmp/legacy",
            "branch": "company/deadbeef",
            "status": "idle",
            "startedAt": 800000000.0,
            "cadenceMinutes": 15,
            "heartbeatCount": 0
        }]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([CodexSession].self, from: legacyJSON)
        let session = try #require(decoded.first)
        #expect(session.id == "deadbeef")
        #expect(session.title == "legacy-company")
        #expect(session.status == .idle)
        // Newer fields default to nil; absence must not break load.
        #expect(session.blockedReason == nil)
        #expect(session.lastHeartbeatAt == nil)
        #expect(session.nextHeartbeatAt == nil)
        #expect(session.pendingUserInstruction == nil)
    }

    // MARK: - Status colour mapping (lightweight UI invariant)

    @Test
    func statusColorCoversAllCases() {
        for status in [
            CodexSession.Status.running,
            .idle,
            .blocked,
            .paused,
            .completed,
            .failed,
            .killed,
        ] {
            var session = CodexSession(
                id: "x", title: "x", task: "x",
                worktreePath: "/tmp/x", branch: "company/x",
                status: status,
                startedAt: Date()
            )
            session.status = status
            #expect(!session.statusColor.isEmpty, "status \(status) must have a colour name")
        }
    }
}
