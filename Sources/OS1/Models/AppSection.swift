import Foundation

enum AppSection: String, CaseIterable, Identifiable {
    case connections
    case overview
    case files
    case sessions
    case cronjobs
    case kanban
    case usage
    case skills
    case knowledgeBase
    case terminal
    case desktop
    case tiles
    case codexTasks
    case mail
    case messaging
    case connectors
    case providers
    case doctor

    var id: String { rawValue }

    var title: String {
        L10n.string(titleKey)
    }

    var titleKey: String {
        switch self {
        case .connections:
            "Hosts"
        case .overview:
            "Overview"
        case .files:
            "Files"
        case .sessions:
            "Sessions"
        case .cronjobs:
            "Cron Jobs"
        case .kanban:
            "Kanban"
        case .usage:
            "Usage"
        case .skills:
            "Skills"
        case .knowledgeBase:
            "Knowledge Base"
        case .terminal:
            "Terminal"
        case .desktop:
            "Desktop"
        case .tiles:
            "Tiles"
        case .codexTasks:
            "Tasks"
        case .mail:
            "AgentMail"
        case .messaging:
            "Messaging"
        case .connectors:
            "Connectors"
        case .providers:
            "Providers"
        case .doctor:
            "Doctor"
        }
    }

    var systemImage: String {
        switch self {
        case .connections:
            "server.rack"
        case .overview:
            "waveform.path.ecg"
        case .files:
            "doc.text"
        case .sessions:
            "clock.arrow.circlepath"
        case .cronjobs:
            "calendar.badge.clock"
        case .kanban:
            "rectangle.3.group"
        case .usage:
            "chart.bar.xaxis"
        case .skills:
            "book.closed"
        case .knowledgeBase:
            "books.vertical.fill"
        case .terminal:
            "terminal"
        case .desktop:
            "display"
        case .tiles:
            "rectangle.split.2x2"
        case .codexTasks:
            "square.grid.2x2.fill"
        case .mail:
            "envelope"
        case .messaging:
            "paperplane.fill"
        case .connectors:
            "puzzlepiece.extension"
        case .providers:
            "cpu"
        case .doctor:
            "stethoscope"
        }
    }
}
