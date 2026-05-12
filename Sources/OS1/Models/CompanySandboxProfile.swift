import Foundation

struct CompanySandboxProfile: Hashable {
    let companyID: String
    let worktreePath: String
    let logPath: String
    let promptPath: String
    let portfolioLessonsPath: String
    let codexHomePath: String
    let allowedCredentialNames: [String]

    func render() -> String {
        let readWritePaths = [
            worktreePath,
            logPath,
            promptPath,
            portfolioLessonsPath,
            codexHomePath,
            "/tmp",
            "/private/tmp"
        ].filter { !$0.isEmpty }.flatMap(Self.pathAliases)

        let readOnlyPaths = [
            "/bin",
            "/sbin",
            "/usr",
            "/System",
            "/Library",
            "/Applications",
            "/opt/homebrew"
        ].filter { !$0.isEmpty }.flatMap(Self.pathAliases)

        return """
        (version 1)
        (deny default)
        (import "system.sb")
        (import "com.apple.corefoundation.sb")
        (corefoundation)

        ; Process execution is needed for zsh, codex, git, and language/tool subprocesses.
        (allow process-exec*)
        (allow process-fork)
        (allow process-info* (target self))
        (allow sysctl-read)
        (allow mach-lookup)
        (allow mach-register)
        (allow ipc-posix-shm)
        (allow ipc-posix-sem)
        (allow network*)
        (allow file-read-metadata)

        ; System/tooling reads.
        \(readOnlyPaths.map { "(allow file-read* (subpath \"\(Self.profileEscape($0))\"))" }.joined(separator: "\n"))

        ; Company-scoped mutable state.
        \(readWritePaths.map { "(allow file-read* file-write* (subpath \"\(Self.profileEscape($0))\"))" }.joined(separator: "\n"))
        """
    }

    func write(to url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try render().write(to: url, atomically: true, encoding: .utf8)
    }

    static func profileEscape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
    }

    static func canonicalPath(_ value: String) -> String {
        let resolved = URL(fileURLWithPath: value).resolvingSymlinksInPath().path
        if resolved == "/var" || resolved.hasPrefix("/var/") {
            return "/private" + resolved
        }
        if resolved == "/tmp" || resolved.hasPrefix("/tmp/") {
            return "/private" + resolved
        }
        return resolved
    }

    static func pathAliases(_ value: String) -> [String] {
        let canonical = canonicalPath(value)
        return canonical == value ? [value] : [value, canonical]
    }
}
