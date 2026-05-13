import Foundation
import Testing
@testable import OS1

/// Acceptance-criteria tests for issue #146 — one named test per bullet.
///
/// The existing `CompanyApprovalTests` suite covers schema round-tripping and
/// the high-level queue plan. This file adds **per-AC** named tests that map
/// 1:1 to the issue body, plus tests for the constructive helpers that wire
/// the in-memory plan into real handling (auto-policy creation, batch
/// resolution, stale-request expiry, notification dispatch, policy store).
struct CompanyApprovalQueueACTests {

    // MARK: AC1 — Risk-tier score on every approval request

    @Test
    func ac1_riskTierIsRequiredOnEveryRequest() throws {
        // The Swift type system enforces population at the call site; on the wire,
        // decoding a request that omits `riskTier` must fail.
        let missingRiskTier = #"""
        {
          "id": "r-1",
          "companyID": "co-1",
          "requestedAt": "2026-05-13T00:00:00Z",
          "actor": "codex",
          "proposedAction": "Send email",
          "expectedEffect": "Email sent",
          "rollbackPlan": "Recall email",
          "status": "pending"
        }
        """#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(throws: (any Error).self) {
            _ = try decoder.decode(CompanyApprovalRequest.self, from: Data(missingRiskTier.utf8))
        }

        for tier in CompanyApprovalRequest.RiskTier.allCases {
            let req = CompanyApprovalRequest(
                companyID: "co-1",
                riskTier: tier,
                proposedAction: "Send email",
                expectedEffect: "Email goes out",
                rollbackPlan: "Recall"
            )
            #expect(req.riskTier == tier)
        }
    }

    // MARK: AC2 — Auto-approve policy fires after N approvals in window

    @Test
    func ac2_autoApprovePolicyCreatedAfterThresholdAndAppliesToFutureMatches() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let candidate = request(
            id: "candidate",
            companyID: "validated-7",
            riskTier: .low,
            proposedAction: "Send customer email",
            requestedAt: now
        )
        let priors = (0..<3).map { i -> CompanyApprovalRequest in
            var r = request(
                id: "prior-\(i)",
                companyID: "validated-\(i)",
                riskTier: .low,
                proposedAction: "Send customer email",
                requestedAt: now.addingTimeInterval(-Double(i + 1) * 3_600)
            )
            r.status = .approved
            return r
        }
        let policy = CompanyApprovalQueueEngine.autoCreatePolicyIfEligible(
            request: candidate,
            priorApprovals: priors,
            revocationCount: 0,
            threshold: 3,
            windowDays: 14,
            since: now.addingTimeInterval(-14 * 86_400),
            createdBy: "operator@os1",
            now: now,
            policyID: "pol-ac2"
        )
        let policyUnwrapped = try? #require(policy)
        #expect(policyUnwrapped?.companyPattern == "validated-*")
        #expect(policyUnwrapped?.actionType == "outbound_message")
        #expect(policyUnwrapped?.riskTier == .low)
        #expect(policyUnwrapped?.createdBy == "operator@os1")
        #expect(policyUnwrapped?.isRevoked == false)

        let plan = CompanyApprovalQueueEngine.plan(
            requests: [candidate],
            policies: [policyUnwrapped!],
            now: now
        )
        #expect(plan.items.first?.status == .approved)
        #expect(plan.items.first?.approvalMode == "auto")
        #expect(plan.items.first?.event?.metadata["approval_mode"] == "auto")

        // Threshold not reached → no policy.
        let notYet = CompanyApprovalQueueEngine.autoCreatePolicyIfEligible(
            request: candidate,
            priorApprovals: Array(priors.prefix(2)),
            revocationCount: 0,
            threshold: 3,
            windowDays: 14,
            since: now.addingTimeInterval(-14 * 86_400),
            createdBy: "operator@os1",
            now: now
        )
        #expect(notYet == nil)
    }

    // MARK: AC3 — Single-click batch decision resolves every matching item

    @Test
    func ac3_singleClickBatchApproveResolvesAllMatchingPendingItems() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let batch = (0..<5).map { i in
            request(
                id: "tweet-\(i)",
                companyID: "validated-\(i)",
                riskTier: .high,
                proposedAction: "post_tweet launch update \(i)",
                requestedAt: now.addingTimeInterval(-300)
            )
        }
        let unrelated = request(
            id: "email-1",
            companyID: "validated-9",
            riskTier: .medium,
            proposedAction: "Send customer email",
            requestedAt: now.addingTimeInterval(-300)
        )
        let plan = CompanyApprovalQueueEngine.plan(
            requests: batch + [unrelated],
            policies: [],
            now: now
        )
        let batchKey = "post_tweet|high"
        #expect(plan.batches[batchKey]?.count == 5)

        let outcome = CompanyApprovalQueueEngine.applyBatchDecision(
            plan: plan,
            batchKey: batchKey,
            decision: .approve,
            decidedBy: "operator@os1",
            now: now
        )
        #expect(outcome.resolvedRequestIDs.count == 5)
        #expect(outcome.resolvedRequestIDs == batch.map(\.id).sorted())
        #expect(outcome.events.count == 5)
        #expect(outcome.events.allSatisfy { $0.metadata["approval_mode"] == "batch_approve" })
        #expect(outcome.events.allSatisfy { $0.metadata["batch_key"] == batchKey })
        // The unrelated outbound_message|medium request is untouched.
        #expect(!outcome.resolvedRequestIDs.contains("email-1"))
    }

    // MARK: AC4 — Auto-expire stale requests, release lease, pause company

    @Test
    func ac4_staleRequestExpiresReleasesLeaseAndPausesCompany() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let fresh = request(
            id: "fresh",
            companyID: "co-fresh",
            riskTier: .medium,
            proposedAction: "Send customer email",
            requestedAt: now.addingTimeInterval(-3_600)
        )
        let stale = request(
            id: "stale",
            companyID: "co-stale",
            riskTier: .high,
            proposedAction: "post_tweet outdated launch",
            requestedAt: now.addingTimeInterval(-90_000) // > 24h ago
        )
        let outcomes = CompanyApprovalQueueEngine.expireStale(
            requests: [fresh, stale],
            now: now,
            expirySeconds: 86_400,
            leaseReleaseSeconds: 60
        )
        #expect(outcomes.count == 1)
        let outcome = outcomes[0]
        #expect(outcome.expiredRequest.id == "stale")
        #expect(outcome.expiredRequest.status == .expired)
        #expect(outcome.expiredRequest.decidedAt == now)
        #expect(outcome.leaseReleaseDeadline == now.addingTimeInterval(60))
        #expect(outcome.pausedCompanyState == "paused_awaiting_review")
        #expect(outcome.event.kind == .approvalDenied)
        #expect(outcome.event.approvalState == "expired")
        #expect(outcome.event.metadata["approval_mode"] == "expired")
        #expect(outcome.event.metadata["company_state"] == "paused_awaiting_review")
    }

    // MARK: AC5 — Push routing per risk tier

    @Test
    func ac5_pushRoutingRoutesByRiskTier() {
        let now = Date(timeIntervalSince1970: 1_800_003_600) // exactly 1h past epoch+anchor
        let requests = [
            request(id: "low-1", riskTier: .low, proposedAction: "Draft locally", requestedAt: now),
            request(id: "med-1", riskTier: .medium, proposedAction: "Send customer email", requestedAt: now),
            request(id: "hi-1", riskTier: .high, proposedAction: "post_tweet announcement", requestedAt: now),
            request(id: "crit-1", riskTier: .critical, proposedAction: "Wire $5000 to vendor", requestedAt: now)
        ]
        let plan = CompanyApprovalQueueEngine.plan(requests: requests, policies: [], now: now)
        let notifications = CompanyApprovalQueueEngine.dispatchNotifications(
            plan: plan,
            requests: requests,
            now: now
        )
        let byChannel = Dictionary(grouping: notifications, by: { $0.channel })
        #expect(byChannel[.immediate]?.count == 2) // high + critical
        #expect(byChannel[.hourlyDigest]?.count == 1)
        #expect(byChannel[.dailyDigest]?.count == 1)

        let immediate = byChannel[.immediate]!
        #expect(immediate.allSatisfy { $0.scheduledFor == now })

        let hourly = byChannel[.hourlyDigest]!.first!
        #expect(hourly.scheduledFor > now)
        #expect(hourly.scheduledFor.timeIntervalSince(now) <= 3_600)

        let daily = byChannel[.dailyDigest]!.first!
        #expect(daily.scheduledFor.timeIntervalSince(now) <= 86_400)
    }

    // MARK: AC6 — Revocation flips future matches back to manual

    @Test
    func ac6_revokingPolicyFlipsFutureMatchesBackToManualWithinOneSecond() throws {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("approval-\(UUID().uuidString).json")
        let store = CompanyApprovalPolicyStore(url: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let policy = CompanyApprovalQueueEngine.appendOnlyPolicy(
            id: "pol-ac6",
            createdBy: "operator@os1",
            companyPattern: "validated-*",
            actionType: "post_tweet",
            riskTier: .high,
            createdAt: now
        )
        try store.append(policy)
        let loaded = try store.load()
        #expect(loaded.count == 1)
        #expect(loaded[0].isRevoked == false)

        let req = request(
            id: "rev-1",
            companyID: "validated-3",
            riskTier: .high,
            proposedAction: "post_tweet new launch",
            requestedAt: now
        )
        let beforeRevocation = CompanyApprovalQueueEngine.plan(
            requests: [req],
            policies: try store.load(),
            now: now
        )
        #expect(beforeRevocation.items.first?.approvalMode == "auto")

        // Revoke and re-plan one second later (ISO8601 storage strips sub-seconds,
        // so use whole-second offsets in the assertion).
        let revokedAt = now.addingTimeInterval(1)
        _ = try store.revoke(id: "pol-ac6", at: revokedAt, reason: "Spotted a misfire")
        let afterRevocation = CompanyApprovalQueueEngine.plan(
            requests: [req],
            policies: try store.load(),
            now: now.addingTimeInterval(2)
        )
        #expect(afterRevocation.items.first?.approvalMode == "manual")
        #expect(afterRevocation.items.first?.route == "immediate")

        // Audit trail intact: createdBy/createdAt preserved, revokedAt/revocationReason populated.
        let final = try store.load().first!
        #expect(final.id == "pol-ac6")
        #expect(final.createdBy == "operator@os1")
        #expect(final.createdAt == now)
        #expect(final.revokedAt == revokedAt)
        #expect(final.revocationReason?.contains("misfire") == true)
    }

    // MARK: - Scale fixture from the issue body

    @Test
    func operatorClears100MixedRiskApprovalsUnderFiveMinutes() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let requests: [CompanyApprovalRequest] = (0..<100).map { i in
            let tier: CompanyApprovalRequest.RiskTier
            let action: String
            switch i % 4 {
            case 0:  tier = .high;     action = "post_tweet launch \(i)"
            case 1:  tier = .medium;   action = "Send customer email \(i)"
            case 2:  tier = .low;      action = "Send daily digest \(i)"
            default: tier = .critical; action = "Wire payment \(i)"
            }
            return request(
                id: "scale-\(i)",
                companyID: i % 3 == 0 ? "validated-\(i)" : "experimental-\(i)",
                riskTier: tier,
                proposedAction: action,
                requestedAt: now.addingTimeInterval(-300)
            )
        }
        let plan = CompanyApprovalQueueEngine.plan(requests: requests, policies: [], now: now)
        #expect(plan.items.count == 100)
        #expect(plan.estimatedClearSeconds <= 300)
        #expect(plan.batches.values.contains { $0.count > 1 }) // at least one batch consolidates work
    }

    // MARK: - Helpers

    private func request(
        id: String,
        companyID: String = "co-1",
        riskTier: CompanyApprovalRequest.RiskTier,
        proposedAction: String,
        requestedAt: Date
    ) -> CompanyApprovalRequest {
        CompanyApprovalRequest(
            id: id,
            companyID: companyID,
            requestedAt: requestedAt,
            actor: "codex",
            riskTier: riskTier,
            proposedAction: proposedAction,
            expectedEffect: "Action completes",
            rollbackPlan: "Undo",
            status: .pending
        )
    }
}
