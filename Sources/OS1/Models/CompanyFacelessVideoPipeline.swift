import Foundation

struct CompanyFacelessVideoAsset: Codable, Hashable, Identifiable {
    enum Kind: String, Codable, CaseIterable, Hashable {
        case script
        case voiceover
        case broll
        case captions
        case render
        case thumbnail
    }

    let id: String
    var companyID: String
    var kind: Kind
    var path: String
    var provider: String
    var approved: Bool
}

struct CompanyFacelessVideoJob: Codable, Hashable, Identifiable {
    enum State: String, Codable, CaseIterable, Hashable {
        case drafted
        case assetsReady
        case renderQueued
        case rendered
        case blocked
    }

    let id: String
    var companyID: String
    var topic: String
    var durationSeconds: Int
    var script: String
    var assets: [CompanyFacelessVideoAsset]
    var state: State
    var qualityDecision: CompanyContentQualityDecision?
}

enum FacelessVideoPipeline {
    static func draftJob(companyID: String, topic: String, outline: [String], durationSeconds: Int = 45) -> CompanyFacelessVideoJob {
        let script = outline.enumerated().map { index, line in "\(index + 1). \(line)" }.joined(separator: "\n")
        return CompanyFacelessVideoJob(
            id: "video-\(companyID)-\(CompanyEvent.inputHash(for: topic).prefix(8))",
            companyID: companyID,
            topic: topic,
            durationSeconds: durationSeconds,
            script: script,
            assets: [
                .init(id: "script", companyID: companyID, kind: .script, path: "video/script.md", provider: "codex", approved: true),
                .init(id: "captions", companyID: companyID, kind: .captions, path: "video/captions.srt", provider: "codex", approved: true)
            ],
            state: .drafted,
            qualityDecision: nil
        )
    }

    static func attachRenderAssets(
        to job: CompanyFacelessVideoJob,
        voiceProvider: String,
        videoProvider: String = "fal-ai",
        renderProvider: String,
        accessControl: CompanyAccessControl
    ) -> CompanyFacelessVideoJob {
        var copy = job
        guard accessControl.mediaProviderAllowlist.contains(voiceProvider),
              accessControl.mediaProviderAllowlist.contains(videoProvider),
              accessControl.mediaProviderAllowlist.contains(renderProvider) else {
            copy.state = .blocked
            return copy
        }
        copy.assets.append(.init(id: "voiceover", companyID: job.companyID, kind: .voiceover, path: "video/voiceover.wav", provider: voiceProvider, approved: true))
        copy.assets.append(.init(id: "broll", companyID: job.companyID, kind: .broll, path: "video/broll.mp4", provider: videoProvider, approved: true))
        copy.assets.append(.init(id: "render", companyID: job.companyID, kind: .render, path: "video/final.mp4", provider: renderProvider, approved: false))
        copy.state = .assetsReady
        return copy
    }

    static func render(_ job: CompanyFacelessVideoJob, qualityDecision: CompanyContentQualityDecision) -> CompanyFacelessVideoJob {
        var copy = job
        copy.qualityDecision = qualityDecision
        copy.state = qualityDecision.status == .blocked ? .blocked : .rendered
        copy.assets = copy.assets.map { asset in
            guard asset.kind == .render else { return asset }
            var approved = asset
            approved.approved = qualityDecision.status != .blocked
            return approved
        }
        return copy
    }
}
