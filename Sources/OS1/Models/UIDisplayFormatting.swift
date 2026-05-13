import Foundation

enum UIDisplayFormatting {
    static func computerCountLabelKey(for count: Int) -> String {
        count == 1 ? "%lld computer" : "%lld computers"
    }

    static func shortComputerID(_ computerID: String) -> String {
        let trimmed = computerID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 8 else { return trimmed }
        return String(trimmed.prefix(8))
    }

    static func readableHomeFolder(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed == "-" ? L10n.string("(not set)") : value
    }

    static func providerCapacityLine(modality: String, quota: String?) -> String {
        let trimmedQuota = quota?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let resolvedQuota = trimmedQuota.isEmpty ? L10n.string("account plan") : trimmedQuota
        return L10n.string("%@ · Quota: %@ · Cost-to-date: ledger tracked", modality, resolvedQuota)
    }
}
