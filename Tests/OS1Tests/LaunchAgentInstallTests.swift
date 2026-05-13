import Foundation
import Testing
@testable import OS1

struct LaunchAgentInstallTests {
    @Test
    func launchdTemplatesRenderAndReportMissingInstalledPlists() throws {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)
        let reports = DoctorViewModel.launchAgentDriftReports(
            repoRoot: repoRoot,
            home: home,
            installedDirectory: repoRoot.appendingPathComponent("missing-launch-agents", isDirectory: true)
        )

        #expect(reports.count == DoctorViewModel.launchAgentLabels.count)
        #expect(reports.allSatisfy { $0.expectedHash.count == 64 })

        let wuphf = try #require(reports.first { $0.label == "com.os1.wuphf" })
        #expect(wuphf.problem?.contains("missing installed plist") == true)
        #expect(!wuphf.expectedHash.isEmpty)

        let rendered = DoctorViewModel.renderLaunchAgentTemplate(
            "__OS1_REPO_ROOT__ __OS1_HOME__ __OS1_PATH__",
            repoRoot: repoRoot.path,
            home: home.path,
            path: "/opt/homebrew/bin:/usr/bin"
        )
        #expect(!rendered.contains("__OS1_"))
        #expect(rendered.contains("/opt/homebrew/bin:/usr/bin"))
    }

    @Test
    func launchdDirectoryDoesNotCommitHardcodedUserPlists() throws {
        let repoRoot = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let launchd = repoRoot.appendingPathComponent("launchd", isDirectory: true)
        let files = try FileManager.default.contentsOfDirectory(
            at: launchd,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )

        for file in files {
            let body = try String(contentsOf: file, encoding: .utf8)
            #expect(!body.contains("/Users/"), "Hardcoded user path in \(file.lastPathComponent)")
        }

        let templates = files.filter { $0.lastPathComponent.hasSuffix(".plist.template") }
        #expect(templates.count == DoctorViewModel.launchAgentLabels.count)
        for template in templates {
            let body = try String(contentsOf: template, encoding: .utf8)
            #expect(body.contains("__OS1_HOME__"))
            #expect(!body.contains("/Users/gaganarora"))
        }
    }
}
