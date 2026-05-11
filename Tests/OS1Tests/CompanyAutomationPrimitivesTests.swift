import Foundation
import Testing
@testable import OS1

struct CompanyAutomationPrimitivesTests {
    @Test
    func signalWatcherDiffsDedupesAndSortsByScore() throws {
        let previous = CompanySignalSnapshot(
            watcherID: "w",
            capturedAt: Date(timeIntervalSince1970: 1),
            items: [.init(id: "a", title: "Old", url: nil, noveltyKey: "old", score: 0.9)]
        )
        let current = CompanySignalSnapshot(
            watcherID: "w",
            capturedAt: Date(timeIntervalSince1970: 2),
            items: [
                .init(id: "a", title: "Old again", url: nil, noveltyKey: "old", score: 1),
                .init(id: "b", title: "New low", url: nil, noveltyKey: "low", score: 0.2),
                .init(id: "c", title: "New high", url: nil, noveltyKey: "high", score: 0.8)
            ]
        )

        let diff = CompanySignalWatcherService.diff(previous: previous, current: current)

        #expect(diff.map(\.noveltyKey) == ["high", "low"])
        #expect(CompanySignalWatcherService.nextRun(after: Date(timeIntervalSince1970: 0), everyHours: 6).timeIntervalSince1970 == 21_600)
    }

    @Test
    func rssAndJSONAdaptersParseSignalItems() throws {
        let rss = CompanySignalWatcherService.parseRSS("<rss><item><title>Hiring spike</title><link>https://example.com/job</link></item></rss>")
        let json = try CompanySignalWatcherService.parseJSONAPI(Data(#"[{"id":"1","title":"Domain drop","url":"https://example.com/domain","score":0.9}]"#.utf8))

        #expect(rss.first?.title == "Hiring spike")
        #expect(json.first?.score == 0.9)
    }

    @Test
    func digestQuietHoursRateCapsAndWatchOnlyBlocksPublish() {
        let items = [
            CompanySignalItem(id: "1", title: "A", url: nil, noveltyKey: "a", score: 0.9),
            CompanySignalItem(id: "2", title: "B", url: nil, noveltyKey: "b", score: 0.8),
            CompanySignalItem(id: "3", title: "C", url: nil, noveltyKey: "c", score: 0.7)
        ]
        let allowed = CompanyDigestDeliverer.render(adapter: .telegram, items: items, quietHours: 0...6, date: Date(timeIntervalSince1970: 50_000), maxDigestsPerDay: 2, sentToday: 0)
        let blocked = CompanyDigestDeliverer.render(adapter: .email, items: items, quietHours: 0...23, date: Date(), maxDigestsPerDay: 2, sentToday: 0)
        let watcher = CompanySignalWatcher(id: "w", companyID: "co", source: "rss", schedule: "daily", noveltyKeyPath: "link", deliveryMode: .watchOnly, lastRunAt: nil)
        let action = CompanyBrowserAction(id: "a", companyID: "co", domain: "example.com", kind: .publishDraft, actionName: "publish", semanticTarget: "button", selector: "#publish", expectedResult: "published")

        #expect(allowed?.contains("1. A") == true)
        #expect(blocked == nil)
        #expect(CompanySignalWatcherService.blocksPublishInWatchOnlyMode(watcher: watcher, action: action))
    }

    @Test
    func repurposerCreatesPlatformSpecificAssetsAndListenerFindsUrgentMentions() {
        let assets = CompanyRepurposer.repurpose(source: "Long essay about roofing estimates", channels: [.xThread, .instagramReel, .linkedinPost])
        let mentions = [
            CompanySocialMention(id: "m1", channel: .xPost, author: "a", text: "love this"),
            CompanySocialMention(id: "m2", channel: .xPost, author: "b", text: "angry customer wants refund")
        ]

        #expect(assets.count == 3)
        #expect(assets.first { $0.channel == .instagramReel }?.body.contains("Short script") == true)
        #expect(CompanySocialListener.urgentMentions(mentions).map(\.id) == ["m2"])
    }

    @Test
    func speedToLeadSwarmAndROIDashboardWork() {
        let lead = CompanyInboundLead(id: "l1", companyID: "co", receivedAt: Date(timeIntervalSince1970: 0), channel: "form", message: "I need a quote")
        let task = CompanySpeedToLeadResponder.responseTask(lead: lead, now: Date(timeIntervalSince1970: 600))
        let assignments = CompanyTaskFanout.assign(taskIDs: ["a", "b", "c"], workerIDs: ["w1", "w2"])
        let roi = CompanyROIDashboard(companyID: "co", hoursSaved: 10, profitUSD: 500, hourlyValueUSD: 50)

        #expect(task.priority == .urgent)
        #expect(assignments["c"] == "w1")
        #expect(roi.leverageROI == 1)
    }
}
