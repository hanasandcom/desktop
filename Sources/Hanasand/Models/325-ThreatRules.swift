import Foundation

enum ThreatRuleJSON: Codable, Equatable {
    case object([String: ThreatRuleJSON])
    case array([ThreatRuleJSON])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([ThreatRuleJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: ThreatRuleJSON].self)) }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case let .object(value): try container.encode(value)
        case let .array(value): try container.encode(value)
        case let .string(value): try container.encode(value)
        case let .number(value): try container.encode(value)
        case let .bool(value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }

    subscript(_ key: String) -> ThreatRuleJSON? {
        guard case let .object(value) = self else { return nil }
        return value[key]
    }

    var stringValue: String? { if case let .string(value) = self { value } else { nil } }
    var objectValue: [String: ThreatRuleJSON]? { if case let .object(value) = self { value } else { nil } }
    var arrayValue: [ThreatRuleJSON]? { if case let .array(value) = self { value } else { nil } }

}

struct ThreatRuleCondition: Codable, Equatable {
    var path: String
    var operation: String
    var value: String
    var caseSensitive: Bool?
    enum CodingKeys: String, CodingKey { case path, operation = "operator", value, caseSensitive }
}

struct ThreatRuleRecord: Codable, Identifiable, Equatable {
    let id: String
    var recordId: String?
    var name: String
    var explanation: String
    var severity: String
    var version: String
    var enabled: Bool
    var source: String
    var family: String?
    var hitCount: Int?
    var definition: ThreatRuleJSON
    enum CodingKeys: String, CodingKey { case id, recordId, name, explanation, severity, version, enabled, source, family, hitCount, definition }

    var stage: String { definition["stage"]?.stringValue ?? "unknown" }
    var action: String { definition["action"]?.stringValue ?? "keep" }
    var conditions: [ThreatRuleCondition] {
        (definition["conditions"]?.arrayValue ?? []).compactMap { item in
            guard let object = item.objectValue,
                  let path = object["path"]?.stringValue,
                  let operation = object["operator"]?.stringValue,
                  let value = object["value"]?.stringValue else { return nil }
            let sensitive: Bool?
            if case let .bool(value)? = object["caseSensitive"] { sensitive = value } else { sensitive = nil }
            return ThreatRuleCondition(path: path, operation: operation, value: value, caseSensitive: sensitive)
        }
    }
}

struct ThreatRuleSummary: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let enabled: Bool
    let source: String
    var stage: String
    var action: String
    enum CodingKeys: String, CodingKey { case id, name, enabled, source, definition }
    private enum DefinitionKeys: String, CodingKey { case stage, action }
    init(rule: ThreatRuleRecord) {
        id = rule.id; name = rule.name; enabled = rule.enabled; source = rule.source; stage = rule.stage; action = rule.action
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        enabled = try c.decode(Bool.self, forKey: .enabled)
        source = try c.decodeIfPresent(String.self, forKey: .source) ?? "unknown"
        let definition = try c.nestedContainer(keyedBy: DefinitionKeys.self, forKey: .definition)
        stage = try definition.decodeIfPresent(String.self, forKey: .stage) ?? "unknown"
        action = try definition.decodeIfPresent(String.self, forKey: .action) ?? "keep"
    }
}

struct ThreatRuleOrganization: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let role: String
    let status: String
    enum CodingKeys: String, CodingKey { case id, name, role, status, lifecycleStatus }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Organization"
        role = try c.decodeIfPresent(String.self, forKey: .role) ?? ""
        status = try c.decodeIfPresent(String.self, forKey: .lifecycleStatus) ?? c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
    }
}

struct ThreatRulesPage: Equatable {
    let organization: ThreatRuleOrganization
    let canManageRetention: Bool
    let rules: [ThreatRuleRecord]
}

struct ThreatRulePreview: Decodable, Equatable {
    struct Event: Decodable, Identifiable, Equatable {
        let id: String
        let timestamp: String
        let normalized: [String: ThreatRuleJSON]
    }
    struct Cursor: Decodable, Equatable { let time: String; let id: String }
    let count: Int
    let scanned: Int
    let events: [Event]
    let cursor: Cursor?
}

struct ThreatRuleTuningPattern: Decodable, Identifiable, Equatable {
    var id: String { [message, ip, userAgent].joined(separator: "|") }
    let message: String
    let ip: String
    let ipPath: String?
    let userAgent: String
    let userAgentPath: String?
    let lastTriggered: String?
    let last24hCount: String
    let eventCount: String
    let storageBytes: String
    enum CodingKeys: String, CodingKey {
        case message, ip, userAgent = "user_agent", lastTriggered = "last_triggered", last24hCount = "last_24h_count", eventCount = "event_count", storageBytes = "storage_bytes", ipPath = "ip_path", userAgentPath = "user_agent_path"
    }
}

struct ThreatRuleTuningSnapshot: Decodable, Equatable {
    let organizationId: String
    let generatedAt: String?
    let logs: [ThreatRuleTuningPattern]
    let pending: Bool
    let refreshing: Bool
}

struct ThreatRuleReprocessJob: Decodable, Identifiable, Equatable {
    let id: String
    let ruleID: String
    let ruleVersion: String
    let status: String
    let scanned: String
    let matched: String
    let protected: String
    let removedEvents: String
    let removedSources: String
    let error: String?
    let createdAt: String
    let updatedAt: String
    enum CodingKeys: String, CodingKey { case id, ruleID = "rule_id", ruleVersion = "rule_version", status, scanned, matched, protected, removedEvents = "removed_events", removedSources = "removed_sources", error, createdAt = "created_at", updatedAt = "updated_at" }
}

struct ThreatRuleReprocessState: Decodable, Equatable {
    struct Existing: Decodable, Equatable { let count: Int; let bytes: Int }
    let jobs: [ThreatRuleReprocessJob]
    let existing: Existing?
}

struct ThreatRuleImportReceipt: Decodable, Equatable {
    struct Pack: Decodable, Equatable {
        let name: String
        let version: String
        let sourceReference: String
    }

    let imported: Int
    let pack: Pack
}
