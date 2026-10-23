import Foundation

enum ThreatDeliveryStatus: String, Decodable, Hashable {
    case dryRun = "dry_run"
    case delivered
    case failed
    case skipped
    case unknown

    var statusLabel: String {
        switch self {
        case .dryRun: "Dry run"
        case .delivered: "Delivered"
        case .failed: "Failed"
        case .skipped: "Skipped"
        case .unknown: "Status not reported"
        }
    }

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        self = ThreatDeliveryStatus(rawValue: value) ?? .unknown
    }
}

struct ThreatDeliveryHistory: Decodable {
    struct Attempt: Decodable, Identifiable {
        let id: String
        let orgId: String
        let alertId: String
        let eventType: String
        let status: ThreatDeliveryStatus
        let dryRun: Bool
        let attemptCount: Int?
        let attemptedAt: String?
        let completedAt: String?
        let deliveredAt: String?
        let createdAt: String?

        enum CodingKeys: String, CodingKey {
            case id, orgId, alertId, eventType, status, dryRun, attemptCount
            case attemptedAt, completedAt, deliveredAt, createdAt
        }

        init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            id = try values.decode(String.self, forKey: .id)
            orgId = try values.decode(String.self, forKey: .orgId)
            alertId = try values.decode(String.self, forKey: .alertId)
            eventType = try values.decodeIfPresent(String.self, forKey: .eventType) ?? ""
            status = ThreatDeliveryStatus(rawValue: try values.decodeIfPresent(String.self, forKey: .status) ?? "") ?? .unknown
            dryRun = try values.decodeIfPresent(Bool.self, forKey: .dryRun) ?? false
            let attempts = try values.decodeIfPresent(Int.self, forKey: .attemptCount)
            attemptCount = attempts.flatMap { $0 >= 0 ? $0 : nil }
            attemptedAt = try values.decodeIfPresent(String.self, forKey: .attemptedAt)
            completedAt = try values.decodeIfPresent(String.self, forKey: .completedAt)
            deliveredAt = try values.decodeIfPresent(String.self, forKey: .deliveredAt)
            createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        }

        var displayDate: String { deliveredAt ?? completedAt ?? attemptedAt ?? createdAt ?? "Time not reported" }
        var statusLabel: String { status.statusLabel }
    }

    let deliveries: [Attempt]
    let organizationID: String

    init(deliveries: [Attempt], organizationID: String) {
        self.deliveries = deliveries
        self.organizationID = organizationID
    }

    static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil && value != "." && value != ".."
    }
}
