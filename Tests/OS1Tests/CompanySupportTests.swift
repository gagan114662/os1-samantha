import Foundation
import Testing
@testable import OS1

struct CompanySupportTests {
    @Test
    func supportReadinessRequiresContactEscalationRefundAndCancellation() {
        let readiness = CompanySupportOperations.readiness(config: nil)

        #expect(!readiness.canLaunch)
        #expect(readiness.blockers.contains("Support contact and escalation policy are required before launch."))
    }

    @Test
    func dashboardCountsOpenTicketsSlaBreachesRefundsAndEscalations() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let tickets = [
            ticket(status: .open, priority: .high, dueAt: now.addingTimeInterval(-60)),
            ticket(status: .escalated, priority: .urgent, dueAt: now.addingTimeInterval(3600)),
            ticket(status: .closed, priority: .normal, dueAt: now.addingTimeInterval(-60))
        ]
        let refund = CompanyRefundWorkflow(
            id: "refund-1",
            companyID: "company-1",
            ticketID: "ticket-1",
            paymentID: "pi_1",
            amountUSD: 20,
            reason: "customer request",
            status: .approvalRequired,
            approvalRequestID: "approval-1"
        )
        let reply = CompanySupportReply(
            id: "reply-1",
            ticketID: "ticket-1",
            customerID: "customer-1",
            draftedBy: "samantha",
            body: "We can help.",
            loggedAt: now,
            approvalState: .draft
        )

        let dashboard = CompanySupportOperations.dashboard(
            companyID: "company-1",
            tickets: tickets,
            replies: [reply],
            refunds: [refund],
            now: now
        )

        #expect(dashboard.openTickets == 2)
        #expect(dashboard.slaBreaches == 1)
        #expect(dashboard.refundsPending == 1)
        #expect(dashboard.escalations == 1)
        #expect(dashboard.loggedReplies == 1)
    }

    @Test
    func refundsAndRiskyRepliesRequireApproval() {
        let refund = CompanyRefundWorkflow(
            id: "refund-1",
            companyID: "company-1",
            ticketID: "ticket-1",
            paymentID: "pi_1",
            amountUSD: 20,
            reason: "duplicate charge",
            status: .drafted,
            approvalRequestID: nil
        )

        #expect(CompanySupportOperations.refundRequiresApproval(refund))
        #expect(CompanySupportOperations.replyApprovalState(for: "We will refund this charge.") == .approvalRequired)
        #expect(CompanySupportOperations.replyApprovalState(for: "Thanks, we are checking this.") == .draft)
    }

    private func ticket(
        status: CompanySupportTicket.Status,
        priority: CompanySupportTicket.Priority,
        dueAt: Date
    ) -> CompanySupportTicket {
        CompanySupportTicket(
            id: UUID().uuidString,
            companyID: "company-1",
            customerID: "customer-1",
            customerEmail: "buyer@example.com",
            subject: "Help",
            status: status,
            priority: priority,
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            dueAt: dueAt,
            linkedPaymentID: "pi_1",
            linkedProductArea: "checkout",
            escalationReason: status == .escalated ? "angry customer" : nil
        )
    }
}
