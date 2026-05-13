import Foundation
import Testing
@testable import OS1

struct HermesUpdatePreferencesTests {
    @Test
    func dismissThenNewMajorVersionReappearsAfterRestart() throws {
        let suiteName = "OS1Tests.HermesUpdateBanner.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = HermesUpdatePreferencesStore(defaults: defaults)
        var firstSession = HermesUpdateBannerSession(preferences: preferences)
        let v1 = availability(offeredVersion: "1.0.0", commits: 7)

        #expect(firstSession.snapshot(
            for: v1,
            checkAutomatically: true
        )?.renderedRows == [
            "title=Major Hermes update available",
            "subtitle=Hermes Agent v0.13.0 — Hermes Agent v1.0.0 offered, 7 commits behind main.",
            "detail=Review the changelog before updating. Major updates can include workflow or configuration changes. Breaking-change notes: BREAKING CHANGE: config keys moved under gateway.",
            "accessibility=update available, Hermes Agent v1.0.0",
            "breaking=BREAKING CHANGE: config keys moved under gateway.",
            "action=Update Hermes Agent",
            "action=What's new",
            "action=Dismiss"
        ])

        firstSession.dismiss(offer: offer(offeredVersion: "1.0.0", commits: 7))

        var restartedSession = HermesUpdateBannerSession(
            preferences: HermesUpdatePreferencesStore(defaults: defaults)
        )
        #expect(restartedSession.snapshot(
            for: v1,
            checkAutomatically: true
        ) == nil)

        let v2 = availability(offeredVersion: "2.0.0", commits: 12)
        #expect(restartedSession.snapshot(
            for: v2,
            checkAutomatically: true
        )?.renderedRows == [
            "title=Major Hermes update available",
            "subtitle=Hermes Agent v0.13.0 — Hermes Agent v2.0.0 offered, 12 commits behind main.",
            "detail=Review the changelog before updating. Major updates can include workflow or configuration changes. Breaking-change notes: BREAKING CHANGE: config keys moved under gateway.",
            "accessibility=update available, Hermes Agent v2.0.0",
            "breaking=BREAKING CHANGE: config keys moved under gateway.",
            "action=Update Hermes Agent",
            "action=What's new",
            "action=Dismiss"
        ])
    }

    @Test
    func disabledAutomaticChecksDoNotResurfaceSameVersionAfterRestart() throws {
        let suiteName = "OS1Tests.HermesUpdateBanner.Disabled.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let preferences = HermesUpdatePreferencesStore(defaults: defaults)
        var firstSession = HermesUpdateBannerSession(preferences: preferences)
        let v1 = availability(offeredVersion: "1.1.0", commits: 3)

        #expect(firstSession.snapshot(for: v1, checkAutomatically: false) != nil)

        var restartedSession = HermesUpdateBannerSession(
            preferences: HermesUpdatePreferencesStore(defaults: defaults)
        )
        #expect(restartedSession.snapshot(for: v1, checkAutomatically: false) == nil)
        #expect(restartedSession.snapshot(
            for: availability(offeredVersion: "1.2.0", commits: 5),
            checkAutomatically: false
        ) != nil)
    }

    private func availability(offeredVersion: String, commits: Int) -> HermesUpdateAvailability {
        .behind(
            versionLabel: "Hermes Agent v0.13.0",
            offer: offer(offeredVersion: offeredVersion, commits: commits)
        )
    }

    private func offer(offeredVersion: String, commits: Int) -> HermesUpdateOffer {
        HermesUpdateOffer(
            currentVersion: "0.13.0",
            offeredVersion: offeredVersion,
            offeredVersionLabel: "Hermes Agent v\(offeredVersion)",
            commits: commits,
            changelogURL: URL(string: "https://github.com/NousResearch/hermes-agent/compare/a...b"),
            breakingChangeNotes: ["BREAKING CHANGE: config keys moved under gateway."]
        )
    }
}
