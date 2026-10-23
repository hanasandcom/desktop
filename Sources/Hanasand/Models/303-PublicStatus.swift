import Foundation

struct PublicStatusPayload: Decodable, Equatable {
    let overall: String
    let monitoring: String?
    let generatedAt: String?
    let lastVerifiedAt: String?
    let historyAvailable: Bool?
    let historyGeneratedAt: String?
    let checks: [PublicStatusCheck]
    let incidents: [PublicStatusIncident]
    let history: [PublicStatusDay]

    enum CodingKeys: String, CodingKey {
        case overall, monitoring, checks, incidents, history
        case generatedAt = "generated_at"
        case lastVerifiedAt = "last_verified_at"
        case historyAvailable = "history_available"
        case historyGeneratedAt = "history_generated_at"
    }

    static let empty = PublicStatusPayload(
        overall: "unknown", monitoring: "unavailable", generatedAt: "", lastVerifiedAt: nil,
        historyAvailable: false, historyGeneratedAt: nil, checks: [], incidents: [], history: []
    )
}

struct PublicStatusCheck: Decodable, Equatable, Identifiable {
    var id: String { "\(service)|\(checkName)" }
    let service: String
    let checkName: String
    let status: String
    let latencyMilliseconds: Int?
    let message: String?
    let checkedAt: String?
    let uptime30Days: String?

    enum CodingKeys: String, CodingKey {
        case service, status, message
        case checkName = "check_name"
        case latencyMilliseconds = "latency_ms"
        case checkedAt = "checked_at"
        case uptime30Days = "uptime_30d"
    }
}

struct PublicStatusIncident: Decodable, Equatable, Identifiable {
    var id: String
    var aliases: [String]?
    var service: String
    var checkName: String
    var title: String
    var impact: String
    var status: String
    var startedAt: String
    var resolvedAt: String?
    var summary: String
    var cause: String?
    var updates: [PublicStatusIncidentUpdate]

    enum CodingKeys: String, CodingKey {
        case id, aliases, service, title, impact, status, summary, cause, updates
        case checkName = "check_name"
        case startedAt = "started_at"
        case resolvedAt = "resolved_at"
    }
}

struct PublicStatusIncidentUpdate: Decodable, Equatable, Identifiable {
    var id: String { "\(at)|\(status)|\(message)" }
    let at: String
    let status: String
    let message: String
    let evidence: String?
}

struct PublicStatusDay: Decodable, Equatable, Identifiable {
    var id: String { "\(service)|\(checkName)|\(date)" }
    let service: String
    let checkName: String
    let date: String
    let status: String
    let incidentIDs: [String]
    let samples: Int?
    let healthySamples: Int?
    let degradedSamples: Int?
    let failedSamples: Int?

    enum CodingKeys: String, CodingKey {
        case service, date, status, samples
        case checkName = "check_name"
        case incidentIDs = "incident_ids"
        case healthySamples = "healthy_samples"
        case degradedSamples = "degraded_samples"
        case failedSamples = "failed_samples"
    }
}
