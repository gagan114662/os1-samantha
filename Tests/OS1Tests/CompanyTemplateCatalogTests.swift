import Foundation
import Testing
@testable import OS1

struct CompanyTemplateCatalogTests {
    @Test
    func catalogContainsAtLeastOneHundredTwentyFiveTemplates() {
        #expect(CompanyTemplateCatalog.all.count >= 125)
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

    @Test
    func socialPlatformTemplatesCoverFivePlatformsAndRoundTrip() throws {
        for platform in CompanyTemplate.Platform.allCases {
            let templates = CompanyTemplateCatalog.all.filter { $0.platform == platform }
            #expect(templates.count >= 5, "\(platform.rawValue) needs at least five templates.")
            for template in templates {
                #expect(template.validationSignals.count >= 3)
                #expect(template.launchAssets.count >= 3)
                #expect(!template.riskNotes.isEmpty)

                let data = try JSONEncoder().encode(template)
                let decoded = try JSONDecoder().decode(CompanyTemplate.self, from: data)
                #expect(decoded == template)
                #expect(!decoded.companyName.isEmpty)
            }
        }
    }

    @Test
    func watcherArbitrageTemplateFamilyIsPresent() {
        let required: Set<String> = [
            "watcher-domain-flipper",
            "watcher-local-liquidation",
            "watcher-hiring-signal",
            "watcher-sunset-saas",
            "watcher-dying-app-store",
            "watcher-competitive-intel"
        ]
        let ids = Set(CompanyTemplateCatalog.all.map(\.id))

        #expect(required.isSubset(of: ids))
        for id in required {
            let template = CompanyTemplateCatalog.template(id: id)
            #expect(template?.searchText.contains("watch") == true || template?.searchText.contains("signal") == true || template?.searchText.contains("digest") == true)
        }
    }
}
