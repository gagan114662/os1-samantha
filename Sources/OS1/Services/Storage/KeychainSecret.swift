import Foundation
import Security

/// Tiny, dependency-free Keychain reader for secrets that secret-bearing
/// services (Orgo, ElevenLabs, Composio, Telegram) saved into their own
/// service identifiers. Used as the **fallback** when an env var isn't
/// present, so launchd plists don't need inline API keys.
///
/// Why not just call `SecItemCopyMatching` inline at each site? Three reasons:
/// 1. Single place to audit how we touch Keychain (no scattering).
/// 2. No surprises on `kSecAttrAccessibleWhenUnlocked` semantics.
/// 3. Easy to unit-test or stub later by replacing this enum.
enum KeychainSecret {
    /// Read a generic-password item without prompting the user (subject to
    /// Mac's per-app access control — first-time access for an unsigned/
    /// changed binary may prompt once).
    static func read(service: String, account: String = "default") -> String? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword,
            kSecAttrService: service,
            kSecAttrAccount: account,
            kSecMatchLimit: kSecMatchLimitOne,
            kSecReturnData: true,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .nonEmpty
    }
}

private extension String {
    /// Returns nil for empty strings, so `nil ?? next-fallback` chains work.
    var nonEmpty: String? { isEmpty ? nil : self }
}
