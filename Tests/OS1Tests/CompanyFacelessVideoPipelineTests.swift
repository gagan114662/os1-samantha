import Foundation
import Testing
@testable import OS1

struct CompanyFacelessVideoPipelineTests {
    @Test
    func facelessVideoPipelineDraftsGatesAndRenders() {
        var access = CompanyAccessControl.lockedDown(companyID: "co")
        access.mediaProviderAllowlist = ["elevenlabs-tts", "fal-ai", "json2video"]
        let job = FacelessVideoPipeline.draftJob(
            companyID: "co",
            topic: "roof replacement costs",
            outline: ["Hook with cost range", "Explain variables", "Offer quote checklist"]
        )
        let withAssets = FacelessVideoPipeline.attachRenderAssets(
            to: job,
            voiceProvider: "elevenlabs-tts",
            videoProvider: "fal-ai",
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
        #expect(withAssets.assets.contains { $0.kind == .broll && $0.provider == "fal-ai" })
        #expect(rendered.state == CompanyFacelessVideoJob.State.rendered)
        #expect(rendered.assets.first { $0.kind == CompanyFacelessVideoAsset.Kind.render }?.approved == true)
    }

    @Test
    func facelessVideoFiveSecondSmokeTestUsesLLMTTSVideoAndRenderProviders() {
        var access = CompanyAccessControl.lockedDown(companyID: "smoke")
        access.mediaProviderAllowlist = ["elevenlabs-tts", "fal-ai", "json2video"]
        let job = FacelessVideoPipeline.draftJob(
            companyID: "smoke",
            topic: "fixture smoke",
            outline: ["LLM script fixture", "TTS narration fixture", "Video b-roll fixture"],
            durationSeconds: 5
        )
        let withAssets = FacelessVideoPipeline.attachRenderAssets(
            to: job,
            voiceProvider: "elevenlabs-tts",
            videoProvider: "fal-ai",
            renderProvider: "json2video",
            accessControl: access
        )
        let rendered = FacelessVideoPipeline.render(
            withAssets,
            qualityDecision: CompanyContentQualityDecision(
                status: .passed,
                score: .init(
                    originalityScore: 1,
                    hookStrength: 0.9,
                    claimSafety: 1,
                    brandFit: 0.9,
                    readability: 0.9,
                    plagiarismRisk: 0,
                    hallucinationFlags: []
                ),
                flags: []
            )
        )

        #expect(rendered.durationSeconds == 5)
        #expect(rendered.assets.contains { $0.kind == .script && $0.provider == "codex" })
        #expect(rendered.assets.contains { $0.kind == .voiceover && $0.provider == "elevenlabs-tts" })
        #expect(rendered.assets.contains { $0.kind == .broll && $0.provider == "fal-ai" })
        #expect(rendered.assets.contains { $0.kind == .render && $0.provider == "json2video" && $0.approved })
    }
}
