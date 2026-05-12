import Foundation

enum DomainRegistrar: String, Codable, CaseIterable, Hashable {
    case namecheap
    case porkbun
    case cloudflare
}

enum HostingProvider: String, Codable, CaseIterable, Hashable {
    case vercel
    case cloudflarePages
    case netlify
    case render
    case fly
}

struct CompanyDomainProposal: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var registrar: DomainRegistrar
    var domain: String
    var available: Bool
    var priceUSD: Double
    var renewsAt: Date?
}

struct CompanyDomain: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var registrar: DomainRegistrar
    var domain: String
    var purchasedAt: Date
    var renewsAt: Date
    var autoRenew: Bool
    var priceUSD: Double
    var whoisPrivacy: Bool
    var approvalState: CompanyGrowthCampaign.ApprovalState
}

struct CompanyHostingDeployment: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var provider: HostingProvider
    var repoURL: URL
    var commitSHA: String
    var deployURL: URL
    var deployedAt: Date
    var dnsHealthy: Bool
}

struct CompanyWebsite: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var domain: CompanyDomain?
    var deployment: CompanyHostingDeployment?
    var templateID: String
    var lastDeployAt: Date?
    var dnsHealth: String
}

enum DomainRegistrationService {
    static func proposals(
        companyID: String,
        domain: String,
        fixtures: [DomainRegistrar: (available: Bool, priceUSD: Double)]
    ) -> [CompanyDomainProposal] {
        fixtures.map { registrar, fixture in
            CompanyDomainProposal(
                id: "\(companyID)-\(registrar.rawValue)-\(domain)",
                companyID: companyID,
                registrar: registrar,
                domain: domain.lowercased(),
                available: fixture.available,
                priceUSD: fixture.priceUSD,
                renewsAt: nil
            )
        }
        .sorted { $0.priceUSD < $1.priceUSD }
    }

    static func purchase(
        proposal: CompanyDomainProposal,
        approved: Bool,
        at date: Date = Date()
    ) -> (domain: CompanyDomain?, ledgerEntry: CompanyLedgerEntry?, event: CompanyEvent) {
        let requiresApproval = !approved
        let event = CompanyEvent(
            occurredAt: date,
            companyID: proposal.companyID,
            kind: requiresApproval ? .approvalRequested : .ledgerEntryRecorded,
            summary: requiresApproval
                ? "Domain purchase requires approval for \(proposal.domain)"
                : "Domain purchased through \(proposal.registrar.rawValue)",
            costUSD: proposal.priceUSD,
            approvalState: requiresApproval ? "approval-required" : "approved",
            metadata: ["domain": proposal.domain, "registrar": proposal.registrar.rawValue]
        )
        guard approved, proposal.available else { return (nil, nil, event) }
        let domain = CompanyDomain(
            id: proposal.id,
            companyID: proposal.companyID,
            registrar: proposal.registrar,
            domain: proposal.domain,
            purchasedAt: date,
            renewsAt: date.addingTimeInterval(365 * 86_400),
            autoRenew: true,
            priceUSD: proposal.priceUSD,
            whoisPrivacy: true,
            approvalState: .approved
        )
        let ledger = CompanyLedgerEntry(
            id: "domain-\(proposal.id)",
            companyID: proposal.companyID,
            occurredAt: date,
            kind: .cost,
            category: .purchases,
            amountUSD: proposal.priceUSD,
            source: "domain-registration",
            sourceEventID: event.id,
            sourceReference: proposal.domain,
            confidence: .verified,
            note: "domain=\(proposal.domain) registrar=\(proposal.registrar.rawValue)"
        )
        return (domain, ledger, event)
    }
}

enum CompanyHostingAdapter {
    static func createProject(
        companyID: String,
        provider: HostingProvider,
        repoURL: URL,
        commitSHA: String,
        at date: Date = Date()
    ) -> CompanyHostingDeployment {
        let host = provider == .cloudflarePages ? "pages.dev" : "\(provider.rawValue).app"
        let slug = companyID.lowercased().replacingOccurrences(of: "_", with: "-")
        return CompanyHostingDeployment(
            id: "\(provider.rawValue)-\(companyID)-\(commitSHA.prefix(8))",
            companyID: companyID,
            provider: provider,
            repoURL: repoURL,
            commitSHA: commitSHA,
            deployURL: URL(string: "https://\(slug).\(host)")!,
            deployedAt: date,
            dnsHealthy: true
        )
    }
}

enum CompanySiteTemplate: String, Codable, CaseIterable, Hashable {
    case localLeadgenPages
    case affiliateComparison
    case saasMarketing
    case newsletterLanding
}

struct CompanySchedule: Codable, Hashable, Identifiable {
    enum Expression: Codable, Hashable {
        case interval(seconds: TimeInterval)
        case cron(minute: Int, hour: Int, timezoneID: String)
    }

    enum Payload: String, Codable, CaseIterable, Hashable {
        case heartbeat
        case watcherScan
        case analyticsSync
        case newsletterSend
        case redirectorCacheRotation
    }

    let id: String
    var companyID: String
    var name: String
    var expression: Expression
    var enabled: Bool
    var nextRunAt: Date
    var lastRunAt: Date?
    var lastRunResult: String?
    var payload: Payload
    var catchUpMissedRuns: Bool
}

enum InAppCronScheduler {
    static func nextRun(after date: Date, expression: CompanySchedule.Expression) -> Date {
        switch expression {
        case .interval(let seconds):
            return date.addingTimeInterval(seconds)
        case .cron(let minute, let hour, let timezoneID):
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = TimeZone(identifier: timezoneID) ?? .current
            var components = calendar.dateComponents([.year, .month, .day], from: date)
            components.hour = hour
            components.minute = minute
            components.second = 0
            let candidate = calendar.date(from: components) ?? date
            return candidate > date ? candidate : calendar.date(byAdding: .day, value: 1, to: candidate) ?? date
        }
    }

    static func dueSchedules(
        _ schedules: [CompanySchedule],
        now: Date,
        pausedCompanyIDs: Set<String>,
        sandboxAllowedCompanyIDs: Set<String>
    ) -> (ready: [CompanySchedule], missedEvents: [CompanyEvent]) {
        var missed: [CompanyEvent] = []
        let ready = schedules.filter { schedule in
            guard schedule.enabled else { return false }
            guard !pausedCompanyIDs.contains(schedule.companyID) else { return false }
            guard sandboxAllowedCompanyIDs.contains(schedule.companyID) else { return false }
            if schedule.nextRunAt < now.addingTimeInterval(-300), !schedule.catchUpMissedRuns {
                missed.append(CompanyEvent(companyID: schedule.companyID, kind: .heartbeatQueued, summary: "Missed scheduled run for \(schedule.name)", metadata: ["scheduleID": schedule.id]))
                return false
            }
            return schedule.nextRunAt <= now
        }
        return (ready, missed)
    }

    static func persistedRoundTrip(_ schedules: [CompanySchedule], at url: URL) throws -> [CompanySchedule] {
        let data = try JSONEncoder().encode(schedules)
        try data.write(to: url, options: .atomic)
        return try JSONDecoder().decode([CompanySchedule].self, from: Data(contentsOf: url))
    }
}

struct CompanySender: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case email
        case linkedinDM
        case igDM
        case fbDM
        case tiktokDM
        case twitterDM
        case smsTextMagic
        case agentMail
    }

    enum WarmupState: String, Codable, CaseIterable, Hashable {
        case newAccount
        case ramping
        case healthy
        case paused
        case banned
    }

    let id: String
    var companyID: String
    var kind: Kind
    var senderIdentifier: String
    var warmupState: WarmupState
    var dailyLimit: Int
    var dailySent: Int
    var weeklySent: Int
    var replyRate: Double
    var bounceRate: Double
    var complaintRate: Double
    var firstSentAt: Date?
    var lastSentAt: Date?
    var consecutiveBouncesSinceReply: Int
    var verified: Bool
}

enum SenderRampScheduler {
    static func allowedDailyVolume(sender: CompanySender, now: Date) -> Int {
        guard let firstSentAt = sender.firstSentAt else { return min(1, sender.dailyLimit) }
        let days = max(0, Int(now.timeIntervalSince(firstSentAt) / 86_400))
        let ramp = Int(pow(2.0, Double(days)))
        return min(sender.dailyLimit, max(1, ramp))
    }
}

enum SenderHealthMonitor {
    static func updated(sender: CompanySender, bounceEvents: Int, complaintEvents: Int, replies: Int) -> CompanySender {
        var copy = sender
        copy.consecutiveBouncesSinceReply = replies > 0 ? 0 : sender.consecutiveBouncesSinceReply + bounceEvents
        let denominator = max(1, sender.dailySent)
        copy.bounceRate = Double(bounceEvents) / Double(denominator)
        copy.complaintRate = Double(complaintEvents) / Double(denominator)
        if copy.complaintRate > 0.02 || copy.bounceRate > 0.08 || copy.consecutiveBouncesSinceReply >= 3 {
            copy.warmupState = .paused
        } else if copy.verified && copy.warmupState == .newAccount {
            copy.warmupState = .ramping
        }
        return copy
    }

    static func verifyEmailDNS(spf: String?, dkim: String?, dmarc: String?) -> Bool {
        spf?.contains("v=spf1") == true &&
            dkim?.contains("k=rsa") == true &&
            dmarc?.contains("v=DMARC1") == true
    }

    static func blocksSend(sender: CompanySender, now: Date = Date()) -> (blocked: Bool, reason: String?) {
        guard sender.verified else { return (true, "sender is not verified") }
        guard sender.warmupState != .paused && sender.warmupState != .banned else {
            return (true, "sender warmup state is \(sender.warmupState.rawValue)")
        }
        if sender.dailySent >= SenderRampScheduler.allowedDailyVolume(sender: sender, now: now) {
            return (true, "sender would exceed warmup ramp")
        }
        return (false, nil)
    }
}

struct CompanyDeal: Codable, Hashable, Identifiable {
    enum Stage: String, Codable, CaseIterable, Hashable {
        case new
        case contacted
        case qualified
        case booked
        case won
        case lost
    }

    let id: String
    var companyID: String
    var contactEmail: String
    var valueUSD: Double
    var stage: Stage
    var source: String
    var lastSyncedAt: Date?
}

enum CompanyCRMSyncService {
    enum AddResult: Equatable {
        case added(CompanyCRMContact)
        case duplicate(existingCompanyID: String)
    }

    static func upsertInbound(
        companyID: String,
        email: String,
        name: String,
        source: String,
        existing: [CompanyCRMContact],
        sharedPool: [CompanyCRMContact],
        at date: Date = Date()
    ) -> AddResult {
        let normalized = email.lowercased()
        if let duplicate = sharedPool.first(where: { $0.normalizedEmail == normalized && $0.companyID != companyID }) {
            return .duplicate(existingCompanyID: duplicate.companyID)
        }
        let contact = existing.first(where: { $0.normalizedEmail == normalized }) ?? CompanyCRMContact(
            id: UUID().uuidString,
            companyID: companyID,
            accountID: nil,
            email: email,
            name: name,
            source: .init(source: source, capturedAt: date, campaignID: nil, evidenceURL: nil),
            consentBasis: .legitimateInterest,
            lifecycleStage: .lead,
            owner: "samantha",
            notes: "inbound sync",
            linkedLedgerEntryIDs: [],
            linkedSupportTicketIDs: [],
            linkedCampaignEventIDs: [],
            deletedAt: nil
        )
        return .added(contact)
    }

    static func markWon(deal: CompanyDeal, paymentReference: String, at date: Date = Date()) -> (CompanyDeal, CompanyEvent) {
        var copy = deal
        copy.stage = .won
        copy.lastSyncedAt = date
        return (
            copy,
            CompanyEvent(
                occurredAt: date,
                companyID: deal.companyID,
                kind: .ledgerEntryRecorded,
                summary: "CRM deal marked won",
                metadata: ["dealID": deal.id, "paymentReference": paymentReference]
            )
        )
    }
}

struct CompanySupportInboxItem: Codable, Hashable, Identifiable {
    enum Channel: String, Codable, CaseIterable, Hashable {
        case email
        case igDM
        case fbDM
        case twitterDM
        case linkedinDM
        case websiteForm
        case ticketingSystem
    }

    enum Category: String, Codable, CaseIterable, Hashable {
        case refund
        case deliveryIssue
        case productQuestion
        case bug
        case billing
        case abuse
        case other
    }

    enum State: String, Codable, CaseIterable, Hashable {
        case open
        case awaitingApproval
        case awaitingCustomer
        case resolved
        case escalated
    }

    let id: String
    var companyID: String
    var channel: Channel
    var from: String
    var subject: String
    var body: String
    var category: Category
    var priority: CompanySupportTicket.Priority
    var state: State
    var firstResponseDueBy: Date
    var lastResponseAt: Date?
    var paymentReference: String?
}

enum CompanySupportRunner {
    static func classify(_ body: String) -> CompanySupportInboxItem.Category {
        let lower = body.lowercased()
        if lower.contains("refund") { return .refund }
        if lower.contains("download") || lower.contains("access") { return .deliveryIssue }
        if lower.contains("bug") || lower.contains("broken") { return .bug }
        if lower.contains("charge") || lower.contains("invoice") { return .billing }
        if lower.contains("abuse") || lower.contains("threat") { return .abuse }
        if lower.contains("?") { return .productQuestion }
        return .other
    }

    static func draft(ticket: CompanySupportInboxItem, knowledgeBase: CompanyKnowledgeBase?) -> CompanySupportReply {
        let grounding = knowledgeBase?.chunks.first?.text ?? "Thanks for reaching out. We are reviewing this and will follow up shortly."
        let body = "Hi, \(grounding.prefix(220))"
        let requiresApproval = ticket.category == .refund || ticket.category == .billing || ticket.category == .abuse
        return CompanySupportReply(
            id: "reply-\(ticket.id)",
            ticketID: ticket.id,
            customerID: ticket.from,
            draftedBy: "samantha",
            body: body,
            loggedAt: Date(),
            approvalState: requiresApproval ? .approvalRequired : .draft
        )
    }

    static func route(ticket: CompanySupportInboxItem) -> (state: CompanySupportInboxItem.State, handoff: String?) {
        switch ticket.category {
        case .refund:
            return (.awaitingApproval, "payments-refund")
        case .abuse:
            return (.escalated, "abuse-containment")
        case .billing:
            return (.awaitingApproval, "billing-review")
        default:
            return (.awaitingCustomer, nil)
        }
    }
}
