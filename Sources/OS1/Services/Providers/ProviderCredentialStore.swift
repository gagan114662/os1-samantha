import Foundation
import Security

/// Per-Mac Keychain wrapper for the user's LLM provider API keys.
///
/// One key per (host × provider). Storage is sliced two ways:
///   - profile-scoped slot — `<profileId>.<providerSlug>` Keychain
///     account, so one connection's OpenAI key doesn't leak into another
///     host config.
///   - default slot — `default.<providerSlug>`, the Mac-level fallback
///     for users who reuse the same provider key across all of their
///     own VMs (the common case — most people have one OpenAI key).
///
/// Resolution order on read:
///   1. Profile-scoped slot — strict per-host
///   2. Default slot — Mac-level fallback
///
/// Mirrors `ComposioCredentialStore` deliberately so the two stores
/// behave identically when wiring the same `ConnectionProfile.id` and
/// `MacKey ↔ HostKey` semantics.
final class ProviderCredentialStore: @unchecked Sendable {
    enum CredentialError: LocalizedError {
        case saveFailed(OSStatus)
        case deleteFailed(OSStatus)

        var errorDescription: String? {
            switch self {
            case .saveFailed(let status):
                return "Couldn't save the provider API key to Keychain (status \(status))."
            case .deleteFailed(let status):
                return "Couldn't remove the provider API key from Keychain (status \(status))."
            }
        }
    }

    static let defaultProfileToken = "default"

    private let service: String

    init(service: String = "ai.os1.provider-key") {
        self.service = service
    }

    // MARK: - Read

    /// Resolves the API key for the given provider on the active host.
    /// Profile-scoped first; falls back to the Mac-level default.
    func loadAPIKey(slug: String, forProfileId profileId: String? = nil) -> String? {
        if let profileId, let key = readKey(account: account(profileToken: profileId, slug: slug)) {
            return key
        }
        return readKey(account: account(profileToken: Self.defaultProfileToken, slug: slug))
    }

    /// True if either a profile-specific or default key is stored.
    func hasAPIKey(slug: String, forProfileId profileId: String? = nil) -> Bool {
        loadAPIKey(slug: slug, forProfileId: profileId) != nil
    }

    /// True if there's a profile-scoped key (regardless of default).
    /// Lets the UI render "host-scoped" vs "Mac default" badges.
    func hasProfileScopedKey(slug: String, profileId: String) -> Bool {
        readKey(account: account(profileToken: profileId, slug: slug)) != nil
    }

    /// Map of slug → has-any-key, used for rendering the provider list
    /// without N round-trips. Cheap (one Keychain read per provider).
    func loadConnectionStatuses(forProfileId profileId: String?) -> [String: Bool] {
        var result: [String: Bool] = [:]
        for entry in ProviderCatalog.entries {
            result[entry.slug] = hasAPIKey(slug: entry.slug, forProfileId: profileId)
        }
        return result
    }

    // MARK: - Write

    /// Saves a key for one provider into a specific profile's slot.
    /// Empty input deletes that slot.
    func saveAPIKey(_ apiKey: String, slug: String, forProfileId profileId: String) throws {
        try saveKey(apiKey, account: account(profileToken: profileId, slug: slug))
    }

    /// Saves a key as the Mac-level default for one provider. Same
    /// empty-input semantics.
    func saveAsDefault(_ apiKey: String, slug: String) throws {
        try saveKey(apiKey, account: account(profileToken: Self.defaultProfileToken, slug: slug))
    }

    // MARK: - Delete

    func deleteKey(slug: String, forProfileId profileId: String) throws {
        try deleteKey(account: account(profileToken: profileId, slug: slug))
    }

    func deleteDefaultKey(slug: String) throws {
        try deleteKey(account: account(profileToken: Self.defaultProfileToken, slug: slug))
    }

    // MARK: - Internals

    /// Composite account: `<profileToken>.<slug>` keeps the Keychain
    /// flat (one service) so SecItemDelete on app uninstall wipes them
    /// all at once, while still namespacing per host and per provider.
    private func account(profileToken: String, slug: String) -> String {
        "\(profileToken).\(slug)"
    }

    private func readKey(account: String) -> String? {
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
              let key = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func saveKey(_ apiKey: String, account: String) throws {
        let trimmed = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try deleteKey(account: account)
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

    private func deleteKey(account: String) throws {
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

/// Non-secret health metadata for provider calls. API keys stay in
/// Keychain; this only records timestamps that Doctor can safely surface.
final class ProviderCallHealthStore: @unchecked Sendable {
    private let userDefaults: UserDefaults
    private let keyPrefix: String

    init(
        userDefaults: UserDefaults = .standard,
        keyPrefix: String = "ai.os1.provider-call-health"
    ) {
        self.userDefaults = userDefaults
        self.keyPrefix = keyPrefix
    }

    func recordSuccessfulCall(
        slug: String,
        forProfileId profileId: String? = nil,
        at date: Date = Date()
    ) {
        userDefaults.set(date.timeIntervalSince1970, forKey: key(profileToken: profileToken(profileId), slug: slug))
    }

    func lastSuccessfulCall(slug: String, forProfileId profileId: String? = nil) -> Date? {
        if let profileId,
           let profileScoped = readDate(key: key(profileToken: profileId, slug: slug)) {
            return profileScoped
        }
        return readDate(key: key(profileToken: ProviderCredentialStore.defaultProfileToken, slug: slug))
    }

    func loadLastSuccessfulCalls(forProfileId profileId: String?) -> [String: Date] {
        var result: [String: Date] = [:]
        for entry in ProviderCatalog.entries {
            result[entry.slug] = lastSuccessfulCall(slug: entry.slug, forProfileId: profileId)
        }
        return result
    }

    private func profileToken(_ profileId: String?) -> String {
        profileId ?? ProviderCredentialStore.defaultProfileToken
    }

    private func key(profileToken: String, slug: String) -> String {
        "\(keyPrefix).\(profileToken).\(slug)"
    }

    private func readDate(key: String) -> Date? {
        let timestamp = userDefaults.double(forKey: key)
        guard timestamp > 0 else { return nil }
        return Date(timeIntervalSince1970: timestamp)
    }
}
