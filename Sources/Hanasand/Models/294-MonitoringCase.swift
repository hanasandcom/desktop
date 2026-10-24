import Foundation

struct MonitoringCase: Identifiable, Decodable {
    let id: String
    let title: String
    let summary: String
    let status: String
    let severity: String
    let canManage: Bool
    let source: String
    let organizationId: String?
    let assignedOwner: String
    let automationId: String
    let createdAt: String
    let updatedAt: String
    let lastSeenAt: String
    let resolvedAt: String
    let occurrences: Int
    let notificationsEnabled: Bool
    let resolution: JSONValue?
    let comments: [JSONValue]
    let history: [JSONValue]
    let notifications: [JSONValue]
    let events: [JSONValue]
    let eventPage: Int
    let eventTotal: Int
    let eventSnapshot: String
    let currentCheck: JSONValue?
    let relatedChecks: [JSONValue]
    let diskDiagnostics: JSONValue?

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        summary = try c.decodeIfPresent(String.self, forKey: .summary) ?? ""
        status = try c.decode(String.self, forKey: .status)
        severity = try c.decode(String.self, forKey: .severity)
        canManage = try c.decode(Bool.self, forKey: .canManage)
        source = try c.decode(String.self, forKey: .source)
        organizationId = try c.decodeIfPresent(String.self, forKey: .organizationId)
        assignedOwner = try c.decodeIfPresent(String.self, forKey: .assignedOwner) ?? ""
        automationId = try c.decodeIfPresent(String.self, forKey: .automationId) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? ""
        lastSeenAt = try c.decodeIfPresent(String.self, forKey: .lastSeenAt) ?? ""
        resolvedAt = try c.decodeIfPresent(String.self, forKey: .resolvedAt) ?? ""
        occurrences = try c.decode(Int.self, forKey: .occurrences)
        notificationsEnabled = try c.decode(Bool.self, forKey: .notificationsEnabled)
        resolution = try c.decodeIfPresent(JSONValue.self, forKey: .resolution)
        comments = try c.decodeIfPresent([JSONValue].self, forKey: .comments) ?? []
        history = try c.decodeIfPresent([JSONValue].self, forKey: .history) ?? []
        notifications = try c.decodeIfPresent([JSONValue].self, forKey: .notifications) ?? []
        events = try c.decodeIfPresent([JSONValue].self, forKey: .events) ?? []
        eventPage = try c.decodeIfPresent(Int.self, forKey: .eventPage) ?? 0
        eventTotal = try c.decodeIfPresent(Int.self, forKey: .eventTotal) ?? 0
        eventSnapshot = try c.decodeIfPresent(String.self, forKey: .eventSnapshot) ?? ""
        currentCheck = try c.decodeIfPresent(JSONValue.self, forKey: .currentCheck)
        relatedChecks = try c.decodeIfPresent([JSONValue].self, forKey: .relatedChecks) ?? []
        diskDiagnostics = try c.decodeIfPresent(JSONValue.self, forKey: .diskDiagnostics)

        let hasDetailFields = c.contains(.eventPage) || c.contains(.eventTotal) || c.contains(.eventSnapshot)
        if hasDetailFields {
            guard c.contains(.comments), c.contains(.history), c.contains(.notifications), c.contains(.events),
                  c.contains(.eventPage), c.contains(.eventTotal), c.contains(.eventSnapshot), c.contains(.relatedChecks) else {
                throw DecodingError.dataCorruptedError(forKey: .events, in: c, debugDescription: "Monitoring case details are incomplete")
            }
        }

        guard id.range(of: "^(HA|MON)-[1-9][0-9]*$", options: .regularExpression) != nil,
              ["open", "in_progress", "escalated", "resolved", "closed", "suppressed", "false_positive"].contains(status),
              ["low", "medium", "high", "critical"].contains(severity), source == "monitoring",
              organizationId == nil, occurrences >= 0,
              Int64(id.dropFirst(id.hasPrefix("MON-") ? 4 : 3)) != nil else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Monitoring case fields are invalid")
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, summary, status, severity, canManage, source, organizationId, assignedOwner, automationId
        case createdAt, updatedAt, lastSeenAt, resolvedAt, occurrences, notificationsEnabled
        case resolution, comments, history, notifications, events, eventPage, eventTotal, eventSnapshot
        case currentCheck, relatedChecks, diskDiagnostics
    }

    func contains(_ query: String) -> Bool {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return true }
        return [id, title, summary, status, severity, assignedOwner].joined(separator: " ").localizedCaseInsensitiveContains(needle)
    }

    var resolutionType: String {
        guard case .object(let resolution)? = resolution,
              case .string(let type)? = resolution["type"] else { return "" }
        return type
    }

    static func stringValue(_ value: JSONValue?, key: String) -> String? {
        guard case .object(let object)? = value, case .string(let text)? = object[key] else { return nil }
        return text
    }

    var needsHumanReview: Bool {
        guard case .object(let resolution)? = resolution,
              case .string(let type)? = resolution["type"], ["ai", "automation"].contains(type),
              case .string(let id)? = resolution["id"], !id.isEmpty else { return false }
        let unconfirmed: Bool
        if let value = resolution["confirmedAt"] {
            if case .null = value { unconfirmed = true } else { unconfirmed = false }
        } else { unconfirmed = true }
        guard unconfirmed else { return false }
        return ["resolved", "closed"].contains(status)
    }

    var humanReviewed: Bool {
        guard case .object(let resolution)? = resolution else { return false }
        if case .string(let value)? = resolution["confirmedAt"] { return !value.isEmpty }
        return false
    }
}

struct MonitoringCaseList: Decodable { let items: [MonitoringCase] }
struct MonitoringCaseDetail: Decodable { let `case`: MonitoringCase }

enum MonitoringCaseResolutionPolicy {
    static func allowsResolutionMethod(_ method: String?, status: String?) -> Bool {
        guard let method else { return true }
        return method == "ai" && ["resolved", "closed"].contains(status ?? "")
    }
}

enum MonitoringCaseNativeRoute {
    static let healthCheckPath = "/automation/health"

    static func healthCheckQuery(automationID: String) -> [String: String]? {
        let value = automationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 200 else { return nil }
        return ["monitor": value]
    }
}
