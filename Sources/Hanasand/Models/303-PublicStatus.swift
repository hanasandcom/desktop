import Foundation

struct PublicStatusPayload: Codable, Equatable {
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

    init(
        overall: String, monitoring: String?, generatedAt: String?, lastVerifiedAt: String?,
        historyAvailable: Bool?, historyGeneratedAt: String?, checks: [PublicStatusCheck],
        incidents: [PublicStatusIncident], history: [PublicStatusDay]
    ) {
        self.overall = overall
        self.monitoring = monitoring
        self.generatedAt = generatedAt
        self.lastVerifiedAt = lastVerifiedAt
        self.historyAvailable = historyAvailable
        self.historyGeneratedAt = historyGeneratedAt
        self.checks = checks
        self.incidents = incidents
        self.history = history
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        _ = try container.decodeIfPresent(String.self, forKey: .overall)
        monitoring = try container.decodeIfPresent(String.self, forKey: .monitoring)
        generatedAt = try container.decodeIfPresent(String.self, forKey: .generatedAt)
        lastVerifiedAt = try container.decodeIfPresent(String.self, forKey: .lastVerifiedAt)
        historyAvailable = try container.decodeIfPresent(Bool.self, forKey: .historyAvailable)
        historyGeneratedAt = try container.decodeIfPresent(String.self, forKey: .historyGeneratedAt)

        let receivedChecks = try container.decodeIfPresent([PublicStatusCheck].self, forKey: .checks) ?? []
        let receivedIncidents = try container.decodeIfPresent([PublicStatusIncident].self, forKey: .incidents) ?? []
        let receivedHistory = try container.decodeIfPresent([PublicStatusDay].self, forKey: .history) ?? []
        checks = receivedChecks.filter(PublicStatusSuite.allows(check:))
        incidents = receivedIncidents.filter(PublicStatusSuite.allows(incident:))
        history = receivedHistory.filter(PublicStatusSuite.allows(history:))
        overall = PublicStatusSuite.overall(checks: checks, monitoring: monitoring)
    }

    static let empty = PublicStatusPayload(
        overall: "unknown", monitoring: "unavailable", generatedAt: "", lastVerifiedAt: nil,
        historyAvailable: false, historyGeneratedAt: nil, checks: [], incidents: [], history: []
    )
}

struct PublicStatusTimelineDay: Equatable, Identifiable {
    let date: String
    let status: String
    let samples: Int?
    let healthyFraction: Double?
    let healthyAndDegradedFraction: Double?
    let incident: PublicStatusIncident?

    var id: String { date }

    var displayStatus: String {
        guard status.lowercased() == "down", incident?.impact != "Outage" else { return status }
        return "degraded"
    }
}

enum PublicStatusTimeline {
    static let dayCount = 90

    static func days(for check: PublicStatusCheck, in payload: PublicStatusPayload, now: Date = Date()) -> [PublicStatusTimelineDay] {
        let incidentByID = visibleIncidentIndex(payload.incidents)
        var historyByDate: [String: PublicStatusDay] = [:]
        for day in payload.history where PublicStatusSuite.allows(history: day)
            && day.service == check.service && day.checkName == check.checkName {
            historyByDate[day.date] = day
        }

        return dateKeys(now: now).map { date in
            let history = historyByDate[date]
            let incident = history?.incidentIDs.lazy.compactMap { incidentByID[$0] }.first
            let samples = history?.samples.flatMap { $0 > 0 ? $0 : nil }
            let healthy = boundedCount(history?.healthySamples, samples: samples)
            let healthyAndDegraded = boundedCount((healthy ?? 0) + (history?.degradedSamples ?? 0), samples: samples)
            let healthyFraction = samples.map { Double(healthy ?? 0) / Double($0) }
            let healthyAndDegradedFraction = samples.map { Double(healthyAndDegraded ?? 0) / Double($0) }
            return PublicStatusTimelineDay(
                date: date,
                status: history?.status ?? "unknown",
                samples: samples,
                healthyFraction: healthyFraction,
                healthyAndDegradedFraction: healthyAndDegradedFraction,
                incident: incident
            )
        }
    }

    static func dateKeys(now: Date = Date()) -> [String] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        let today = calendar.startOfDay(for: now)
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return (0..<dayCount).compactMap { index in
            guard let date = calendar.date(byAdding: .day, value: index - (dayCount - 1), to: today) else { return nil }
            return formatter.string(from: date)
        }
    }

    private static func visibleIncidentIndex(_ incidents: [PublicStatusIncident]) -> [String: PublicStatusIncident] {
        var result: [String: PublicStatusIncident] = [:]
        for incident in incidents where PublicStatusSuite.allows(incident: incident) {
            result[incident.id] = incident
            for alias in incident.aliases ?? [] where !alias.isEmpty {
                result[alias] = incident
            }
        }
        return result
    }

    private static func boundedCount(_ value: Int?, samples: Int?) -> Int? {
        guard let value, let samples, samples > 0 else { return nil }
        return min(max(value, 0), samples)
    }
}

struct PublicStatusCheck: Codable, Equatable, Identifiable {
    var id: String { "\(service)|\(checkName)" }
    var displayService: String { PublicStatusSuite.displayName(service) }
    let service: String
    let checkName: String
    let status: String
    let latencyMilliseconds: Double?
    let message: String?
    let checkedAt: String?
    let uptime30Days: String?
    let uptime90Days: String?

    enum CodingKeys: String, CodingKey {
        case service, status, message
        case checkName = "check_name"
        case latencyMilliseconds = "latency_ms"
        case checkedAt = "checked_at"
        case uptime30Days = "uptime_30d"
        case uptime90Days = "uptime_90d"
    }
}

private enum PublicStatusSuite {
    // Keep the public status surface bounded to the established service groups.
    // The upstream feed can contain dynamically named worker checks; those are
    // not part of the user-facing status suite.
    private static let services: Set<String> = [
        "core", "ai", "website", "threat-intelligence", "content", "shares", "projects", "docker",
        "infrastructure", "api", "authentication", "auth", "database", "production-monitor", "workspace",
    ]
    private static let checkNames: Set<String> = [
        "api", "api health", "ai", "website", "public website", "ti", "content", "shares", "projects",
        "authentication", "support api", "mail", "browser api", "browser web", "browsers", "discord bot", "ti web",
        "availability", "geoip", "onion", "monitoring", "public search", "processing backlog",
        "source collection", "monitoring workspace", "latest activity",
    ]
    private static let idLikeText = try! NSRegularExpression(pattern: #"(?i)(?:\b[0-9a-f]{7,}\b|\b[0-9a-f]{8}-[0-9a-f-]{27,}\b)"#)

    static func allows(service: String, checkName: String) -> Bool {
        let normalizedService = service.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard services.contains(normalizedService), !containsIdentifier(service), !containsIdentifier(checkName) else {
            return false
        }
        return checkNames.contains(checkName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    static func allows(check: PublicStatusCheck) -> Bool {
        allows(service: check.service, checkName: check.checkName)
            && [check.message, check.checkedAt, check.uptime30Days, check.uptime90Days]
                .compactMap { $0 }
                .allSatisfy { !containsIdentifier($0) }
    }

    static func allows(incident: PublicStatusIncident) -> Bool {
        guard allows(service: incident.service, checkName: incident.checkName) else { return false }
        let visibleText = [incident.title, incident.impact, incident.status, incident.startedAt, incident.resolvedAt,
                           incident.summary, incident.cause]
            .compactMap { $0 } + incident.updates.flatMap { [$0.at, $0.status, $0.message, $0.evidence].compactMap { $0 } }
        return visibleText.allSatisfy { !containsIdentifier($0) }
    }

    static func allows(history: PublicStatusDay) -> Bool {
        allows(service: history.service, checkName: history.checkName)
            && [history.date, history.status].allSatisfy { !containsIdentifier($0) }
    }

    static func displayName(_ service: String) -> String {
        switch service.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "core", "api": return "Core platform"
        case "ai": return "AI"
        case "website": return "Website"
        case "threat-intelligence": return "Threat intelligence"
        case "content": return "Content"
        case "shares": return "Sharing"
        case "projects": return "Projects"
        case "docker", "infrastructure": return "Infrastructure"
        case "authentication", "auth": return "Authentication"
        case "database": return "Database"
        case "production-monitor": return "Monitoring"
        case "workspace": return "Workspace"
        default: return service
        }
    }

    static func overall(checks: [PublicStatusCheck], monitoring: String?) -> String {
        guard monitoring != "unavailable", !checks.isEmpty else { return "unknown" }
        if checks.contains(where: { ["degraded", "down"].contains($0.status.lowercased()) }) {
            let api = checks.first { ["api", "api health"].contains($0.checkName.lowercased()) }?.status
            let website = checks.first { ["website", "public website"].contains($0.checkName.lowercased()) }?.status
            let authentication = checks.first { ["authentication", "identity"].contains($0.checkName.lowercased()) }?.status
            if api == "down", website == "down", authentication == "down" { return "down" }
            return "degraded"
        }
        if checks.contains(where: { $0.status.lowercased() == "up" }) { return "up" }
        return "unknown"
    }

    private static func containsIdentifier(_ value: String) -> Bool {
        idLikeText.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

struct PublicStatusIncident: Codable, Equatable, Identifiable {
    var displayService: String { PublicStatusSuite.displayName(service) }
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

struct PublicStatusIncidentUpdate: Codable, Equatable, Identifiable {
    var id: String { "\(at)|\(status)|\(message)" }
    let at: String
    let status: String
    let message: String
    let evidence: String?
}

struct PublicStatusDay: Codable, Equatable, Identifiable {
    var id: String { "\(service)|\(checkName)|\(date)" }
    var displayService: String { PublicStatusSuite.displayName(service) }
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
