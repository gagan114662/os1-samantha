import Foundation
import Testing
@testable import OS1

struct CompanyOperationsInfrastructureTests {
    @Test
    func domainPurchaseHostingAndWebsiteHealthAreDeterministic() throws {
        let proposals = DomainRegistrationService.proposals(
            companyID: "co",
            domain: "Example.com",
            fixtures: [.namecheap: (true, 12), .porkbun: (true, 9)]
        )
        let purchase = DomainRegistrationService.purchase(proposal: proposals[0], approved: true, at: Date(timeIntervalSince1970: 0))
        let deploy = CompanyHostingAdapter.createProject(
            companyID: "co",
            provider: .cloudflarePages,
            repoURL: URL(string: "https://github.com/acme/site")!,
            commitSHA: "abcdef123456",
            at: Date(timeIntervalSince1970: 1)
        )
        let website = CompanyWebsite(
            id: "site",
            companyID: "co",
            domain: purchase.domain,
            deployment: deploy,
            templateID: CompanySiteTemplate.saasMarketing.rawValue,
            lastDeployAt: deploy.deployedAt,
            dnsHealth: deploy.dnsHealthy ? "healthy" : "failing"
        )

        #expect(proposals.map(\.registrar) == [.porkbun, .namecheap])
        #expect(purchase.ledgerEntry?.kind == .cost)
        #expect(purchase.event.approvalState == "approved")
        #expect(website.deployment?.deployURL.host() == "co.pages.dev")
        #expect(website.dnsHealth == "healthy")
    }

    @Test
    func inAppCronHonorsTimezoneMissesPauseSandboxAndPersistence() throws {
        let now = Date(timeIntervalSince1970: 1_000)
        let schedule = CompanySchedule(
            id: "s1",
            companyID: "co",
            name: "watcher",
            expression: .interval(seconds: 2),
            enabled: true,
            nextRunAt: now.addingTimeInterval(-600),
            lastRunAt: nil,
            lastRunResult: nil,
            payload: .watcherScan,
            catchUpMissedRuns: false
        )
        let due = InAppCronScheduler.dueSchedules([schedule], now: now, pausedCompanyIDs: [], sandboxAllowedCompanyIDs: ["co"])
        let future = InAppCronScheduler.nextRun(after: now, expression: .cron(minute: 30, hour: 9, timezoneID: "America/Toronto"))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("os1-schedules-\(UUID().uuidString).json")
        let restored = try InAppCronScheduler.persistedRoundTrip([schedule], at: url)

        #expect(due.ready.isEmpty)
        #expect(due.missedEvents.count == 1)
        #expect(future > now)
        #expect(restored.first?.payload == .watcherScan)
    }

    @Test
    func senderWarmupDeliverabilityAndHealthBlockUnsafeOutreach() {
        let first = Date(timeIntervalSince1970: 0)
        let now = first.addingTimeInterval(3 * 86_400)
        var sender = CompanySender(
            id: "sender",
            companyID: "co",
            kind: .email,
            senderIdentifier: "sales@example.com",
            warmupState: .newAccount,
            dailyLimit: 100,
            dailySent: 8,
            weeklySent: 20,
            replyRate: 0.05,
            bounceRate: 0,
            complaintRate: 0,
            firstSentAt: first,
            lastSentAt: first,
            consecutiveBouncesSinceReply: 0,
            verified: SenderHealthMonitor.verifyEmailDNS(spf: "v=spf1 include:_spf.example", dkim: "k=rsa; p=abc", dmarc: "v=DMARC1; p=quarantine")
        )

        #expect(SenderRampScheduler.allowedDailyVolume(sender: sender, now: now) == 8)
        #expect(SenderHealthMonitor.blocksSend(sender: sender, now: now).blocked)
        sender.dailySent = 1
        #expect(!SenderHealthMonitor.blocksSend(sender: sender, now: now).blocked)
        let paused = SenderHealthMonitor.updated(sender: sender, bounceEvents: 5, complaintEvents: 0, replies: 0)
        #expect(paused.warmupState == .paused)
    }

    @Test
    func crmDedupeAndSupportRunnerRouteInboundWork() {
        let shared = contact(companyID: "sibling", email: "lead@example.com")
        let duplicate = CompanyCRMSyncService.upsertInbound(
            companyID: "co",
            email: "lead@example.com",
            name: "Lead",
            source: "form",
            existing: [],
            sharedPool: [shared]
        )
        let ticket = CompanySupportInboxItem(
            id: "t1",
            companyID: "co",
            channel: .email,
            from: "buyer@example.com",
            subject: "Refund",
            body: "I need a refund for invoice 123",
            category: CompanySupportRunner.classify("I need a refund for invoice 123"),
            priority: .urgent,
            state: .open,
            firstResponseDueBy: Date(),
            lastResponseAt: nil,
            paymentReference: "pi_123"
        )
        let route = CompanySupportRunner.route(ticket: ticket)
        let reply = CompanySupportRunner.draft(ticket: ticket, knowledgeBase: nil)

        #expect(duplicate == .duplicate(existingCompanyID: "sibling"))
        #expect(route.handoff == "payments-refund")
        #expect(reply.approvalState == .approvalRequired)
    }

    private func contact(companyID: String, email: String) -> CompanyCRMContact {
        CompanyCRMContact(
            id: UUID().uuidString,
            companyID: companyID,
            accountID: nil,
            email: email,
            name: "Lead",
            source: .init(source: "fixture", capturedAt: Date(), campaignID: nil, evidenceURL: nil),
            consentBasis: .legitimateInterest,
            lifecycleStage: .lead,
            owner: "os1",
            notes: "",
            linkedLedgerEntryIDs: [],
            linkedSupportTicketIDs: [],
            linkedCampaignEventIDs: [],
            deletedAt: nil
        )
    }
}
