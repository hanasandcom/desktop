import Foundation

struct ServiceAccountEndpoint: Decodable, Encodable, Equatable, Identifiable {
    let method: String
    let route: String
    let label: String
    var id: String { "\(method) \(route)" }
    enum CodingKeys: String, CodingKey { case method, route, label }

    init(method: String, route: String, label: String) {
        self.method = method; self.route = route; self.label = label
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        method = try values.decode(String.self, forKey: .method)
        route = try values.decode(String.self, forKey: .route)
        label = try values.decodeIfPresent(String.self, forKey: .label) ?? ""
    }
}

struct ServiceAccountKeyScope: Decodable, Equatable, Identifiable {
    let method: String
    let route: String
    let label: String?
    let enabled: Bool
    var id: String { "\(method) \(route)" }
    enum CodingKeys: String, CodingKey { case method, route, label, enabled }
}

struct ServiceAccountKey: Decodable, Equatable, Identifiable {
    let id: String
    let ownerID: String
    let enabled: Bool
    let keyPrefix: String
    let createdAt: String?
    let lastUsedAt: String?
    let scopes: [ServiceAccountKeyScope]
    enum CodingKeys: String, CodingKey { case id, ownerID = "ownerId", enabled, keyPrefix, createdAt, lastUsedAt, scopes }
}

struct ServiceAccountRecord: Decodable, Equatable, Identifiable {
    let id: String
    let name: String
    let description: String
    let active: Bool
    let createdAt: String?
    let keys: [ServiceAccountKey]
    enum CodingKeys: String, CodingKey { case id, name, description, active, createdAt = "created_at", keys }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        active = try values.decode(Bool.self, forKey: .active)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        keys = try values.decode([ServiceAccountKey].self, forKey: .keys)
    }
}

struct ServiceAccountDirectory: Decodable, Equatable {
    let endpoints: [ServiceAccountEndpoint]
    let accounts: [ServiceAccountRecord]
}

struct ServiceAccountAccess: Decodable, Equatable {
    let allowed: Bool
    let canEdit: Bool
}

struct ServiceAccountReceipt: Decodable, Equatable {
    struct Key: Decodable, Equatable {
        let id: String
        let ownerID: String
        let name: String
        let enabled: Bool
        let keyPrefix: String
        let scopes: [ServiceAccountEndpoint]
        enum CodingKeys: String, CodingKey { case id, ownerID = "ownerId", name, enabled, keyPrefix, scopes }
    }
    let apiKey: Key
    let secret: String
}

struct ServiceAccountUpdateReceipt: Decodable, Equatable {
    let id: String
    let name: String
    let description: String
}

struct ServiceAccountRevokeReceipt: Decodable, Equatable {
    let message: String
}
