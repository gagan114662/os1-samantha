import Foundation

enum HermesUpdateKind: Equatable, Sendable {
    case major
    case minor
    case unknown
}

struct HermesUpdateOffer: Equatable, Sendable {
    let currentVersion: String?
    let offeredVersion: String?
    let offeredVersionLabel: String?
    let commits: Int?
    let changelogURL: URL?
    let breakingChangeNotes: [String]

    var displayVersion: String {
        offeredVersionLabel ?? offeredVersion.map { "Hermes Agent v\($0)" } ?? "latest Hermes Agent"
    }

    var identityKey: String {
        if let offeredVersion, !offeredVersion.isEmpty {
            return "version:\(offeredVersion)"
        }
        if let offeredVersionLabel, !offeredVersionLabel.isEmpty {
            return "label:\(offeredVersionLabel)"
        }
        if let changelogURL {
            return "changelog:\(changelogURL.absoluteString)"
        }
        return "commits:\(commits ?? -1)"
    }

    var majorVersionKey: String {
        if let version = HermesSemanticVersion.parse(offeredVersion ?? offeredVersionLabel) {
            return "major:\(version.major)"
        }
        return identityKey
    }

    var updateKind: HermesUpdateKind {
        guard let current = HermesSemanticVersion.parse(currentVersion),
              let offered = HermesSemanticVersion.parse(offeredVersion ?? offeredVersionLabel) else {
            return .unknown
        }
        if offered.major > current.major {
            return .major
        }
        return .minor
    }
}

struct HermesUpdateBannerSnapshot: Equatable, Sendable {
    let title: String
    let subtitle: String
    let detail: String
    let accessibilityLabel: String
    let breakingChangeNotes: [String]
    let actionLabels: [String]

    static func make(installedVersionLabel: String, offer: HermesUpdateOffer) -> HermesUpdateBannerSnapshot {
        let title: String
        let detailPrefix: String
        switch offer.updateKind {
        case .major:
            title = L10n.string("Major Hermes update available")
            detailPrefix = L10n.string("Review the changelog before updating. Major updates can include workflow or configuration changes.")
        case .minor:
            title = L10n.string("Hermes minor update available")
            detailPrefix = L10n.string("This minor update can be installed with hermes update --backup; the gateway restarts automatically.")
        case .unknown:
            title = L10n.string("Hermes update available")
            detailPrefix = L10n.string("Review the changelog before updating, then run hermes update --backup when ready.")
        }

        let subtitle: String
        if let commits = offer.commits, commits > 0 {
            subtitle = String(
                format: L10n.string(commits == 1
                    ? "%@ — %@ offered, %d commit behind main."
                    : "%@ — %@ offered, %d commits behind main."),
                installedVersionLabel,
                offer.displayVersion,
                commits
            )
        } else {
            subtitle = String(
                format: L10n.string("%@ — %@ offered."),
                installedVersionLabel,
                offer.displayVersion
            )
        }

        let breakingNotes = offer.breakingChangeNotes
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let detail: String
        if breakingNotes.isEmpty {
            detail = detailPrefix
        } else {
            detail = String(
                format: L10n.string("%@ Breaking-change notes: %@"),
                detailPrefix,
                breakingNotes.joined(separator: "; ")
            )
        }

        return HermesUpdateBannerSnapshot(
            title: title,
            subtitle: subtitle,
            detail: detail,
            accessibilityLabel: String(
                format: L10n.string("update available, %@"),
                offer.displayVersion
            ),
            breakingChangeNotes: breakingNotes,
            actionLabels: [
                L10n.string("Update Hermes Agent"),
                L10n.string("What's new"),
                L10n.string("Dismiss")
            ]
        )
    }

    var renderedRows: [String] {
        [
            "title=\(title)",
            "subtitle=\(subtitle)",
            "detail=\(detail)",
            "accessibility=\(accessibilityLabel)"
        ]
        + breakingChangeNotes.map { "breaking=\($0)" }
        + actionLabels.map { "action=\($0)" }
    }
}

struct HermesUpdateBannerSession {
    private let preferences: HermesUpdatePreferencesStore
    private var surfacedWhileAutomaticChecksDisabled = Set<String>()

    init(preferences: HermesUpdatePreferencesStore = HermesUpdatePreferencesStore()) {
        self.preferences = preferences
    }

    mutating func snapshot(
        for availability: HermesUpdateAvailability,
        checkAutomatically: Bool
    ) -> HermesUpdateBannerSnapshot? {
        guard case .behind(let installedVersionLabel, let offer) = availability else {
            return nil
        }
        guard !preferences.isDismissed(offer: offer) else {
            return nil
        }

        if !checkAutomatically {
            let key = offer.identityKey
            if preferences.lastSurfacedVersionKey == key,
               !surfacedWhileAutomaticChecksDisabled.contains(key) {
                return nil
            }
            surfacedWhileAutomaticChecksDisabled.insert(key)
            preferences.lastSurfacedVersionKey = key
        }

        return HermesUpdateBannerSnapshot.make(
            installedVersionLabel: installedVersionLabel,
            offer: offer
        )
    }

    func dismiss(offer: HermesUpdateOffer) {
        preferences.dismiss(offer: offer)
    }
}

final class HermesUpdatePreferencesStore {
    static let defaultCheckAutomatically = true

    private enum Keys {
        static let checkAutomatically = "os1.hermesUpdate.checkAutomatically"
        static let dismissedMajorVersions = "os1.hermesUpdate.dismissedMajorVersions"
        static let lastSurfacedVersionKey = "os1.hermesUpdate.lastSurfacedVersionKey"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var checkAutomatically: Bool {
        get {
            guard defaults.object(forKey: Keys.checkAutomatically) != nil else {
                return Self.defaultCheckAutomatically
            }
            return defaults.bool(forKey: Keys.checkAutomatically)
        }
        set {
            defaults.set(newValue, forKey: Keys.checkAutomatically)
        }
    }

    var lastSurfacedVersionKey: String? {
        get { defaults.string(forKey: Keys.lastSurfacedVersionKey) }
        set { defaults.set(newValue, forKey: Keys.lastSurfacedVersionKey) }
    }

    func isDismissed(offer: HermesUpdateOffer) -> Bool {
        dismissedMajorVersions.contains(offer.majorVersionKey)
    }

    func dismiss(offer: HermesUpdateOffer) {
        var dismissed = dismissedMajorVersions
        dismissed.insert(offer.majorVersionKey)
        dismissedMajorVersions = dismissed
    }

    private var dismissedMajorVersions: Set<String> {
        get {
            Set(defaults.stringArray(forKey: Keys.dismissedMajorVersions) ?? [])
        }
        set {
            defaults.set(Array(newValue).sorted(), forKey: Keys.dismissedMajorVersions)
        }
    }
}

private struct HermesSemanticVersion: Comparable {
    let major: Int
    let minor: Int
    let patch: Int

    static func parse(_ text: String?) -> HermesSemanticVersion? {
        guard let text else { return nil }
        let pattern = #"(?:^|[^0-9])v?([0-9]+)\.([0-9]+)(?:\.([0-9]+))?"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let major = component(at: 1, in: text, match: match),
              let minor = component(at: 2, in: text, match: match) else {
            return nil
        }
        let patch = component(at: 3, in: text, match: match) ?? 0
        return HermesSemanticVersion(major: major, minor: minor, patch: patch)
    }

    static func < (lhs: HermesSemanticVersion, rhs: HermesSemanticVersion) -> Bool {
        if lhs.major != rhs.major { return lhs.major < rhs.major }
        if lhs.minor != rhs.minor { return lhs.minor < rhs.minor }
        return lhs.patch < rhs.patch
    }

    private static func component(at index: Int, in text: String, match: NSTextCheckingResult) -> Int? {
        guard match.range(at: index).location != NSNotFound,
              let range = Range(match.range(at: index), in: text) else {
            return nil
        }
        return Int(text[range])
    }
}
