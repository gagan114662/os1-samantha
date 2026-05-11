import Foundation
import Testing
@testable import OS1

struct CompanyTemplateCatalogTests {
    @Test
    func catalogContainsOneHundredTemplates() {
        #expect(CompanyTemplateCatalog.all.count == 100)
    }

    @Test
    func templateIDsAreUnique() {
        let ids = CompanyTemplateCatalog.all.map(\.id)
        #expect(ids.count == Set(ids).count, "Company template IDs must be unique.")
    }

    @Test
    func templatesHaveEnoughExecutionDetail() {
        for template in CompanyTemplateCatalog.all {
            #expect(!template.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(!template.companyName.isEmpty)
            #expect(!template.mission.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            #expect(template.validationSignals.count >= 3, "\(template.id) needs at least 3 validation signals.")
            #expect(template.launchAssets.count >= 3, "\(template.id) needs at least 3 launch assets.")
            #expect(!template.riskNotes.isEmpty, "\(template.id) needs risk notes.")
            #expect(template.missionPrompt.contains("Validation signals to collect before scaling"))
            #expect(template.missionPrompt.contains("Launch assets to create"))
            #expect(template.missionPrompt.contains("Risk notes and constraints"))
        }
    }

    @Test
    func initialCatalogCoversAllExecutionClusters() {
        let categories = Set(CompanyTemplateCatalog.all.map(\.category))
        #expect(categories == Set(CompanyTemplate.Category.allCases))
    }
}
