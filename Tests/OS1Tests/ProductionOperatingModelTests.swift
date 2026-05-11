import Foundation
import Testing
@testable import OS1

struct ProductionOperatingModelTests {
    @Test
    func productionOperatingModelContainsRequiredGateSections() throws {
        let url = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("docs/production-operating-model.md")
        let document = try String(contentsOf: url, encoding: .utf8)

        let missing = DoctorViewModel.productionOperatingModelMissingSections(in: document)

        #expect(missing.isEmpty)
    }

    @Test
    func productionOperatingModelCheckReportsMissingSections() {
        let missing = DoctorViewModel.productionOperatingModelMissingSections(in: """
        # OS1 + Samantha Production Operating Model
        Version: 1
        ## Autonomy Levels
        """)

        #expect(missing.contains("## Risk Tiers"))
        #expect(missing.contains("## Tool / Action Approval Matrix"))
        #expect(missing.contains("## Sandbox to Live Revenue Checklist"))
    }
}
