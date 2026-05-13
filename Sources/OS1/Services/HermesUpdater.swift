import Foundation

/// Whether a Hermes update is available on the active host.
///
/// `unknown` until the first probe completes. `notInstalled` lets the UI
/// hide the affordance entirely on hosts where the user hasn't installed
/// Hermes yet (the install banner handles that surface). `upToDate` and
/// `behind` carry the version label from `hermes version` so the UI
/// doesn't need a second round trip to display it.
enum HermesUpdateAvailability: Equatable, Sendable {
    case unknown
    case notInstalled
    case upToDate(versionLabel: String)
    case behind(versionLabel: String, offer: HermesUpdateOffer)

    var versionLabel: String? {
        switch self {
        case .unknown, .notInstalled: nil
        case .upToDate(let label), .behind(let label, _): label
        }
    }

    var isBehind: Bool {
        if case .behind = self { return true }
        return false
    }
}

extension HermesUpdateAvailability {
    static func make(from result: HermesAvailabilityResult, fallbackLabel: String) -> HermesUpdateAvailability {
        if !result.installed { return .notInstalled }

        let label = result.version_label ?? fallbackLabel
        switch result.behind {
        case .some(0):
            return .upToDate(versionLabel: label)
        case .some(let n) where n > 0:
            return .behind(
                versionLabel: label,
                offer: HermesUpdateOffer(
                    currentVersion: result.current_version,
                    offeredVersion: result.offered_version,
                    offeredVersionLabel: result.offered_version_label,
                    commits: n,
                    changelogURL: result.changelog_url,
                    breakingChangeNotes: result.breaking_changes ?? []
                )
            )
        case .some(-1):
            // Behind, count unknown — `hermes update --check` exited 1
            // but the probe could not resolve an exact count.
            return .behind(
                versionLabel: label,
                offer: HermesUpdateOffer(
                    currentVersion: result.current_version,
                    offeredVersion: result.offered_version,
                    offeredVersionLabel: result.offered_version_label,
                    commits: nil,
                    changelogURL: result.changelog_url,
                    breakingChangeNotes: result.breaking_changes ?? []
                )
            )
        default:
            // Probe couldn't determine state (no git repo, network failure on
            // Nix builds, etc.). We still know hermes is installed; treat as
            // up-to-date so the UI doesn't nag.
            return .upToDate(versionLabel: label)
        }
    }
}

/// View-state for the update flow. Same shape as HermesInstallStatus —
/// AppState publishes it; OverviewView and DoctorView read it to render
/// the running spinner / failure banner.
enum HermesUpdateStatus: Equatable {
    case idle
    case running
    case failed(message: String, logTail: String?)
}

struct HermesAvailabilityResult: Decodable, Equatable, Sendable {
    /// `true` when a `hermes` executable is found on the host.
    let installed: Bool
    /// First non-empty line of `hermes version` output. e.g.
    /// "Hermes Agent v0.12.3 (2025-04-18)". Nil if hermes isn't
    /// installed or the version probe failed.
    let version_label: String?
    /// Commits behind origin/main: 0 = synced, >0 = update available,
    /// -1 = behind but count unknown, nil = check failed or doesn't apply.
    /// Mirrors hermes_cli/banner.py's `check_for_updates()` return shape.
    let behind: Int?
    /// Source of the `behind` value: "cache", "fresh-check", or "unknown".
    /// Diagnostic only — surfaced in detail expander, not the headline.
    let source: String
    /// Parsed semantic version from the installed Hermes label, when present.
    let current_version: String?
    /// Parsed semantic version from the offered upstream ref, when present.
    let offered_version: String?
    /// Human label for the upstream ref, e.g. "Hermes Agent v0.14.0".
    let offered_version_label: String?
    /// Changelog/compare URL for the commits included in this update.
    let changelog_url: URL?
    /// Breaking-change notes scraped from commit bodies between local and
    /// offered refs. Empty when no explicit notes were found.
    let breaking_changes: [String]?
}

struct HermesUpdateRunResult: Decodable, Equatable, Sendable {
    let exit_code: Int
    let stdout_tail: String
    let stderr_tail: String
    /// Tail of `~/.hermes/logs/update.log`. `hermes update` mirrors
    /// output to this file (and ignores SIGHUP so it survives SSH
    /// disconnects), so the log is sometimes the only durable record
    /// when the process times out from our side.
    let log_tail: String?

    var succeeded: Bool { exit_code == 0 }
}

/// Drives `hermes version` / `hermes update --check` for detection and
/// `hermes update --backup` for the trigger.
///
/// Bound to the multiplexed transport so it works on both Orgo VMs and
/// SSH hosts. Unlike OrgoHermesInstaller, the update path needs none of
/// the clock-sync / git-bootstrap / dpkg-lock cleanup the first install
/// requires — `hermes update` is a single shell call into a CLI the user
/// already has.
///
/// Defaults to `--backup` so the upstream rollback path
/// (`hermes backup restore --state pre-update`) is always available.
final class HermesUpdater: @unchecked Sendable {
    private let orgoTransport: OrgoTransport
    private let multiplexed: any RemoteTransport

    init(orgoTransport: OrgoTransport, multiplexed: any RemoteTransport) {
        self.orgoTransport = orgoTransport
        self.multiplexed = multiplexed
    }

    func checkAvailability(on connection: ConnectionProfile) async throws -> HermesAvailabilityResult {
        let script = Self.makeAvailabilityScript()
        return try await multiplexed.executeJSON(
            on: connection,
            pythonScript: script,
            responseType: HermesAvailabilityResult.self
        )
    }

    func performUpdate(on connection: ConnectionProfile) async throws -> HermesUpdateRunResult {
        let script = Self.makeUpdateScript()
        switch connection.transport {
        case .orgo:
            // `hermes update` is the slowest call we make on Orgo by far —
            // git pull + uv pip install + gateway restart can run a couple
            // of minutes when the dependency tree changes. Use the long
            // /exec path with the same 290s ceiling as the installer.
            return try await orgoTransport.executeLongPython(
                on: connection,
                pythonScript: script,
                serverTimeoutSeconds: 290,
                responseType: HermesUpdateRunResult.self
            )
        case .ssh:
            return try await multiplexed.executeJSON(
                on: connection,
                pythonScript: script,
                responseType: HermesUpdateRunResult.self
            )
        }
    }
}

extension HermesUpdater {
    /// Generates the Python source for the availability probe. Exposed
    /// for testing so a Python-syntax check can run against it without
    /// needing a real RemoteTransport.
    static func makeAvailabilityScript() -> String {
        return #"""
        import json
        import os
        import re
        import shutil
        import subprocess
        import sys
        import time
        import urllib.parse

        UPDATE_CACHE_TTL_SECONDS = 6 * 3600

        def find_hermes_binary():
            path = shutil.which("hermes")
            if path:
                return path
            for candidate in [
                os.path.expanduser("~/.local/bin/hermes"),
                os.path.expanduser("~/.cargo/bin/hermes"),
                os.path.expanduser("~/.hermes/bin/hermes"),
                "/usr/local/bin/hermes",
                "/usr/bin/hermes",
            ]:
                if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                    return candidate
            return None

        def run(args, timeout=10):
            return subprocess.run(args, capture_output=True, text=True, timeout=timeout)

        def parse_version(text):
            if not text:
                return None
            match = re.search(r"v?(\d+\.\d+(?:\.\d+)?)", text)
            return match.group(1) if match else None

        def find_git_root(hermes_bin):
            starts = [
                os.path.dirname(os.path.realpath(hermes_bin)),
                os.path.expanduser("~/.hermes"),
            ]
            seen = set()
            for start in starts:
                current = os.path.abspath(start)
                for _ in range(8):
                    if current in seen:
                        break
                    seen.add(current)
                    if os.path.isdir(os.path.join(current, ".git")):
                        return current
                    parent = os.path.dirname(current)
                    if parent == current:
                        break
                    current = parent
                try:
                    r = run(["git", "-C", start, "rev-parse", "--show-toplevel"])
                    if r.returncode == 0 and r.stdout.strip():
                        return r.stdout.strip()
                except Exception:
                    pass
            return None

        def git_text(root, args, timeout=10):
            try:
                r = run(["git", "-C", root] + args, timeout=timeout)
                if r.returncode == 0:
                    return (r.stdout or "").strip()
            except Exception:
                pass
            return None

        def upstream_ref(root):
            for ref in ["@{u}", "origin/main", "origin/master"]:
                value = git_text(root, ["rev-parse", "--verify", ref])
                if value:
                    return value
            return None

        def version_from_ref(root, ref):
            for path in ["pyproject.toml", "setup.cfg", "hermes_cli/__init__.py", "package.json"]:
                text = git_text(root, ["show", f"{ref}:{path}"])
                version = parse_version(text)
                if version:
                    return version
            return None

        def normalize_github_remote(remote):
            if not remote:
                return None
            remote = remote.strip()
            if remote.startswith("git@github.com:"):
                path = remote[len("git@github.com:"):]
            else:
                parsed = urllib.parse.urlparse(remote)
                if parsed.netloc not in ("github.com", "www.github.com"):
                    return None
                path = parsed.path.lstrip("/")
            if path.endswith(".git"):
                path = path[:-4]
            parts = [p for p in path.split("/") if p]
            if len(parts) < 2:
                return None
            return f"https://github.com/{parts[0]}/{parts[1]}"

        def changelog_url(root, current_ref, offered_ref):
            base = normalize_github_remote(git_text(root, ["config", "--get", "remote.origin.url"]))
            if not base or not current_ref or not offered_ref:
                return None
            return f"{base}/compare/{current_ref[:12]}...{offered_ref[:12]}"

        def breaking_changes(root, current_ref, offered_ref):
            if not current_ref or not offered_ref:
                return []
            try:
                r = run([
                    "git", "-C", root, "log",
                    "--format=%s%n%b%n---END-COMMIT---",
                    f"{current_ref}..{offered_ref}",
                ], timeout=10)
                if r.returncode != 0:
                    return []
            except Exception:
                return []
            notes = []
            for commit in (r.stdout or "").split("---END-COMMIT---"):
                lines = [line.strip() for line in commit.splitlines() if line.strip()]
                for line in lines:
                    lowered = line.lower()
                    if "breaking change" in lowered or lowered.startswith("breaking:") or lowered.startswith("breaking -"):
                        notes.append(line)
                        break
                if len(notes) >= 3:
                    break
            return notes

        def emit(payload):
            print(json.dumps(payload))
            sys.exit(0)

        hermes_bin = find_hermes_binary()
        if not hermes_bin:
            emit({
                "installed": False,
                "version_label": None,
                "behind": None,
                "source": "unknown",
                "current_version": None,
                "offered_version": None,
                "offered_version_label": None,
                "changelog_url": None,
                "breaking_changes": [],
            })

        # Version label: first non-empty line of `hermes version`.
        # Hermes' format is "Hermes Agent v<VERSION> (<RELEASE_DATE>) ..."
        # which is exactly what we want to render. We only need the first
        # line — the rest of `hermes version`'s output is dependency probes
        # and an update-check footer that we'd be re-running ourselves.
        version_label = None
        try:
            r = subprocess.run(
                [hermes_bin, "version"],
                capture_output=True, text=True, timeout=15,
            )
            for line in (r.stdout or "").splitlines():
                stripped = line.strip()
                if stripped:
                    version_label = stripped
                    break
        except Exception:
            pass

        current_version = parse_version(version_label)
        repo_root = find_git_root(hermes_bin)
        current_ref = None
        offered_ref = None
        offered_version = None
        offered_version_label = None
        offered_changelog_url = None
        offered_breaking_changes = []
        if repo_root:
            current_ref = git_text(repo_root, ["rev-parse", "HEAD"])
            offered_ref = upstream_ref(repo_root)
            if not current_version:
                current_version = version_from_ref(repo_root, current_ref or "HEAD")
            if offered_ref:
                offered_version = version_from_ref(repo_root, offered_ref)
                if offered_version:
                    offered_version_label = f"Hermes Agent v{offered_version}"
                offered_changelog_url = changelog_url(repo_root, current_ref, offered_ref)
                offered_breaking_changes = breaking_changes(repo_root, current_ref, offered_ref)

        # Detection: prefer the cache file Hermes itself maintains.
        # ~/.hermes/.update_check is { "ts": <epoch>, "behind": <int|None>, "rev": <str|None> }
        # written by hermes_cli/banner.py's check_for_updates() with a 6h TTL.
        # Cheap and offline-friendly — we don't have to spawn a second
        # subprocess just to ask a question Hermes already answered.
        cache_path = os.path.join(os.path.expanduser("~"), ".hermes", ".update_check")
        behind = None
        source = "unknown"
        now = time.time()
        try:
            if os.path.exists(cache_path):
                with open(cache_path, "r") as fh:
                    cached = json.loads(fh.read())
                ts = cached.get("ts", 0)
                if isinstance(ts, (int, float)) and (now - ts) < UPDATE_CACHE_TTL_SECONDS:
                    cached_behind = cached.get("behind")
                    if isinstance(cached_behind, int):
                        behind = cached_behind
                        source = "cache"
        except Exception:
            pass

        # Cache miss / stale → ask Hermes itself. `hermes update --check`
        # exits 0 if synced, 1 if behind, and writes the cache for next
        # time. We don't parse stdout for an exact commit count — exit
        # code is the canonical signal, and the cache will catch up on
        # the next poll (within 6h) once banner.py runs again.
        if behind is None:
            try:
                r = subprocess.run(
                    [hermes_bin, "update", "--check"],
                    capture_output=True, text=True, timeout=30,
                )
                if r.returncode == 0:
                    behind = 0
                    source = "fresh-check"
                elif r.returncode == 1:
                    behind = -1  # behind, count unknown without parsing stdout
                    source = "fresh-check"
            except Exception:
                pass

        emit({
            "installed": True,
            "version_label": version_label,
            "behind": behind,
            "source": source,
            "current_version": current_version,
            "offered_version": offered_version,
            "offered_version_label": offered_version_label,
            "changelog_url": offered_changelog_url,
            "breaking_changes": offered_breaking_changes,
        })
        """#
    }

    /// Generates the Python source for the actual update run. Exposed
    /// for testing.
    static func makeUpdateScript() -> String {
        return #"""
        import json
        import os
        import shutil
        import subprocess
        import sys

        def find_hermes_binary():
            path = shutil.which("hermes")
            if path:
                return path
            for candidate in [
                os.path.expanduser("~/.local/bin/hermes"),
                os.path.expanduser("~/.cargo/bin/hermes"),
                os.path.expanduser("~/.hermes/bin/hermes"),
                "/usr/local/bin/hermes",
                "/usr/bin/hermes",
            ]:
                if os.path.isfile(candidate) and os.access(candidate, os.X_OK):
                    return candidate
            return None

        def read_log_tail():
            log_path = os.path.join(os.path.expanduser("~"), ".hermes", "logs", "update.log")
            try:
                if os.path.exists(log_path):
                    with open(log_path, "r") as fh:
                        return fh.read()[-4000:]
            except Exception:
                pass
            return None

        def emit(exit_code, stdout_tail, stderr_tail):
            print(json.dumps({
                "exit_code": exit_code,
                "stdout_tail": stdout_tail[-4000:] if stdout_tail else "",
                "stderr_tail": stderr_tail[-4000:] if stderr_tail else "",
                "log_tail": read_log_tail(),
            }))
            sys.exit(0)

        hermes_bin = find_hermes_binary()
        if not hermes_bin:
            emit(127, "", "Hermes CLI not found on this host. Install Hermes from the Overview tab first.")

        # `hermes update --backup` is the documented update entry point:
        #   1. Snapshot pairing data (restorable via `hermes backup restore
        #      --state pre-update`)
        #   2. git pull --ff-only (with submodules)
        #   3. uv pip install -e ".[all]"
        #   4. Detect new config options
        #   5. Auto-restart any running gateway
        # The CLI ignores SIGHUP, so a dropped SSH session doesn't kill it.
        # We still cap our subprocess.run timeout to 270s to leave headroom
        # under our /exec server-side ceiling. If we hit the timeout, the
        # update may still be running on the VM — the next availability
        # probe will catch up.
        try:
            r = subprocess.run(
                [hermes_bin, "update", "--backup"],
                capture_output=True, text=True, timeout=270,
            )
            emit(r.returncode, r.stdout or "", r.stderr or "")
        except subprocess.TimeoutExpired as exc:
            stdout_tail = exc.stdout if isinstance(getattr(exc, "stdout", None), str) else ""
            emit(
                -1,
                stdout_tail or "",
                "hermes update --backup exceeded 270s and was aborted on this side. The update may still be running on the host — re-check in a minute.",
            )
        except Exception as exc:
            emit(-1, "", f"Failed to invoke hermes update: {exc}")
        """#
    }
}
