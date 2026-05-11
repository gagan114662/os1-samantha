import Foundation

struct CompanyCRMAccount: Codable, Hashable, Identifiable {
    let id: String
    var companyID: String
    var name: String
    var owner: String
    var notes: String
}

struct CompanyContactSource: Codable, Hashable {
    var source: String
    var capturedAt: Date
    var campaignID: String?
    var evidenceURL: URL?

    var isValid: Bool {
        !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct CompanyCRMContact: Codable, Hashable, Identifiable {
    enum ConsentBasis: String, Codable, CaseIterable, Hashable {
        case explicitOptIn
        case existingCustomer
        case legitimateInterest
        case noConsent
        case unknown

        var allowsOutbound: Bool {
            switch self {
            case .explicitOptIn, .existingCustomer, .legitimateInterest:
                return true
            case .noConsent, .unknown:
                return false
            }
        }
    }

    enum LifecycleStage: String, Codable, CaseIterable, Hashable {
        case lead
        case trial
        case customer
        case churned
        case blocked
        case suppressed
        case deleted
    }

    let id: String
    var companyID: String
    var accountID: String?
    var email: String
    var name: String
    var source: CompanyContactSource
    var consentBasis: ConsentBasis
    var lifecycleStage: LifecycleStage
    var owner: String
    var notes: String
    var linkedLedgerEntryIDs: [String]
    var linkedSupportTicketIDs: [String]
    var linkedCampaignEventIDs: [String]
    var deletedAt: Date?

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var hasRequiredOutboundMetadata: Bool {
        !normalizedEmail.isEmpty && source.isValid && consentBasis.allowsOutbound && deletedAt == nil
    }

    var isSuppressedLifecycle: Bool {
        lifecycleStage == .blocked || lifecycleStage == .suppressed || lifecycleStage == .deleted
    }
}

struct CompanySuppressionEntry: Codable, Hashable, Identifiable {
    enum Reason: String, Codable, CaseIterable, Hashable {
        case unsubscribe
        case bounce
        case complaint
        case manualDoNotContact
    }

    let id: String
    var email: String
    var reason: Reason
    var sourceCompanyID: String?
    var recordedAt: Date

    var normalizedEmail: String {
        email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

struct CompanyCRMExport: Codable, Hashable {
    var contact: CompanyCRMContact
    var account: CompanyCRMAccount?
    var exportedAt: Date
}

enum CompanyCRMEngine {
    static func eligibleOutboundTargets(
        contacts: [CompanyCRMContact],
        suppressions: [CompanySuppressionEntry]
    ) -> [CompanyCRMContact] {
        contacts.filter { contact in
            contact.hasRequiredOutboundMetadata &&
                !contact.isSuppressedLifecycle &&
                !isSuppressed(contact.normalizedEmail, suppressions: suppressions)
        }
    }

    static func isSuppressed(_ email: String, suppressions: [CompanySuppressionEntry]) -> Bool {
        let normalized = email.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return suppressions.contains { $0.normalizedEmail == normalized }
    }

    static func deduplicate(_ contacts: [CompanyCRMContact]) -> [CompanyCRMContact] {
        var ordered: [String] = []
        var byEmail: [String: CompanyCRMContact] = [:]
        for contact in contacts {
            let key = contact.normalizedEmail
            guard !key.isEmpty else { continue }
            if var existing = byEmail[key] {
                existing.linkedLedgerEntryIDs = merged(existing.linkedLedgerEntryIDs, contact.linkedLedgerEntryIDs)
                existing.linkedSupportTicketIDs = merged(
                    existing.linkedSupportTicketIDs,
                    contact.linkedSupportTicketIDs
                )
                existing.linkedCampaignEventIDs = merged(
                    existing.linkedCampaignEventIDs,
                    contact.linkedCampaignEventIDs
                )
                if existing.consentBasis == .unknown { existing.consentBasis = contact.consentBasis }
                if existing.source.source.isEmpty { existing.source = contact.source }
                if !contact.notes.isEmpty {
                    existing.notes = [existing.notes, contact.notes]
                        .filter { !$0.isEmpty }
                        .joined(separator: "\n")
                }
                byEmail[key] = existing
            } else {
                ordered.append(key)
                byEmail[key] = contact
            }
        }
        return ordered.compactMap { byEmail[$0] }
    }

    static func exportContact(
        id: String,
        contacts: [CompanyCRMContact],
        accounts: [CompanyCRMAccount],
        exportedAt: Date = Date()
    ) -> CompanyCRMExport? {
        guard let contact = contacts.first(where: { $0.id == id }) else { return nil }
        return .init(
            contact: contact,
            account: contact.accountID.flatMap { accountID in accounts.first { $0.id == accountID } },
            exportedAt: exportedAt
        )
    }

    static func deleted(_ contact: CompanyCRMContact, at deletedAt: Date = Date()) -> CompanyCRMContact {
        var copy = contact
        copy.email = ""
        copy.name = ""
        copy.notes = ""
        copy.lifecycleStage = .deleted
        copy.deletedAt = deletedAt
        return copy
    }

    private static func merged(_ lhs: [String], _ rhs: [String]) -> [String] {
        Array(Set(lhs + rhs)).sorted()
    }
}
