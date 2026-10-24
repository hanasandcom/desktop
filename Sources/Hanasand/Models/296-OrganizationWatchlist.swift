import Foundation

enum OrganizationWatchlistKind: String, CaseIterable, Codable { case company, domain, vendor, actor, keyword }
enum OrganizationWatchlistStatus: String, Codable { case active, paused, archived }

struct OrganizationWatchlistItem: Decodable, Identifiable {
    let id: String
    let organizationId: String
    let kind: OrganizationWatchlistKind
    let value: String
    let notes: String
    let status: OrganizationWatchlistStatus
    let updatedAt: String
    enum CodingKeys: String, CodingKey { case id, organizationId, kind, value, notes, status, updatedAt }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        organizationId = try c.decode(String.self, forKey: .organizationId)
        guard let kind = OrganizationWatchlistKind(rawValue: try c.decode(String.self, forKey: .kind)),
              let status = OrganizationWatchlistStatus(rawValue: try c.decode(String.self, forKey: .status)) else {
            throw DecodingError.dataCorruptedError(forKey: .kind, in: c, debugDescription: "Unsupported watchlist state")
        }
        self.kind = kind
        value = try c.decode(String.self, forKey: .value)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        self.status = status
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        guard !id.isEmpty, !organizationId.isEmpty, !value.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Watchlist item is incomplete")
        }
    }
}

struct OrganizationWatchlistPage: Decodable {
    struct Organization: Decodable { let id: String; let name: String; let lifecycleStatus: String }
    struct SharedContract: Decodable {
        struct Capabilities: Decodable {
            let authoritativeProjectionSync: Bool
            let projectionReconcile: Bool
            let projectionReceiptSchemaVersion: String
        }
        struct Permissions: Decodable { let canRead: Bool; let canWrite: Bool; let canArchive: Bool; let canCleanup: Bool }
        let organizationId: String
        let capabilities: Capabilities
        let permissions: Permissions
    }
    let organization: Organization
    let watchlistItems: [OrganizationWatchlistItem]
    let sharedWatchlistContract: SharedContract

    var projectionSupported: Bool {
        sharedWatchlistContract.capabilities.authoritativeProjectionSync
            && sharedWatchlistContract.capabilities.projectionReconcile
            && sharedWatchlistContract.capabilities.projectionReceiptSchemaVersion == "organization.watchlist_projection_receipt.v1"
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        organization = try c.decode(Organization.self, forKey: .organization)
        watchlistItems = try c.decode([OrganizationWatchlistItem].self, forKey: .watchlistItems)
        sharedWatchlistContract = try c.decode(SharedContract.self, forKey: .sharedWatchlistContract)
        guard !organization.id.isEmpty, sharedWatchlistContract.organizationId == organization.id,
              watchlistItems.allSatisfy({ $0.organizationId == organization.id }),
              Set(watchlistItems.map(\.id)).count == watchlistItems.count else {
            throw DecodingError.dataCorruptedError(forKey: .watchlistItems, in: c, debugDescription: "Watchlist data does not match its organization")
        }
    }
    private enum CodingKeys: String, CodingKey { case organization, watchlistItems, sharedWatchlistContract }
}

struct OrganizationWatchlistDraft: Encodable {
    let kind: OrganizationWatchlistKind
    let value: String
    let notes: String
    let reason: String
    let requestId: String
}
struct OrganizationWatchlistAction: Encodable {
    let action: String
    let reason: String
    let requestId: String
}
struct OrganizationWatchlistMutationReceipt: Decodable {
    let watchlistItem: OrganizationWatchlistItem
    let operation: JSONValue?
    let dwmAlertBridge: JSONValue?
}

struct OrganizationCollectionRequest: Decodable, Identifiable, Equatable {
    let requestId: String
    let status: String
    let captureCount: Int?
    let alertCount: Int?
    let errors: [String]?
    var id: String { requestId }
}

struct OrganizationCollectionRequestEnvelope: Decodable {
    let collectionRequest: OrganizationCollectionRequest?
}

struct OrganizationWatchlistCleanupReceipt: Decodable {
    struct Cleanup: Decodable { let archivedCount: Int?; let skippedItemIds: [String]? }
    let cleanup: Cleanup?
}

struct OrganizationWatchlistAlertRebuildReceipt: Decodable {
    let savedAlertCount: Int?
    let alertIds: [String]?
}
