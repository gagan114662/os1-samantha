import Foundation

struct CustomerInterview: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var participant: String
    var transcript: String
    var painScore: Int
    var willingnessToPayUSD: Double?
}

struct FakeDoorExperiment: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var landingPageURL: URL
    var visitors: Int
    var signups: Int
    var checkoutClicks: Int
}

struct WillingnessToPaySurvey: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var responsesUSD: [Double]

    var medianWTPUSD: Double {
        guard !responsesUSD.isEmpty else { return 0 }
        let sorted = responsesUSD.sorted()
        let mid = sorted.count / 2
        return sorted.count.isMultiple(of: 2) ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
    }
}

struct PMFSignalScore: Codable, Hashable {
    var interviewPain: Double
    var fakeDoorConversion: Double
    var willingnessToPay: Double
    var total: Double
}

enum PMFSignalScorer {
    static func score(
        interviews: [CustomerInterview],
        fakeDoor: FakeDoorExperiment?,
        survey: WillingnessToPaySurvey?,
        targetPriceUSD: Double
    ) -> PMFSignalScore {
        let pain = interviews.isEmpty ? 0 : Double(interviews.map(\.painScore).reduce(0, +)) / Double(interviews.count * 10)
        let conversion = fakeDoor.map { door in
            Double(door.signups + door.checkoutClicks) / Double(max(1, door.visitors))
        } ?? 0
        let wtp = min(1, (survey?.medianWTPUSD ?? 0) / max(1, targetPriceUSD))
        let total = min(1, pain * 0.4 + conversion * 0.35 + wtp * 0.25)
        return PMFSignalScore(interviewPain: pain, fakeDoorConversion: conversion, willingnessToPay: wtp, total: total)
    }
}

struct ValidationGate: Codable, Hashable {
    enum State: String, Codable, CaseIterable, Hashable {
        case notStarted
        case interviewing
        case fakeDoorRunning
        case pricingSurvey
        case readyToBuild
        case blocked
    }

    var companyID: String
    var state: State
    var minimumScore: Double

    func decision(score: PMFSignalScore) -> State {
        score.total >= minimumScore ? .readyToBuild : .blocked
    }
}

enum CustomerInterviewRunner {
    static func summarizePain(_ interviews: [CustomerInterview]) -> String {
        let average = interviews.isEmpty ? 0 : Double(interviews.map(\.painScore).reduce(0, +)) / Double(interviews.count)
        return "interviews=\(interviews.count) average_pain=\(String(format: "%.1f", average))"
    }
}

enum FakeDoorRunner {
    static func conversionRate(_ experiment: FakeDoorExperiment) -> Double {
        Double(experiment.signups) / Double(max(1, experiment.visitors))
    }
}
