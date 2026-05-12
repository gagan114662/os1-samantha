import Foundation
import Security

/// Keychain-backed payment provider secrets. Values are scoped the same way
/// connector keys are: active host first, Mac default fallback.
final class PaymentCredentialStore: @unchecked Sendable {
    enum SecretKind: String, CaseIterable, Hashable {
        case stripeSecretKey = "stripe_secret_key"
        case stripeWebhookSecret = "stripe_webhook_secret"
        case gumroadApplicationSecret = "gumroad_application_secret"

        var displayName: String {
            switch self {
            case .stripeSecretKey: "Stripe test secret key"
            case .stripeWebhookSecret: "Stripe webhook secret"
            case .gumroadApplicationSecret: "Gumroad application secret"
            }
        }
    }

    enum CredentialError: LocalizedError {
        case saveFailed(OSStatus)
        case deleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Couldn't save the payment credential to Keychain (status \(status))."
            case .deleteFailed(let status):
                return "Couldn't remove the payment credential from Keychain (status \(status))."
            }
        }
    }

    static let shared = PaymentCredentialStore()
    static let defaultProfileToken = "default"

    private let service: String

    init(service: String = "ai.os1.payment-credential") {
        self.service = service
    }

    func loadSecret(_ kind: SecretKind, forProfileId profileId: String? = nil) -> String? {
        if let profileId,
           let profileSecret = readSecret(account: account(profileToken: profileId, kind: kind)) {
            return profileSecret
        }
        return readSecret(account: account(profileToken: Self.defaultProfileToken, kind: kind))
    }

    func hasSecret(_ kind: SecretKind, forProfileId profileId: String? = nil) -> Bool {
        loadSecret(kind, forProfileId: profileId) != nil
    }

    func hasProfileScopedSecret(_ kind: SecretKind, profileId: String) -> Bool {
        readSecret(account: account(profileToken: profileId, kind: kind)) != nil
    }

    func saveSecret(_ secret: String, kind: SecretKind, forProfileId profileId: String) throws {
        try saveSecret(secret, account: account(profileToken: profileId, kind: kind))
    }

    func saveDefaultSecret(_ secret: String, kind: SecretKind) throws {
        try saveSecret(secret, account: account(profileToken: Self.defaultProfileToken, kind: kind))
    }

    func deleteSecret(_ kind: SecretKind, forProfileId profileId: String) throws {
        try deleteSecret(account: account(profileToken: profileId, kind: kind))
    }

    func deleteDefaultSecret(_ kind: SecretKind) throws {
        try deleteSecret(account: account(profileToken: Self.defaultProfileToken, kind: kind))
    }

    private func account(profileToken: String, kind: SecretKind) -> String {
        "\(profileToken).\(kind.rawValue)"
    }

    private func readSecret(account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess,
              let data = result as? Data,
              let secret = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func saveSecret(_ secret: String, account: String) throws {
        let trimmed = secret.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteSecret(account: account)
            return
        }
        let data = Data(trimmed.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let attributes: [String: Any] = [kSecValueData as String: data]

        let updateStatus = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var addQuery = query
            addQuery[kSecValueData as String] = data
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw CredentialError.saveFailed(addStatus)
            }
        default:
            throw CredentialError.saveFailed(updateStatus)
        }
    }

    private func deleteSecret(account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        let status = SecItemDelete(query as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            throw CredentialError.deleteFailed(status)
        }
    }
}
