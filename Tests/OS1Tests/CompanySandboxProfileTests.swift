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

    private func runSandboxedCat(sandboxExec: String, profile: String, path: String) -> (exitCode: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: sandboxExec)
        process.arguments = ["-f", profile, "/bin/cat", path]
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
}
