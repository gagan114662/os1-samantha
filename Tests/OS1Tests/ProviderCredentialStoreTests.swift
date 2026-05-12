import Foundation
import Testing
@testable import OS1

/// Sanity tests around the per-(host × provider) keying behavior of
/// `ProviderCredentialStore`. The tests use a unique service id so they
/// don't collide with the user's real Keychain entries — and clean up
/// after themselves.
struct ProviderCredentialStoreTests {

    @Test
    func writingProfileKeyDoesNotAffectDefault() throws {
        let store = makeIsolatedStore()
        defer { wipe(store) }

        try store.saveAPIKey("host-key", slug: "openai", forProfileId: "host-A")
        #expect(store.loadAPIKey(slug: "openai", forProfileId: "host-A") == "host-key")
        #expect(store.loadAPIKey(slug: "openai", forProfileId: "host-B") == nil)
        #expect(store.loadAPIKey(slug: "openai", forProfileId: nil) == nil)
    }

    @Test
    func defaultIsFallbackForUnknownProfile() throws {
        let store = makeIsolatedStore()
        defer { wipe(store) }

        try store.saveAsDefault("default-key", slug: "openai")
        // Resolution: profile-scoped first, default fallback.
        #expect(store.loadAPIKey(slug: "openai", forProfileId: "host-A") == "default-key")
        #expect(store.loadAPIKey(slug: "openai", forProfileId: nil) == "default-key")
    }

    @Test
    func profileScopedOverridesDefault() throws {
        let store = makeIsolatedStore()
        defer { wipe(store) }

        try store.saveAsDefault("default-key", slug: "openai")
        try store.saveAPIKey("host-A-specific", slug: "openai", forProfileId: "host-A")

        #expect(store.loadAPIKey(slug: "openai", forProfileId: "host-A") == "host-A-specific")
        #expect(store.loadAPIKey(slug: "openai", forProfileId: "host-B") == "default-key")
    }

    @Test
    func keysAreIsolatedAcrossProviders() throws {
        let store = makeIsolatedStore()
        defer { wipe(store) }

        try store.saveAPIKey("openai-key", slug: "openai", forProfileId: "host-A")
        try store.saveAPIKey("anthropic-key", slug: "anthropic", forProfileId: "host-A")

        #expect(store.loadAPIKey(slug: "openai", forProfileId: "host-A") == "openai-key")
        #expect(store.loadAPIKey(slug: "anthropic", forProfileId: "host-A") == "anthropic-key")
    }

    @Test
    func emptyKeyDeletesSlot() throws {
        let store = makeIsolatedStore()
        defer { wipe(store) }

        try store.saveAPIKey("first", slug: "openai", forProfileId: "host-A")
        try store.saveAPIKey("   ", slug: "openai", forProfileId: "host-A")
        #expect(store.loadAPIKey(slug: "openai", forProfileId: "host-A") == nil)
    }

    @Test
    func loadConnectionStatusesCoversCatalog() throws {
        let store = makeIsolatedStore()
        defer { wipe(store) }

        try store.saveAPIKey("k", slug: "openrouter", forProfileId: "host-A")
        let map = store.loadConnectionStatuses(forProfileId: "host-A")
        #expect(map["openrouter"] == true)
        #expect(map["anthropic"] == false)
        // Map should have an entry for every catalog provider so the
        // UI can render them all without "missing" rows.
        #expect(map.count == ProviderCatalog.entries.count)
    }

    @Test
    func providerCallHealthUsesProfileSpecificTimestampBeforeDefault() throws {
        let suiteName = "ai.os1.tests.provider-health.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderCallHealthStore(userDefaults: defaults, keyPrefix: suiteName)
        let defaultDate = Date(timeIntervalSince1970: 1_800_000_000)
        let hostDate = Date(timeIntervalSince1970: 1_800_003_600)

        store.recordSuccessfulCall(slug: "elevenlabs-tts", at: defaultDate)
        store.recordSuccessfulCall(slug: "elevenlabs-tts", forProfileId: "host-A", at: hostDate)

        #expect(store.lastSuccessfulCall(slug: "elevenlabs-tts", forProfileId: "host-A") == hostDate)
        #expect(store.lastSuccessfulCall(slug: "elevenlabs-tts", forProfileId: "host-B") == defaultDate)
        #expect(store.loadLastSuccessfulCalls(forProfileId: "host-A")["elevenlabs-tts"] == hostDate)
    }

    // MARK: - helpers

    /// Each test gets its own service id so concurrent runs don't
    /// stomp on each other in the user's Keychain.
    private func makeIsolatedStore() -> ProviderCredentialStore {
        let suffix = UUID().uuidString.prefix(12)
        return ProviderCredentialStore(service: "ai.os1.tests.provider-key.\(suffix)")
    }

    /// Best-effort cleanup. We don't have a hook to enumerate items by
    /// service, so we just clear every slug × (default + a few common
    /// host ids the tests use).
    private func wipe(_ store: ProviderCredentialStore) {
        for entry in ProviderCatalog.entries {
            try? store.deleteDefaultKey(slug: entry.slug)
            for hostId in ["host-A", "host-B"] {
                try? store.deleteKey(slug: entry.slug, forProfileId: hostId)
            }
        }
    }
}
