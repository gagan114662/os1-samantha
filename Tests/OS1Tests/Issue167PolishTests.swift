import Testing
@testable import OS1

struct Issue167PolishTests {
    @Test
    func sidebarLabelsMatchDestinationPageTitles() {
        let expectedTitleKeys: [AppSection: String] = [
            .connections: "Hosts",
            .overview: "Overview",
            .files: "Files",
            .sessions: "Sessions",
            .cronjobs: "Cron Jobs",
            .kanban: "Kanban",
            .usage: "Usage",
            .skills: "Skills",
            .knowledgeBase: "Knowledge Base",
            .terminal: "Terminal",
            .desktop: "Desktop",
            .tiles: "Tiles",
            .codexTasks: "Tasks",
            .mail: "AgentMail",
            .messaging: "Messaging",
            .connectors: "Connectors",
            .providers: "Providers",
            .doctor: "Doctor"
        ]

        #expect(Set(expectedTitleKeys.keys) == Set(AppSection.allCases))

        for section in AppSection.allCases {
            #expect(section.titleKey == expectedTitleKeys[section])
        }
    }

    @Test
    func citedMetadataDisplayFormattingStaysReadable() {
        #expect(UIDisplayFormatting.computerCountLabelKey(for: 1) == "%lld computer")
        #expect(L10n.string(UIDisplayFormatting.computerCountLabelKey(for: 1), 1) == "1 computer")
        #expect(UIDisplayFormatting.computerCountLabelKey(for: 2) == "%lld computers")
        #expect(UIDisplayFormatting.shortComputerID("a7cf78dd-66a8-43d8-8f14-ba00c307acf2") == "a7cf78dd")
        #expect(UIDisplayFormatting.shortComputerID(" short ") == "short")
        #expect(UIDisplayFormatting.readableHomeFolder("-") == "(not set)")
        #expect(UIDisplayFormatting.readableHomeFolder("   ") == "(not set)")
        #expect(UIDisplayFormatting.readableHomeFolder("/Users/hermes") == "/Users/hermes")
        #expect(
            UIDisplayFormatting.providerCapacityLine(modality: "Text", quota: "account plan") ==
                "Text · Quota: account plan · Cost-to-date: ledger tracked"
        )
        #expect(
            UIDisplayFormatting.providerCapacityLine(modality: "Voice", quota: " ") ==
                "Voice · Quota: account plan · Cost-to-date: ledger tracked"
        )
    }
}
