import Foundation

protocol StripeCheckoutHTTPClient: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: StripeCheckoutHTTPClient {}

enum StripeCheckoutSessionError: LocalizedError, Equatable {
    case missingTestKey
    case liveKeyRejected
    case invalidAmount
    case invalidResponse
    case stripeRejected(Int, String)
    case missingCheckoutURL

    var errorDescription: String? {
        switch self {
        case .missingTestKey:
            return "Save a Stripe test secret key in Connectors before generating a sandbox checkout link."
        case .liveKeyRejected:
            return "Sandbox checkout generation only accepts Stripe test keys that start with sk_test_."
        case .invalidAmount:
            return "Enter a positive checkout amount."
        case .invalidResponse:
            return "Stripe returned a non-HTTP response."
        case .stripeRejected(let status, let body):
            return "Stripe rejected the checkout session request (HTTP \(status)): \(body)"
        case .missingCheckoutURL:
            return "Stripe created a session without a checkout URL."
        }
    }
}

struct StripeCheckoutSessionClient: Sendable {
    var apiKeyProvider: @Sendable () -> String?
    var httpClient: StripeCheckoutHTTPClient

    init(
        apiKeyProvider: @escaping @Sendable () -> String? = {
            PaymentCredentialStore.shared.loadSecret(.stripeSecretKey)
        },
        httpClient: StripeCheckoutHTTPClient = URLSession.shared
    ) {
        self.apiKeyProvider = apiKeyProvider
        self.httpClient = httpClient
    }

    func createTestCheckoutSession(
        companyID: String,
        productName: String,
        amountUSD: Double,
        postID: String
    ) async throws -> CompanyCheckoutLink {
        guard amountUSD > 0 else { throw StripeCheckoutSessionError.invalidAmount }
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
              !apiKey.isEmpty else {
            throw StripeCheckoutSessionError.missingTestKey
        }
        guard apiKey.hasPrefix("sk_test_") else {
            throw StripeCheckoutSessionError.liveKeyRejected
        }

        var request = URLRequest(url: URL(string: "https://api.stripe.com/v1/checkout/sessions")!)
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formURLEncodedBody([
            ("mode", "payment"),
            ("success_url", "https://os1.local/payments/success?company_id=\(companyID)&session_id={CHECKOUT_SESSION_ID}"),
            ("cancel_url", "https://os1.local/payments/cancel?company_id=\(companyID)"),
            ("line_items[0][price_data][currency]", "usd"),
            ("line_items[0][price_data][product_data][name]", productName),
            ("line_items[0][price_data][unit_amount]", "\(Int((amountUSD * 100).rounded()))"),
            ("line_items[0][quantity]", "1"),
            ("metadata[company_id]", companyID),
            ("metadata[utm_campaign]", companyID),
            ("metadata[utm_content]", postID),
            ("metadata[mode]", "test")
        ])

        let (data, response) = try await httpClient.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw StripeCheckoutSessionError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw StripeCheckoutSessionError.stripeRejected(http.statusCode, body)
        }

        struct StripeSessionResponse: Decodable {
            let id: String
            let url: URL?
        }
        let decoded = try JSONDecoder().decode(StripeSessionResponse.self, from: data)
        guard let checkoutURL = decoded.url else {
            throw StripeCheckoutSessionError.missingCheckoutURL
        }

        var access = CompanyAccessControl.lockedDown(companyID: companyID)
        access.paymentProviderAllowlist = ["stripe"]
        return CompanyPaymentCheckout.createTestCheckoutLink(
            companyID: companyID,
            provider: .stripe,
            productName: productName,
            amountUSD: amountUSD,
            postID: postID,
            accessControl: access,
            checkoutID: decoded.id,
            checkoutURL: checkoutURL
        )!
    }

    static func formURLEncodedBody(_ pairs: [(String, String)]) -> Data {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = pairs.map { key, value in
            "\(key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
        return Data(body.utf8)
    }
}
