import Testing
@testable import OS1

struct SkillModelSourceTests {
    @Test
    func searchMatchesTagsDescriptionsAndRelatedSkills() {
        let summary = skillSummary(
            description: "Automates browser QA checks.",
            tags: ["browser", "QA"],
            relatedSkills: ["playwright"]
        )

        #expect(summary.matchesSearch("browser"))
        #expect(summary.matchesSearch("qa"))
        #expect(summary.matchesSearch("playwright"))
        #expect(summary.matchesSearch("automates"))
        #expect(!summary.matchesSearch("stripe"))
    }

    @Test
    func tagFilterUsesCaseInsensitiveTrimmedMatching() {
        let summary = skillSummary(tags: [" Browser ", "QA"])

        #expect(summary.matchesTag(nil))
        #expect(summary.matchesTag("browser"))
        #expect(summary.matchesTag("  BROWSER "))
        #expect(!summary.matchesTag("apple"))
    }

    @Test
    func localSkillBuildsWritableSourceAndPath() {
        let summary = SkillSummary(
            id: "devops/deploy-k8s",
            locator: SkillLocator(sourceID: "local", relativePath: "devops/deploy-k8s"),
            source: SkillSource(
                id: "local",
                kind: .local,
                rootPath: "~/.hermes/skills",
                isReadOnly: false
            ),
            slug: "deploy-k8s",
            category: "devops",
            relativePath: "devops/deploy-k8s",
            name: "Deploy Kubernetes",
            description: "Ship a manifest safely.",
            version: "1.0.0",
            tags: ["k8s"],
            relatedSkills: [],
            hasReferences: true,
            hasScripts: false,
            hasTemplates: true
        )

        #expect(summary.id == "devops/deploy-k8s")
        #expect(summary.locator.sourceID == "local")
        #expect(summary.source.kind == .local)
        #expect(summary.source.isReadOnly == false)
        #expect(summary.skillFilePath == "~/.hermes/skills/devops/deploy-k8s/SKILL.md")
    }

    @Test
    func externalSkillBuildsReadOnlyDetail() {
        let detail = SkillDetail(
            id: "team-conventions",
            locator: SkillLocator(sourceID: "external:1", relativePath: "team-conventions"),
            source: SkillSource(
                id: "external:1",
                kind: .external,
                rootPath: "~/.agents/skills",
                isReadOnly: true
            ),
            slug: "team-conventions",
            category: nil,
            relativePath: "team-conventions",
            name: "Team Conventions",
            description: "Shared standards.",
            version: nil,
            tags: [],
            relatedSkills: [],
            hasReferences: false,
            hasScripts: false,
            hasTemplates: false,
            markdownContent: "# Team Conventions\n",
            contentHash: "abc123"
        )

        #expect(detail.source.kind == .external)
        #expect(detail.isReadOnly)
        #expect(detail.sourceLabel == "External")
        #expect(detail.skillFilePath == "~/.agents/skills/team-conventions/SKILL.md")
    }

    private func skillSummary(
        description: String = "Ship a manifest safely.",
        tags: [String] = ["k8s"],
        relatedSkills: [String] = []
    ) -> SkillSummary {
        SkillSummary(
            id: "devops/deploy-k8s",
            locator: SkillLocator(sourceID: "local", relativePath: "devops/deploy-k8s"),
            source: SkillSource(
                id: "local",
                kind: .local,
                rootPath: "~/.hermes/skills",
                isReadOnly: false
            ),
            slug: "deploy-k8s",
            category: "devops",
            relativePath: "devops/deploy-k8s",
            name: "Deploy Kubernetes",
            description: description,
            version: "1.0.0",
            tags: tags,
            relatedSkills: relatedSkills,
            hasReferences: true,
            hasScripts: false,
            hasTemplates: true
        )
    }
}
