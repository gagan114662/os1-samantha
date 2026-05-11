import Foundation
import Testing
@testable import OS1

struct CompanyFacelessVideoPipelineTests {
    @Test
    func facelessVideoPipelineDraftsGatesAndRenders() {
        var access = CompanyAccessControl.lockedDown(companyID: "co")
        access.mediaProviderAllowlist = ["elevenlabs-tts", "json2video"]
        let job = FacelessVideoPipeline.draftJob(
            companyID: "co",
            topic: "roof replacement costs",
            outline: ["Hook with cost range", "Explain variables", "Offer quote checklist"]
        )
        let withAssets = FacelessVideoPipeline.attachRenderAssets(
            to: job,
            voiceProvider: "elevenlabs-tts",
            renderProvider: "json2video",
            accessControl: access
        )
        let decision = CompanyContentQualityDecision(
            status: .passed,
            score: .init(
                originalityScore: 1,
                hookStrength: 0.8,
                claimSafety: 0.9,
                brandFit: 0.8,
                readability: 0.9,
                plagiarismRisk: 0,
                hallucinationFlags: []
            ),
            flags: []
        )
        let rendered = FacelessVideoPipeline.render(withAssets, qualityDecision: decision)

        #expect(job.script.contains("Offer quote checklist"))
        #expect(withAssets.state == .assetsReady)
        #expect(rendered.state == CompanyFacelessVideoJob.State.rendered)
        #expect(rendered.assets.first { $0.kind == CompanyFacelessVideoAsset.Kind.render }?.approved == true)
    }
}
