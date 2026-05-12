import Foundation
import Testing
@testable import OS1

struct ProviderCatalogTests {
    @Test
    func slugsAreUnique() {
        let slugs = ProviderCatalog.entries.map(\.slug)
        let unique = Set(slugs)
        #expect(slugs.count == unique.count, "Slugs should be unique. Got: \(slugs)")
    }

    @Test
    func envVarsAreUnique() {
        // Hermes reads env vars from .env keyed by name, so two
        // providers writing to the same key would collide on disk.
        let envVars = ProviderCatalog.entries.map(\.envVar)
        let unique = Set(envVars)
        #expect(envVars.count == unique.count, "Env vars should be unique. Got: \(envVars)")
    }

    @Test
    func customProviderConfigNamesAreUnique() {
        // Within `custom_providers`, `name` is the lookup key — must be
        // unique. Built-in providers don't share this namespace.
        var names: [String] = []
        for entry in ProviderCatalog.entries {
            if case .customProvider(let configName) = entry.kind {
                names.append(configName)
            }
        }
        #expect(names.count == Set(names).count, "Custom provider names should be unique. Got: \(names)")
    }

    @Test
    func everyEntryHasParsableURLs() {
        for entry in ProviderCatalog.entries {
            #expect(entry.baseURL.scheme == "https",
                    "\(entry.slug) base URL should be https")
            #expect(entry.dashboardURL.scheme == "https",
                    "\(entry.slug) dashboard URL should be https")
            if let docs = entry.docsURL {
                #expect(docs.scheme == "https",
                        "\(entry.slug) docs URL should be https")
            }
        }
    }

    @Test
    func sixCoreProvidersPresent() {
        let expected: Set<String> = ["anthropic", "openrouter", "openai", "fireworks", "kimi", "zai"]
        let actual = Set(ProviderCatalog.entries.map(\.slug))
        #expect(expected.isSubset(of: actual), "Missing one of the 6 core providers. Got: \(actual)")
    }

    @Test
    func openRouterIsTheOnlyOAuthProvider() {
        // OAuth (PKCE) is OpenRouter-only today. If we add another
        // OAuth-capable provider this test should be loosened — but
        // the change should be deliberate, not accidental.
        let oauthSlugs = ProviderCatalog.entries.filter(\.supportsOAuth).map(\.slug)
        #expect(oauthSlugs == ["openrouter"], "OAuth providers changed: \(oauthSlugs)")
    }

    @Test
    func anthropicSkipsModelValidation() {
        // Anthropic doesn't have a cheap key-probe endpoint — explicit
        // .skip avoids spurious "validation failed" errors at save time.
        guard let anthropic = ProviderCatalog.entry(for: "anthropic") else {
            Issue.record("Anthropic entry missing")
            return
        }
        if case .skip = anthropic.validation {
            // expected
        } else {
            Issue.record("Anthropic validation should be .skip; got \(anthropic.validation)")
        }
    }

    @Test
    func openAIBaseURLIsCanonical() {
        let openai = ProviderCatalog.entry(for: "openai")
        #expect(openai?.baseURL.absoluteString == "https://api.openai.com/v1")
    }

    @Test
    func providerModelSummaryDecodesCommonShapes() throws {
        let payloads: [(String, String?)] = [
            (#"{"id":"gpt-5.2","name":"GPT-5.2","context_length":200000}"#, "GPT-5.2"),
            (#"{"id":"glm-4.6","display_name":"GLM 4.6"}"#, "GLM 4.6"),
            (#"{"id":"openai/o5-mini"}"#, nil), // no display name
        ]
        for (raw, expectedName) in payloads {
            let data = Data(raw.utf8)
            let model = try JSONDecoder().decode(ProviderModelSummary.self, from: data)
            #expect(model.displayName == expectedName, "Failed for \(raw)")
        }
    }

    @Test
    func providerModelListResponseDecodes() throws {
        let raw = #"{"data":[{"id":"a"},{"id":"b","name":"Beta"}]}"#
        let payload = try JSONDecoder().decode(ProviderModelListResponse.self, from: Data(raw.utf8))
        #expect(payload.data.map(\.id) == ["a", "b"])
        #expect(payload.data[1].displayName == "Beta")
    }

    @Test
    func mediaProvidersCoverEveryRequiredModality() throws {
        let required: Set<ProviderCatalogEntry.Modality> = [.video, .image, .tts, .voiceClone, .music, .avatar, .render]
        let actual = Set(ProviderCatalog.entries.map(\.modality))

        #expect(required.isSubset(of: actual))
        for modality in required {
            let entries = ProviderCatalog.entries.filter { $0.modality == modality }
            #expect(!entries.isEmpty, "\(modality.rawValue) needs at least one provider")
            for entry in entries {
                #expect(entry.dashboardURL.scheme == "https")
                #expect(entry.docsURL?.scheme == "https")
                let cap = try #require(entry.dailyCostCapUSD, "\(entry.slug) needs an explicit daily cost cap.")
                #expect(cap > 0, "\(entry.slug) daily cost cap should be positive.")
            }
        }
    }

    @Test
    func doctorReportsProviderKeyPresenceAndLastSuccessfulCall() throws {
        let timestamp = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = DoctorViewModel.providerKeyHealthRows(
            credentialStatuses: ["elevenlabs-tts": true],
            lastSuccessfulCalls: ["elevenlabs-tts": timestamp]
        )
        let eleven = try #require(rows.first { $0.providerSlug == "elevenlabs-tts" })
        let fal = try #require(rows.first { $0.providerSlug == "fal-ai" })

        #expect(eleven.hasKey)
        #expect(eleven.lastSuccessfulCall == timestamp)
        #expect(eleven.summary.contains("key present"))
        #expect(fal.summary.contains("key missing"))
        #expect(fal.summary.contains("last successful call: never"))
    }

    @Test
    func doctorProviderKeyHealthUsesLatestSuccessfulProviderEvent() {
        let older = Date(timeIntervalSince1970: 1_800_000_000)
        let newer = older.addingTimeInterval(60)
        let calls = DoctorViewModel.lastSuccessfulProviderCalls(from: [
            CompanyEvent(
                occurredAt: newer.addingTimeInterval(60),
                kind: .externalSideEffect,
                summary: "Blocked provider call",
                tool: "elevenlabs-tts",
                approvalState: "blocked"
            ),
            CompanyEvent(
                occurredAt: older,
                kind: .externalSideEffect,
                summary: "Rendered narration",
                tool: "elevenlabs-tts",
                approvalState: "approved"
            ),
            CompanyEvent(
                occurredAt: newer,
                kind: .externalSideEffect,
                summary: "Rendered narration again",
                tool: "elevenlabs-tts",
                approvalState: "approved"
            ),
            CompanyEvent(
                occurredAt: newer,
                kind: .externalSideEffect,
                summary: "Unknown provider",
                tool: "not-in-catalog",
                approvalState: "approved"
            )
        ])

        #expect(calls["elevenlabs-tts"] == newer)
        #expect(calls["not-in-catalog"] == nil)
    }
}
