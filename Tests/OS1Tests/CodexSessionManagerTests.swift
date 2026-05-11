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

    // MARK: - Revenue signal parsing

    @Test
    func verifiedRevenueSignalRequiresPositiveDollarAmount() {
        #expect(CodexSessionManager.hasVerifiedRevenueSignal("2026-05-11 Stripe checkout paid: $19.00 id=cs_test_123"))
        #expect(CodexSessionManager.hasVerifiedRevenueSignal("Verified revenue: $1,250.50 from Stripe payout"))
        #expect(!CodexSessionManager.hasVerifiedRevenueSignal("2026-05-11 $0"))
        #expect(!CodexSessionManager.hasVerifiedRevenueSignal("(no revenue API connected yet)"))
        #expect(!CodexSessionManager.hasVerifiedRevenueSignal("estimated revenue projection: $500"))
        #expect(!CodexSessionManager.hasVerifiedRevenueSignal("unmeasured affiliate clicks, possible $25"))
    }

    // MARK: - Credential sandboxing

    @Test
    func credentialParserOnlyExposesAllowlistedNames() {
        let contents = """
        # comments ignored
        export STRIPE_API_KEY="sk_live_should_not_be_logged"
        RESEND_API_KEY='resend-secret'
        GITHUB_TOKEN=ghp_shouldnotleak123456789012345
        """

        let env = CodexSessionManager.parseCredentialEnvironment(
            contents: contents,
            allowlist: ["RESEND_API_KEY"]
        )

        #expect(env == ["RESEND_API_KEY": "resend-secret"])
    }

    @Test
    func credentialParserCanExposeAllNamesForLocalDevelopmentMode() {
        let contents = """
        A=1
        export B="two"
        """

        let env = CodexSessionManager.parseCredentialEnvironment(contents: contents, allowlist: nil)

        #expect(env["A"] == "1")
        #expect(env["B"] == "two")
    }

    @Test
    func credentialLogLineContainsNamesButNeverValues() {
        let line = CodexSessionManager.redactedCredentialLogLine(
            names: ["STRIPE_API_KEY", "RESEND_API_KEY"],
            values: ["sk_live_should_not_be_logged", "resend-secret"]
        )

        #expect(line.contains("RESEND_API_KEY"))
        #expect(line.contains("STRIPE_API_KEY"))
        #expect(!line.contains("sk_live_should_not_be_logged"))
        #expect(!line.contains("resend-secret"))
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
            templateID: "youtube-ai-tool-tutorials",
            budget: .defaultState(now: Date(timeIntervalSince1970: 1_700_000_000)),
            lifecycleStage: .validating,
            sandboxMode: .sandbox,
            credentialAllowlist: ["STRIPE_API_KEY"],
            heartbeatLease: CodexSession.HeartbeatLease(
                id: "lease-1",
                heartbeatCount: 7,
                acquiredAt: Date(timeIntervalSince1970: 1_700_001_000),
                expiresAt: Date(timeIntervalSince1970: 1_700_008_200),
                ownerPID: 12345
            ),
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
        #expect(round.templateID == "youtube-ai-tool-tutorials")
        #expect(round.lifecycleStage == .validating)
        #expect(round.sandboxMode == .sandbox)
        #expect(round.credentialAllowlist == ["STRIPE_API_KEY"])
        #expect(round.heartbeatLease?.id == "lease-1")
        #expect(round.heartbeatLease?.ownerPID == 12345)
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
        #expect(session.lifecycleStage == .validating)
        #expect(session.sandboxMode == .sandbox)
        #expect(session.credentialAllowlist.isEmpty)
        #expect(session.heartbeatLease == nil)
    }

    @Test
    func sessionDecodesLegacyProductionSandboxNameAsSandbox() throws {
        let legacyJSON = """
        [{
            "id": "deadbeef",
            "title": "legacy-company",
            "task": "do stuff",
            "worktreePath": "/tmp/legacy",
            "branch": "company/deadbeef",
            "status": "idle",
            "startedAt": 800000000.0,
            "sandboxMode": "productionSandbox"
        }]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([CodexSession].self, from: legacyJSON)
        let session = try #require(decoded.first)

        #expect(session.sandboxMode == .sandbox)
    }

    @Test
    func legacyBudgetStateDecodesWithSpendPolicyDefaults() throws {
        let legacyJSON = """
        [{
            "id": "budget",
            "title": "legacy-budget",
            "task": "do stuff",
            "worktreePath": "/tmp/budget",
            "branch": "company/budget",
            "status": "idle",
            "startedAt": 800000000.0,
            "budget": {
                "dailyWindowStart": 800000000.0,
                "dailyHeartbeatCount": 3,
                "maxDailyHeartbeats": 6,
                "maxHeartbeatsWithoutRevenueSignal": 12
            }
        }]
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode([CodexSession].self, from: legacyJSON)
        let session = try #require(decoded.first)

        #expect(session.budget?.dailyHeartbeatCount == 3)
        #expect(session.budget?.maxDailyHeartbeats == 6)
        #expect(session.budget?.policy.companyHardLimitUSD == CompanyBudgetPolicy.productionDefault.companyHardLimitUSD)
        #expect(session.budget?.approvals.isEmpty == true)
    }

    // MARK: - Restart recovery / leases

    @Test
    func restartRecoveryQueuesRunningSessionWithActiveLease() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var session = CodexSession(
            id: "leased",
            title: "leased",
            task: "run",
            worktreePath: "/tmp/leased",
            branch: "company/leased",
            status: .running,
            startedAt: now
        )
        session.pid = 4321
        session.heartbeatLease = CodexSession.HeartbeatLease(
            id: "active",
            heartbeatCount: 2,
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(600),
            ownerPID: 4321
        )

        let recovered = CodexSessionManager.recoverSessionAfterRestart(session, now: now, retryJitterSeconds: 10)

        #expect(recovered.status == .queued)
        #expect(recovered.pid == nil)
        #expect(recovered.heartbeatLease?.id == "active")
        #expect(recovered.nextHeartbeatAt == now.addingTimeInterval(610))
    }

    @Test
    func restartRecoveryResumesRunningSessionWithExpiredLease() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var session = CodexSession(
            id: "expired",
            title: "expired",
            task: "run",
            worktreePath: "/tmp/expired",
            branch: "company/expired",
            status: .running,
            startedAt: now
        )
        session.pid = 4321
        session.heartbeatLease = CodexSession.HeartbeatLease(
            id: "expired",
            heartbeatCount: 2,
            acquiredAt: now.addingTimeInterval(-900),
            expiresAt: now.addingTimeInterval(-60),
            ownerPID: 4321
        )

        let recovered = CodexSessionManager.recoverSessionAfterRestart(session, now: now, retryJitterSeconds: 10)

        #expect(recovered.status == .idle)
        #expect(recovered.pid == nil)
        #expect(recovered.heartbeatLease == nil)
        #expect(recovered.nextHeartbeatAt == now.addingTimeInterval(10))
    }

    @Test
    func duplicateLaunchdStartsCannotAcquireSameHeartbeatLock() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-lock-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lockURL = root.appendingPathComponent("company.lock.json")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let lease = CodexSession.HeartbeatLease(
            id: "lease-1",
            heartbeatCount: 1,
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(600),
            ownerPID: 111
        )
        let duplicate = CodexSession.HeartbeatLease(
            id: "lease-2",
            heartbeatCount: 1,
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(600),
            ownerPID: 222
        )

        #expect(CodexSessionManager.tryAcquireHeartbeatLock(lockURL: lockURL, companyID: "company", lease: lease, now: now))
        #expect(!CodexSessionManager.tryAcquireHeartbeatLock(lockURL: lockURL, companyID: "company", lease: duplicate, now: now))

        let record = try #require(CodexSessionManager.heartbeatLockRecord(at: lockURL))
        #expect(record.leaseID == "lease-1")
        #expect(record.ownerPID == 111)
    }

    @Test
    func expiredHeartbeatLockCanBeReacquiredAfterProcessKill() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-stale-lock-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let lockURL = root.appendingPathComponent("company.lock.json")
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let expired = CodexSession.HeartbeatLease(
            id: "expired",
            heartbeatCount: 2,
            acquiredAt: now.addingTimeInterval(-900),
            expiresAt: now.addingTimeInterval(-60),
            ownerPID: 111
        )
        let replacement = CodexSession.HeartbeatLease(
            id: "replacement",
            heartbeatCount: 3,
            acquiredAt: now,
            expiresAt: now.addingTimeInterval(600),
            ownerPID: 222
        )

        #expect(CodexSessionManager.tryAcquireHeartbeatLock(lockURL: lockURL, companyID: "company", lease: expired, now: now.addingTimeInterval(-120)))
        #expect(CodexSessionManager.tryAcquireHeartbeatLock(lockURL: lockURL, companyID: "company", lease: replacement, now: now))

        let record = try #require(CodexSessionManager.heartbeatLockRecord(at: lockURL))
        #expect(record.leaseID == "replacement")
        #expect(record.heartbeatCount == 3)
    }

    @Test
    func processKillAndRestartRecoveryPreservesStateUntilLeaseExpires() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var killedMidRun = CodexSession(
            id: "killed",
            title: "killed",
            task: "run",
            worktreePath: "/tmp/killed",
            branch: "company/killed",
            status: .running,
            startedAt: now.addingTimeInterval(-60)
        )
        killedMidRun.heartbeatCount = 9
        killedMidRun.pid = 9999
        killedMidRun.heartbeatLease = CodexSession.HeartbeatLease(
            id: "lease",
            heartbeatCount: 9,
            acquiredAt: now.addingTimeInterval(-60),
            expiresAt: now.addingTimeInterval(300),
            ownerPID: 9999
        )

        let recovered = CodexSessionManager.recoverSessionAfterRestart(killedMidRun, now: now, retryJitterSeconds: 30)

        #expect(recovered.status == .queued)
        #expect(recovered.heartbeatCount == 9)
        #expect(recovered.pid == nil)
        #expect(recovered.heartbeatLease?.id == "lease")
        #expect(recovered.nextHeartbeatAt == now.addingTimeInterval(330))
    }

    @Test
    func heartbeatFailureAssessmentProvidesActionableRetryStatus() {
        let transient = CodexSessionManager.heartbeatFailureAssessment(
            exitCode: 1,
            logTail: "failed to connect to websocket"
        )
        #expect(transient.isTransient)
        #expect(transient.kind == "transientNetwork")
        #expect(transient.operatorAction.contains("retry"))

        let auth = CodexSessionManager.heartbeatFailureAssessment(
            exitCode: 1,
            logTail: "401 unauthorized"
        )
        #expect(!auth.isTransient)
        #expect(auth.kind == "authentication")
        #expect(auth.operatorAction.contains("credential"))
    }

    // MARK: - Status colour mapping (lightweight UI invariant)

    @Test
    func statusColorCoversAllCases() {
        for status in [
            CodexSession.Status.running,
            .idle,
            .queued,
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
