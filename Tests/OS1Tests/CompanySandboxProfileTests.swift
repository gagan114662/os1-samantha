import Foundation
import Testing
@testable import OS1

struct CompanySandboxProfileTests {
    @Test
    func sandboxAllowsOwnWorktreeAndBlocksOtherCompanyAndSecrets() throws {
        let sandboxExec = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: sandboxExec) else { return }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-sandbox-test-\(UUID().uuidString)", isDirectory: true)
        let own = root.appendingPathComponent("company-a", isDirectory: true)
        let other = root.appendingPathComponent("company-b", isDirectory: true)
        let secrets = root.appendingPathComponent("secrets", isDirectory: true)
        try FileManager.default.createDirectory(at: own, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let ownFile = own.appendingPathComponent("JOURNAL.md")
        let otherFile = other.appendingPathComponent("JOURNAL.md")
        let secretFile = secrets.appendingPathComponent("api-key.txt")
        try "own company".write(to: ownFile, atomically: true, encoding: .utf8)
        try "other company".write(to: otherFile, atomically: true, encoding: .utf8)
        try "secret".write(to: secretFile, atomically: true, encoding: .utf8)

        let profileURL = root.appendingPathComponent("company-a.sb")
        let profile = CompanySandboxProfile(
            companyID: "company-a",
            worktreePath: own.path,
            logPath: own.appendingPathComponent("company-a.log").path,
            promptPath: own.appendingPathComponent("prompt.txt").path,
            portfolioLessonsPath: own.appendingPathComponent("LESSONS.md").path,
            codexHomePath: own.appendingPathComponent(".codex").path,
            allowedCredentialNames: []
        )
        try profile.write(to: profileURL)

        let ownResult = runSandboxedCat(sandboxExec: sandboxExec, profile: profileURL.path, path: ownFile.path)
        let otherResult = runSandboxedCat(sandboxExec: sandboxExec, profile: profileURL.path, path: otherFile.path)
        let secretResult = runSandboxedCat(sandboxExec: sandboxExec, profile: profileURL.path, path: secretFile.path)

        #expect(ownResult.exitCode == 0)
        #expect(ownResult.output.contains("own company"))
        #expect(otherResult.exitCode != 0)
        #expect(secretResult.exitCode != 0)
    }

    @Test
    func sandboxProfileEscapesStringLiterals() {
        #expect(CompanySandboxProfile.profileEscape(#"/tmp/a "quoted" path"#) == #"/tmp/a \"quoted\" path"#)
        #expect(CompanySandboxProfile.profileEscape(#"/tmp/a\b"#) == #"/tmp/a\\b"#)
    }

    @Test
    func sandboxProfileAllowsCodexHomeTempAndIPCForCliStartup() {
        let profile = CompanySandboxProfile(
            companyID: "company-a",
            worktreePath: "/Users/test/.os1/codex-tasks/sessions/company-a",
            logPath: "/Users/test/.os1/codex-tasks/logs/company-a.log",
            promptPath: "/Users/test/.os1/codex-tasks/logs/company-a.heartbeat-1.prompt",
            portfolioLessonsPath: "/Users/test/.os1/codex-tasks/lessons/portfolio.md",
            codexHomePath: "/Users/test/.codex",
            allowedCredentialNames: []
        ).render()

        #expect(profile.contains(#"(allow file-read* file-write* (subpath "/Users/test/.codex"))"#))
        #expect(profile.contains(#"(allow file-read* file-write* (subpath "/private/tmp"))"#))
        #expect(profile.contains("(allow ipc-posix-shm)"))
        #expect(profile.contains("(allow ipc-posix-sem)"))
        #expect(profile.contains("(allow mach-register)"))
    }

    @Test
    func liveSandboxedCodexExecInitializesAndWritesJournal() throws {
        guard ProcessInfo.processInfo.environment["OS1_LIVE_CODEX_SMOKE"] == "1" else { return }
        let sandboxExec = "/usr/bin/sandbox-exec"
        guard FileManager.default.isExecutableFile(atPath: sandboxExec) else {
            throw NSError(
                domain: "OS1LiveCodexSmoke",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "sandbox-exec is not executable on this host."]
            )
        }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("os1-codex-live-smoke-\(UUID().uuidString)", isDirectory: true)
        let worktree = root.appendingPathComponent("worktree", isDirectory: true)
        let logs = root.appendingPathComponent("logs", isDirectory: true)
        let lessons = root.appendingPathComponent("lessons", isDirectory: true)
        let temp = worktree.appendingPathComponent(".tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: worktree, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: lessons, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let journal = worktree.appendingPathComponent("JOURNAL.md")
        let prompt = logs.appendingPathComponent("heartbeat.prompt")
        let log = logs.appendingPathComponent("company.log")
        let profileURL = root.appendingPathComponent("company.sb")
        let lessonsFile = lessons.appendingPathComponent("portfolio.md")
        let marker = "SANDBOX_SMOKE_OK"

        try "# Live Codex sandbox smoke\n".write(to: journal, atomically: true, encoding: .utf8)
        try "# Portfolio lessons\n".write(to: lessonsFile, atomically: true, encoding: .utf8)
        try """
        Append exactly this line to JOURNAL.md:
        \(marker)
        Do not change any other file.
        """
        .write(to: prompt, atomically: true, encoding: .utf8)

        let profile = CompanySandboxProfile(
            companyID: "live-codex-smoke",
            worktreePath: worktree.path,
            logPath: log.path,
            promptPath: prompt.path,
            portfolioLessonsPath: lessonsFile.path,
            codexHomePath: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path,
            allowedCredentialNames: []
        )
        try profile.write(to: profileURL)

        let command = "cat \(Self.shellEscape(prompt.path)) | codex exec --dangerously-bypass-approvals-and-sandbox -"
        let result = runSandboxedShell(
            sandboxExec: sandboxExec,
            profile: profileURL.path,
            worktree: worktree,
            command: command,
            temp: temp,
            timeoutSeconds: 180
        )
        try result.output.write(to: log, atomically: true, encoding: .utf8)

        #expect(result.exitCode == 0, "codex smoke failed: \(result.output.suffix(1200))")
        let journalText = try String(contentsOf: journal, encoding: .utf8)
        #expect(journalText.contains(marker), "JOURNAL.md missing \(marker). Log tail: \(result.output.suffix(1200))")
    }

    private func runSandboxedCat(
        sandboxExec: String,
        profile: String,
        path: String
    ) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxExec)
        process.arguments = ["-f", profile, "/bin/cat", path]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "LLVM_PROFILE_FILE")
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return (-1, error.localizedDescription)
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private func runSandboxedShell(
        sandboxExec: String,
        profile: String,
        worktree: URL,
        command: String,
        temp: URL,
        timeoutSeconds: TimeInterval
    ) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.currentDirectoryURL = worktree
        process.executableURL = URL(fileURLWithPath: sandboxExec)
        process.arguments = ["-f", profile, "/usr/bin/env", "zsh", "-l", "-c", command]
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "LLVM_PROFILE_FILE")
        environment["TMPDIR"] = temp.path
        environment["TMP"] = temp.path
        environment["TEMP"] = temp.path
        process.environment = environment
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            return (-1, error.localizedDescription)
        }

        let deadline = DispatchTime.now() + timeoutSeconds
        DispatchQueue.global().asyncAfter(deadline: deadline) {
            if process.isRunning {
                process.terminate()
            }
        }
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    private static func shellEscape(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
