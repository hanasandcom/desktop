import Foundation

struct DesktopAutomation: Decodable, Identifiable {
    let id: String
    let name: String
    let prompt: String
    let targetUrl: String?
    let monitoringType: String
    let scheduleKind: String
    let intervalMinutes: Int?
    let status: String
    let actionType: String
    let organizationId: String?
    let timezone: String?
    let runAt: String?
    let modelName: String?
    let notificationDestinations: [String]
    let notifyOn: String?
    let notifyWarnings: Bool
    let timeoutSeconds: Int
    let retryCount: Int
    let expectedDown: Bool
    let upsideDown: Bool
    let followRedirects: Bool
    let userAgent: String?
    let jsonRule: DesktopAutomationJSONRule?
    let certificateStatus: String?
    let certificateSubject: String?
    let certificateIssuer: String?
    let certificateExpiresAt: String?
    let uptime: Double?
    let history: [DesktopAutomationHistoryPoint]
    let lastStatus: String?
    let lastRunAt: String?
    let nextRunAt: String?
    let lastResult: String?
    let lastError: String?
    let runCount: Int
    let consecutiveFailures: Int

    var resultSummary: String? { lastError ?? lastResult }

    enum CodingKeys: String, CodingKey {
        case id, name, prompt, actionType, targetUrl, monitoringType, scheduleKind, intervalMinutes, status
        case lastStatus, lastRunAt, nextRunAt, lastResult, lastError, runCount, consecutiveFailures
        case organizationId, timezone, runAt, modelName, notificationDestinations, notifyOn, notifyWarnings
        case timeoutSeconds, retryCount, expectedDown, upsideDown, followRedirects, userAgent, jsonRule
        case certificateStatus, certificateSubject, certificateIssuer, certificateExpiresAt, uptime, history
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        prompt = try values.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        actionType = try values.decodeIfPresent(String.self, forKey: .actionType) ?? "agent_prompt"
        targetUrl = try values.decodeIfPresent(String.self, forKey: .targetUrl)
        monitoringType = try values.decodeIfPresent(String.self, forKey: .monitoringType) ?? "fetch"
        scheduleKind = try values.decodeIfPresent(String.self, forKey: .scheduleKind) ?? "interval"
        intervalMinutes = try values.decodeIfPresent(Int.self, forKey: .intervalMinutes)
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "paused"
        organizationId = try values.decodeIfPresent(String.self, forKey: .organizationId)
        timezone = try values.decodeIfPresent(String.self, forKey: .timezone)
        runAt = try values.decodeIfPresent(String.self, forKey: .runAt)
        modelName = try values.decodeIfPresent(String.self, forKey: .modelName)
        notificationDestinations = try values.decodeIfPresent([String].self, forKey: .notificationDestinations) ?? []
        notifyOn = try values.decodeIfPresent(String.self, forKey: .notifyOn)
        notifyWarnings = try values.decodeIfPresent(Bool.self, forKey: .notifyWarnings) ?? false
        timeoutSeconds = try values.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 5
        retryCount = try values.decodeIfPresent(Int.self, forKey: .retryCount) ?? 0
        expectedDown = try values.decodeIfPresent(Bool.self, forKey: .expectedDown) ?? false
        upsideDown = try values.decodeIfPresent(Bool.self, forKey: .upsideDown) ?? false
        followRedirects = try values.decodeIfPresent(Bool.self, forKey: .followRedirects) ?? true
        userAgent = try values.decodeIfPresent(String.self, forKey: .userAgent)
        jsonRule = try values.decodeIfPresent(DesktopAutomationJSONRule.self, forKey: .jsonRule)
        certificateStatus = try values.decodeIfPresent(String.self, forKey: .certificateStatus)
        certificateSubject = try values.decodeIfPresent(String.self, forKey: .certificateSubject)
        certificateIssuer = try values.decodeIfPresent(String.self, forKey: .certificateIssuer)
        certificateExpiresAt = try values.decodeIfPresent(String.self, forKey: .certificateExpiresAt)
        uptime = try values.decodeIfPresent(Double.self, forKey: .uptime)
        history = try values.decodeIfPresent([DesktopAutomationHistoryPoint].self, forKey: .history) ?? []
        lastStatus = try values.decodeIfPresent(String.self, forKey: .lastStatus)
        lastRunAt = try values.decodeIfPresent(String.self, forKey: .lastRunAt)
        nextRunAt = try values.decodeIfPresent(String.self, forKey: .nextRunAt)
        lastResult = try values.decodeIfPresent(String.self, forKey: .lastResult)
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        runCount = try values.decodeIfPresent(Int.self, forKey: .runCount) ?? 0
        consecutiveFailures = try values.decodeIfPresent(Int.self, forKey: .consecutiveFailures) ?? 0
    }
}

struct DesktopAutomationEnvelope: Decodable {
    let automations: [DesktopAutomation]
    let canManageSystem: Bool?
}

struct DesktopAutomationRun: Decodable, Identifiable {
    let id: String
    let status: String
    let warning: Bool
    let result: String?
    let error: String?
    let startedAt: String
    let completedAt: String?
    let durationMs: Int?
    let caseNumber: String?
}

struct DesktopAutomationHistoryPoint: Decodable, Identifiable {
    let id: String
    let status: String
    let warning: Bool
    let startedAt: String
    enum CodingKeys: String, CodingKey { case id, status, warning; case startedAt = "started_at" }
}

struct DesktopAutomationJSONRule: Codable {
    let path: String
    let operatorName: String
    let value: DesktopAutomationRuleValue
    let aggregate: String?

    enum CodingKeys: String, CodingKey {
        case path, value, aggregate
        case operatorName = "operator"
    }
}

enum DesktopAutomationRuleValue: Codable, Equatable {
    case string(String), number(Double), bool(Bool), null
    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

enum DesktopAutomationEditorRules {
    static let actions = ["agent_prompt", "system_alert", "echo", "mail_health_check"]
    static let operators = ["gt", "gte", "lt", "lte", "eq", "ne"]
    static let aggregates = ["max", "min", "avg", "first"]

    static func value(from raw: String) -> DesktopAutomationRuleValue? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value == "true" { return .bool(true) }
        if value == "false" { return .bool(false) }
        if let number = Double(value), number.isFinite { return .number(number) }
        if value.first == "\"", value.last == "\"",
           let data = value.data(using: .utf8),
           let decoded = try? JSONDecoder().decode(String.self, from: data) {
            return .string(decoded)
        }
        return .string(value)
    }

    static func validate(
        actionType: String,
        monitoringType: String,
        targetURL: String,
        jsonRule: DesktopAutomationJSONRule?,
        canManageSystem: Bool,
        scheduleKind: String = "interval",
        intervalMinutes: Int? = nil,
        timeoutSeconds: Int? = nil,
        expectedDown: Bool = false,
        upsideDown: Bool = false
    ) -> String? {
        guard actions.contains(actionType), actionType != "mail_health_check" || canManageSystem else {
            return "This action is not available for this account. Refresh permissions and try again."
        }
        guard ["fetch", "post", "tcp", "ssh", "json", "push"].contains(monitoringType) else {
            return "Choose a supported check type."
        }
        if monitoringType == "push" && actionType != "agent_prompt" {
            return "External events require a monitoring check."
        }
        guard actionType == "agent_prompt" else { return nil }

        let target = targetURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !target.isEmpty else { return monitoringType == "push" ? "Enter a source ID." : "Enter a monitoring target." }
        if monitoringType == "push" {
            guard target.range(of: "^[\\w./:-]{1,128}$", options: .regularExpression) != nil, !target.hasPrefix("system:") else {
                return "Enter a source ID using letters, numbers, dots, slashes, colons, hyphens or underscores."
            }
            guard scheduleKind == "interval", intervalMinutes == 1, !expectedDown, !upsideDown else {
                return "External checks require a one-minute heartbeat without inverted conditions."
            }
            if let timeoutSeconds, !(1...86_400).contains(timeoutSeconds) {
                return "Enter an offline timeout between 1 and 86400 seconds."
            }
            return nil
        }
        if target.hasPrefix("system:") {
            guard canManageSystem, monitoringType == "json" else {
                return "System monitoring requires a JSON check and Hanasand organization editor access."
            }
        }
        if monitoringType == "tcp" || monitoringType == "ssh" {
            guard target.range(of: "^[^:/\\s]+(?::\\d+)?$", options: .regularExpression) != nil else {
                return "Enter a host with an optional port."
            }
        } else if monitoringType == "json" {
            guard let rule = jsonRule,
                  !rule.path.isEmpty,
                  rule.path.utf8.count <= 300,
                  rule.path.range(of: "^[\\w*-]+(?:\\.[\\w*-]+)*$", options: .regularExpression) != nil,
                  !rule.path.split(separator: ".").contains(where: { ["__proto__", "constructor", "prototype"].contains(String($0)) }) else {
                return "Enter a dot-separated JSON field, using * for array items."
            }
            guard operators.contains(rule.operatorName), aggregates.contains(rule.aggregate ?? "") else {
                return "Choose a supported JSON comparison and aggregation."
            }
            switch rule.value {
            case .number(let number):
                guard number.isFinite else { return "Enter a finite comparison value." }
            case .bool, .string:
                guard ["eq", "ne"].contains(rule.operatorName) else { return "This comparison needs a number." }
                if case .string(let text) = rule.value, text.utf8.count > 500 { return "Text comparison values must be 500 characters or fewer." }
            case .null:
                return "Choose a number, true/false, or text comparison value."
            }
        } else if !target.hasPrefix("system:") {
            let normalized = target.contains("://") ? target : "https://\(target)"
            guard let url = URL(string: normalized), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                return "Enter a valid HTTP or HTTPS target."
            }
        }
        return nil
    }
}

struct DesktopAutomationDetailEnvelope: Decodable {
    let automation: DesktopAutomation
    let runs: [DesktopAutomationRun]
    let total: Int?
    let issues: [DesktopAutomationIssue]
    let nextPage: Int?
    let nextCursor: String?

    enum CodingKeys: String, CodingKey { case automation, runs, total, issues, nextPage, nextCursor }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        automation = try values.decode(DesktopAutomation.self, forKey: .automation)
        runs = try values.decodeIfPresent([DesktopAutomationRun].self, forKey: .runs) ?? []
        total = try values.decodeIfPresent(Int.self, forKey: .total)
        issues = try values.decodeIfPresent([DesktopAutomationIssue].self, forKey: .issues) ?? []
        nextPage = try values.decodeIfPresent(Int.self, forKey: .nextPage)
        nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
    }
}

struct DesktopAutomationIssue: Decodable, Identifiable {
    struct Notification: Decodable { let deliveredAt: String?; let nextAttemptAt: String?; let error: String? }
    let id: String
    let caseNumber: String
    let kind: String
    let summary: String
    let occurrences: Int
    let firstSeenAt: String
    let lastSeenAt: String
    let resolvedAt: String?
    let notifications: [Notification]
}

struct DesktopAutomationPayload: Encodable {
    let name: String
    let prompt: String
    let targetUrl: String
    let monitoringType: String
    let scheduleKind: String
    let intervalMinutes: Int
    let status: String
    let actionType: String
    var followRedirects: Bool = true
    var userAgent: String?
    var expectedDown: Bool = false
    var upsideDown: Bool = false
    var timeoutSeconds: Int = 5
    var retryCount: Int = 4
    var runAt: String?
    var organizationId: String?
    var timezone: String = "UTC"
    var modelName: String?
    var notificationDestinations: [String] = []
    var notifyOn: String = "failure"
    var notifyWarnings: Bool = false
    var jsonRule: DesktopAutomationJSONRule?
}

struct DesktopCronResourceUsage: Decodable {
    let scope: String?
    let cpuPercent: Double?
    let memoryRssMb: Double?
    let memoryUsedMb: Double?
    let queueDepth: Int?
    let note: String?
}

struct DesktopCronCostEstimate: Decodable {
    let scope: String?
    let hourlyUsd: Double?
    let dailyUsd: Double?
    let assumption: String?
}

struct DesktopCronJob: Decodable, Identifiable {
    let id: String
    let name: String
    let description: String
    let category: String
    let source: String
    let service: String
    let schedule: String
    let cadenceSeconds: Int?
    let enabled: Bool
    let running: Bool
    let status: String
    let lastRunAt: String?
    let lastSuccessAt: String?
    let nextRunAt: String?
    let averageRuntimeMs: Double?
    let failureCount: Int
    let lastError: String?
    let logExcerpt: String?
    let controls: [String]
    let controlMode: String
    let resourceUsage: DesktopCronResourceUsage?
    let costEstimate: DesktopCronCostEstimate?

    enum CodingKeys: String, CodingKey {
        case id, name, description, category, source, service, schedule, cadenceSeconds, enabled, running, status
        case lastRunAt, lastSuccessAt, nextRunAt, averageRuntimeMs, failureCount, lastError, logExcerpt
        case controls, controlMode, resourceUsage, costEstimate
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        description = try values.decodeIfPresent(String.self, forKey: .description) ?? ""
        category = try values.decodeIfPresent(String.self, forKey: .category) ?? "Other/System"
        source = try values.decodeIfPresent(String.self, forKey: .source) ?? ""
        service = try values.decodeIfPresent(String.self, forKey: .service) ?? ""
        schedule = try values.decodeIfPresent(String.self, forKey: .schedule) ?? ""
        cadenceSeconds = try values.decodeIfPresent(Int.self, forKey: .cadenceSeconds)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        running = try values.decodeIfPresent(Bool.self, forKey: .running) ?? false
        status = try values.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        lastRunAt = try values.decodeIfPresent(String.self, forKey: .lastRunAt)
        lastSuccessAt = try values.decodeIfPresent(String.self, forKey: .lastSuccessAt)
        nextRunAt = try values.decodeIfPresent(String.self, forKey: .nextRunAt)
        averageRuntimeMs = try values.decodeIfPresent(Double.self, forKey: .averageRuntimeMs)
        failureCount = try values.decodeIfPresent(Int.self, forKey: .failureCount) ?? 0
        lastError = try values.decodeIfPresent(String.self, forKey: .lastError)
        logExcerpt = try values.decodeIfPresent(String.self, forKey: .logExcerpt)
        controls = try values.decodeIfPresent([String].self, forKey: .controls) ?? []
        controlMode = try values.decodeIfPresent(String.self, forKey: .controlMode) ?? "observable_only"
        resourceUsage = try values.decodeIfPresent(DesktopCronResourceUsage.self, forKey: .resourceUsage)
        costEstimate = try values.decodeIfPresent(DesktopCronCostEstimate.self, forKey: .costEstimate)
    }
}

struct DesktopCronJobsEnvelope: Decodable {
    let jobs: [DesktopCronJob]
    let ready: Bool?
}

struct DesktopCronUpdatePayload: Encodable {
    var schedule: String?
    var enabled: Bool?
    var action: String?
}
