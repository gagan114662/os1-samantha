import Foundation

/// Legal entity tracked by the OS1 tax pipeline.
///
/// Entities live in `~/.os1/entities.json` and map every `CompanyLedgerEntry`
/// and `CompanyPaymentProviderEvent` to a single tax-reporting unit (operator
/// personal, an LLC, a Stripe Connect sub-account, etc).
///
/// See `docs/tax-export.md` for the on-disk schema.
struct TaxEntity: Codable, Hashable, Identifiable {
    var id: String
    var legalName: String
    var entityType: TaxEntityType
    var primaryJurisdiction: String
    var additionalJurisdictions: [String]
    var ein: String?
    var itin: String?
    var fiscalYearStartMonth: Int
    var incorporatedAt: Date?
    var dissolvedAt: Date?
    var baseCurrency: String
    var allocation: TaxJurisdictionAllocation

    init(
        id: String,
        legalName: String,
        entityType: TaxEntityType,
        primaryJurisdiction: String,
        additionalJurisdictions: [String] = [],
        ein: String? = nil,
        itin: String? = nil,
        fiscalYearStartMonth: Int = 1,
        incorporatedAt: Date? = nil,
        dissolvedAt: Date? = nil,
        baseCurrency: String = "USD",
        allocation: TaxJurisdictionAllocation = .primaryOnly
    ) {
        self.id = id
        self.legalName = legalName
        self.entityType = entityType
        self.primaryJurisdiction = primaryJurisdiction
        self.additionalJurisdictions = additionalJurisdictions.sorted()
        self.ein = ein
        self.itin = itin
        self.fiscalYearStartMonth = min(12, max(1, fiscalYearStartMonth))
        self.incorporatedAt = incorporatedAt
        self.dissolvedAt = dissolvedAt
        self.baseCurrency = baseCurrency
        self.allocation = allocation
    }

    var allJurisdictions: [String] {
        var seen = Set<String>()
        var result: [String] = []
        for code in [primaryJurisdiction] + additionalJurisdictions where seen.insert(code).inserted {
            result.append(code)
        }
        return result.sorted()
    }
}

enum TaxEntityType: String, Codable, Hashable {
    case soleProprietor       = "sole-proprietor"
    case llcSingleMember      = "llc-single-member"
    case llcMultiMember       = "llc-multi-member"
    case cCorp                = "c-corp"
    case sCorp                = "s-corp"
    case foreignEntity        = "foreign-entity"

    /// Schedule C filers report on Form 1040; corporations use Form 1120.
    var usFederalForm: String {
        switch self {
        case .soleProprietor, .llcSingleMember:
            return "Schedule C"
        case .cCorp:
            return "Form 1120"
        case .sCorp:
            return "Form 1120-S"
        case .llcMultiMember:
            return "Form 1065"
        case .foreignEntity:
            return "Form 1120-F"
        }
    }
}

/// Rule for splitting an entity's income across multiple jurisdictions.
///
/// `.primaryOnly` — all unallocated entries land in `primaryJurisdiction`.
/// `.equalSplit` — every active jurisdiction receives an equal share.
/// `.revenueProportional` — caller supplies explicit weights (per jurisdiction).
///   Weights are normalized to sum to 1.0; missing jurisdictions get 0.
enum TaxJurisdictionAllocation: Codable, Hashable {
    case primaryOnly
    case equalSplit
    case revenueProportional(weights: [String: Double])

    private enum CodingKeys: String, CodingKey { case kind, weights }
    private enum Kind: String, Codable { case primaryOnly, equalSplit, revenueProportional }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .primaryOnly:
            self = .primaryOnly
        case .equalSplit:
            self = .equalSplit
        case .revenueProportional:
            let weights = try container.decode([String: Double].self, forKey: .weights)
            self = .revenueProportional(weights: weights)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .primaryOnly:
            try container.encode(Kind.primaryOnly, forKey: .kind)
        case .equalSplit:
            try container.encode(Kind.equalSplit, forKey: .kind)
        case let .revenueProportional(weights):
            try container.encode(Kind.revenueProportional, forKey: .kind)
            try container.encode(weights, forKey: .weights)
        }
    }
}

/// Persistent registry: `~/.os1/entities.json`.
struct TaxEntityRegistry: Codable, Hashable {
    var entities: [TaxEntity]
    var companyToEntity: [String: String]

    init(entities: [TaxEntity] = [], companyToEntity: [String: String] = [:]) {
        self.entities = entities.sorted { $0.id < $1.id }
        self.companyToEntity = companyToEntity
    }

    func entity(forCompany companyID: String?) -> TaxEntity? {
        guard let companyID, let entityID = companyToEntity[companyID] else { return nil }
        return entities.first { $0.id == entityID }
    }

    static let fileName = "entities.json"
}
