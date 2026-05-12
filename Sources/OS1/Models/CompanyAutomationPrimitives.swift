import Foundation

struct CompanySignalItem: Codable, Hashable, Identifiable {
    var id: String
    var title: String
    var url: URL?
    var noveltyKey: String
    var score: Double
}

struct CompanySignalWatcher: Codable, Hashable, Identifiable {
    enum DeliveryMode: String, Codable, CaseIterable, Hashable {
        case watchOnly
        case actViaApproval
        case autoAct
    }

    var id: String
    var companyID: String
    var source: String
    var schedule: String
    var noveltyKeyPath: String
    var deliveryMode: DeliveryMode
    var lastRunAt: Date?
}

struct CompanySignalSnapshot: Codable, Hashable {
    var watcherID: String
    var capturedAt: Date
    var items: [CompanySignalItem]
}

enum CompanySignalWatcherService {
    static func nextRun(after date: Date, everyHours: Int) -> Date {
        date.addingTimeInterval(Double(everyHours) * 3_600)
    }

    static func diff(previous: CompanySignalSnapshot?, current: CompanySignalSnapshot) -> [CompanySignalItem] {
        let seen = Set(previous?.items.map(\.noveltyKey) ?? [])
        return current.items.filter { !seen.contains($0.noveltyKey) }.sorted { $0.score > $1.score }
    }

    static func parseRSS(_ xml: String) -> [CompanySignalItem] {
        xml.components(separatedBy: "<item>").dropFirst().compactMap { raw in
            guard let title = raw.slice(between: "<title>", and: "</title>") else { return nil }
            let link = raw.slice(between: "<link>", and: "</link>").flatMap(URL.init(string:))
            return CompanySignalItem(id: title, title: title, url: link, noveltyKey: link?.absoluteString ?? title, score: 0.5)
        }
    }

    static func parseJSONAPI(_ data: Data) throws -> [CompanySignalItem] {
        struct Row: Decodable {
            let id: String
            let title: String
            let url: URL?
            let score: Double
        }
        return try JSONDecoder().decode([Row].self, from: data).map {
            CompanySignalItem(id: $0.id, title: $0.title, url: $0.url, noveltyKey: $0.id, score: $0.score)
        }
    }

    static func blocksPublishInWatchOnlyMode(watcher: CompanySignalWatcher, action: CompanyBrowserAction) -> Bool {
        watcher.deliveryMode == .watchOnly && action.kind == .publishDraft
    }
}

enum CompanyDigestDeliverer {
    enum Adapter: String, Codable, CaseIterable, Hashable {
        case telegram
        case email
    }

    static func render(adapter: Adapter, items: [CompanySignalItem], quietHours: ClosedRange<Int>, date: Date, maxDigestsPerDay: Int, sentToday: Int) -> String? {
        let hour = Calendar(identifier: .gregorian).component(.hour, from: date)
        guard !quietHours.contains(hour), sentToday < maxDigestsPerDay else { return nil }
        return items.prefix(3).enumerated().map { index, item in "\(index + 1). \(item.title) [\(String(format: "%.2f", item.score))]" }.joined(separator: "\n")
    }
}

struct CompanyRepurposedAsset: Codable, Hashable, Identifiable {
    var id: String
    var channel: CompanyGrowthCampaign.Channel
    var body: String
}

enum CompanyRepurposer {
    static func repurpose(source: String, channels: [CompanyGrowthCampaign.Channel]) -> [CompanyRepurposedAsset] {
        channels.map { channel in
            CompanyRepurposedAsset(id: "\(channel.rawValue)-\(abs(source.hashValue))", channel: channel, body: "\(prefix(for: channel)) \(source.prefix(220))")
        }
    }

    private static func prefix(for channel: CompanyGrowthCampaign.Channel) -> String {
        switch channel {
        case .xThread: return "Thread:"
        case .instagramReel, .tiktokVideo, .youtubeShort: return "Short script:"
        case .linkedinPost: return "Operator note:"
        case .pinterestPin: return "Pin:"
        default: return "Draft:"
        }
    }
}

struct CompanySocialMention: Codable, Hashable, Identifiable {
    var id: String
    var channel: CompanyGrowthCampaign.Channel
    var author: String
    var text: String
}

enum CompanySocialListener {
    static func sentiment(_ mention: CompanySocialMention) -> Double {
        let text = mention.text.lowercased()
        var score = 0.0
        if text.contains("love") || text.contains("great") { score += 0.7 }
        if text.contains("angry") || text.contains("scam") || text.contains("bad") { score -= 0.8 }
        return max(-1, min(1, score))
    }

    static func urgentMentions(_ mentions: [CompanySocialMention]) -> [CompanySocialMention] {
        mentions.filter { sentiment($0) < -0.5 || $0.text.lowercased().contains("refund") }
    }
}

struct CompanyInboundLead: Codable, Hashable, Identifiable {
    var id: String
    var companyID: String
    var receivedAt: Date
    var channel: String
    var message: String
}

enum CompanySpeedToLeadResponder {
    struct LeadResponseTask: Codable, Hashable, Identifiable {
        enum Priority: String, Codable, CaseIterable, Hashable {
            case normal
            case urgent
        }

        var id: String
        var companyID: String
        var priority: Priority
        var title: String
        var dueAt: Date
        var evidence: String
    }

    static func responseTask(lead: CompanyInboundLead, now: Date, slaSeconds: TimeInterval = 300) -> LeadResponseTask {
        LeadResponseTask(
            id: "lead-\(lead.id)",
            companyID: lead.companyID,
            priority: now.timeIntervalSince(lead.receivedAt) > slaSeconds ? .urgent : .normal,
            title: "Respond to inbound lead from \(lead.channel)",
            dueAt: lead.receivedAt.addingTimeInterval(slaSeconds),
            evidence: lead.message
        )
    }
}

struct CompanyTaskFanoutResult: Codable, Hashable {
    var taskID: String
    var workerID: String
    var score: Double
}

enum CompanyTaskFanout {
    static func assign(taskIDs: [String], workerIDs: [String]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: taskIDs.enumerated().map { offset, task in
            (task, workerIDs[offset % max(1, workerIDs.count)])
        })
    }
}

struct CompanyROIDashboard: Codable, Hashable {
    var companyID: String
    var hoursSaved: Double
    var profitUSD: Double
    var hourlyValueUSD: Double

    var leverageROI: Double {
        guard hoursSaved * hourlyValueUSD > 0 else { return 0 }
        return profitUSD / (hoursSaved * hourlyValueUSD)
    }
}

private extension String {
    func slice(between start: String, and end: String) -> String? {
        guard let startRange = range(of: start),
              let endRange = self[startRange.upperBound...].range(of: end)
        else { return nil }
        return String(self[startRange.upperBound..<endRange.lowerBound])
    }
}
