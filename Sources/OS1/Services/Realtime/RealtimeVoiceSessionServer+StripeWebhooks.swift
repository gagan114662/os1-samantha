import Foundation

extension RealtimeVoiceSessionServer {
    @MainActor
    func stripeWebhookResponse(
        request: HTTPRequest,
        manager: CodexSessionManager = .shared,
        endpointSecretProvider: () -> String? = {
            ProcessInfo.processInfo.environment["STRIPE_WEBHOOK_SECRET"]
                ?? PaymentCredentialStore.shared.loadSecret(.stripeWebhookSecret)
        },
        seenEventStore: PaymentWebhookSeenEventStore? = nil,
        now: Date = Date()
    ) -> HTTPResponse {
        guard let endpointSecret = endpointSecretProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !endpointSecret.isEmpty else {
            return .jsonDict([
                "ok": false,
                "error": "Stripe webhook secret is not configured. Set STRIPE_WEBHOOK_SECRET or save a Stripe webhook secret in Payments."
            ], status: 400)
        }

        do {
            try PaymentWebhookReceiver.verifyStripeSignature(
                payload: request.body,
                signatureHeader: request.headers["stripe-signature"],
                endpointSecret: endpointSecret,
                now: now
            )
            let routedEvent = try PaymentWebhookReceiver.stripe(payload: request.body, receivedAt: now)
            guard !routedEvent.companyID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return .jsonDict([
                    "ok": false,
                    "error": "Stripe event metadata.company_id is required"
                ], status: 400)
            }

            let entry = try manager.recordStripeWebhook(
                companyID: routedEvent.companyID,
                payload: request.body,
                signatureHeader: request.headers["stripe-signature"],
                endpointSecret: endpointSecret,
                seenEventStore: seenEventStore,
                now: now
            )

            return .jsonDict([
                "ok": true,
                "provider": "stripe",
                "event_id": routedEvent.id,
                "event_type": routedEvent.metadata?["stripe_event_type"] ?? routedEvent.kind.rawValue,
                "company_id": routedEvent.companyID,
                "ledger_entry_id": entry.id,
                "amount_usd": entry.amountUSD,
                "source_reference": entry.sourceReference ?? ""
            ])
        } catch let error as PaymentWebhookReceiver.Error {
            return .jsonDict([
                "ok": false,
                "error": Self.publicStripeWebhookError(error)
            ], status: Self.statusCode(for: error))
        } catch {
            return .jsonDict([
                "ok": false,
                "error": "Stripe webhook could not be processed"
            ], status: 400)
        }
    }

    func stripeStatusResponse(
        endpointSecretProvider: () -> String? = {
            ProcessInfo.processInfo.environment["STRIPE_WEBHOOK_SECRET"]
                ?? PaymentCredentialStore.shared.loadSecret(.stripeWebhookSecret)
        }
    ) -> HTTPResponse {
        let configured = endpointSecretProvider()?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        return .jsonDict([
            "ok": true,
            "provider": "stripe",
            "endpoint": "/webhooks/stripe",
            "webhook_secret_configured": configured
        ])
    }

    private static func statusCode(for error: PaymentWebhookReceiver.Error) -> Int {
        switch error {
        case .paymentsCapabilityNotGranted:
            return 403
        default:
            return 400
        }
    }

    private static func publicStripeWebhookError(_ error: PaymentWebhookReceiver.Error) -> String {
        switch error {
        case .paymentsCapabilityNotGranted(let companyID):
            return "Company \(companyID) is not allowed to ingest Stripe payments"
        case .missingSignatureHeader:
            return "Stripe-Signature header is required"
        case .invalidSignatureHeader:
            return "Stripe-Signature header is malformed"
        case .timestampOutsideTolerance:
            return "Stripe-Signature timestamp is outside tolerance"
        case .signatureMismatch:
            return "Stripe signature verification failed"
        case .replayedEvent(let eventID):
            return "Stripe event \(eventID) was already processed"
        case .companyIDMismatch(let expected, let actual):
            return "Stripe event company_id mismatch: expected \(expected), got \(actual)"
        }
    }
}
