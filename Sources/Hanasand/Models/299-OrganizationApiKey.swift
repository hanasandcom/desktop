import Foundation

struct OrganizationApiKey: Decodable, Identifiable, Equatable {
    let id: String
    let organizationId: String
    let name: String
    let enabled: Bool
    let keyPrefix: String
    let expiresAt: String?
    let lastUsedAt: String?
    let createdAt: String?
    let scopes: [Scope]

    struct Scope: Decodable, Equatable, Identifiable {
        let method: String
        let route: String
        let enabled: Bool
        var id: String { "\(method):\(route)" }
    }

    enum CodingKeys: String, CodingKey {
        case id, name, enabled, scopes
        case organizationId
        case keyPrefix
        case expiresAt
        case lastUsedAt
        case createdAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        organizationId = try container.decode(String.self, forKey: .organizationId)
        name = try container.decode(String.self, forKey: .name)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        keyPrefix = try container.decode(String.self, forKey: .keyPrefix)
        expiresAt = try container.decodeIfPresent(String.self, forKey: .expiresAt)
        lastUsedAt = try container.decodeIfPresent(String.self, forKey: .lastUsedAt)
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        scopes = try container.decodeIfPresent([Scope].self, forKey: .scopes) ?? []

        guard !id.isEmpty, !organizationId.isEmpty, !name.isEmpty,
              keyPrefix.range(of: "^[a-fA-F0-9]{12}$", options: .regularExpression) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Organization API key is incomplete")
        }
    }
}

struct OrganizationApiKeyList: Decodable {
    let organizationId: String
    let apiKeys: [OrganizationApiKey]
}

struct OrganizationApiKeyCreateReceipt: Decodable {
    let apiKey: OrganizationApiKey
    let secret: String
}

struct OrganizationApiKeyRevokeReceipt: Decodable {
    let apiKey: OrganizationApiKey
}

enum OrganizationApiKeyPermission {
    static func canManage(role: String, isOwnAccount: Bool, isImpersonating: Bool) -> Bool {
        ["owner", "admin"].contains(role.lowercased()) && isOwnAccount && !isImpersonating
    }
}
