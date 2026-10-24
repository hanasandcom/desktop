import Foundation

struct AIMetricSensor: Decodable, Equatable {
    let name: String; let load: Double?; let memoryUsedMb: Double?; let memoryTotalMb: Double?; let powerDrawWatts: Double?; let temperatureC: Double?
}
struct AIMetricLane: Decodable, Equatable, Identifiable {
    var id: String { identifier }
    let identifier: String; let label: String; let model: String; let tier: String; let gpuName: String
    let active: Double?; let available: Double?; let maximum: Double?; let queued: Double?; let context: Double?
    let memoryUsedMb: Double?; let memoryTotalMb: Double?; let watts: Double?; let temperatureC: Double?
}
struct AIMetricClient: Decodable, Equatable, Identifiable {
    var id: String { name }
    let name: String; let displayName: String; let modelId: String; let profile: String
    let ram: [AIMetricSensor]?; let cpu: [AIMetricSensor]?; let gpu: [AIMetricSensor]?; let lanes: [AIMetricLane]?
    let watts: Double?; let monthlyKwh: Double?; let sampledAt: String
    let model: AIModelMetrics
}
struct AIMetricQueueRow: Decodable, Equatable, Identifiable {
    var id: String { "\(lane)|\(model)|\(kind)|\(status)" }
    let lane: String; let model: String; let kind: String; let status: String; let count: Double?
}
struct AIMetricEconomics: Decodable, Equatable {
    let windowDays: Double?; let firstOutputP50: Double?; let firstOutputP95: Double?; let sampleCount: Double?; let queue: [AIMetricQueueRow]
}
struct AIMetricContainer: Decodable, Equatable, Identifiable {
    var id: String { name }
    let name: String; let image: String; let status: String; let health: String
}
struct AIMetricContainers: Decodable, Equatable {
    let generatedAt: String; let unavailable: String; let items: [AIMetricContainer]
}
struct AIMetricsSnapshot: Equatable {
    var clients: [AIMetricClient] = []; var economics: AIMetricEconomics?; var containers: AIMetricContainers?
    var errors: [String] = []; var liveState = "Disconnected"; var participants: Int?; var lastRead = ""; var loading = false
}

struct AIMetricSummary: Equatable {
    let ramLoad: Double?
    let cpuLoad: Double?
    let gpuLoad: Double?
    let throughput: Double?
    let activeRequests: Double?
    let availableRequests: Double?
    let maximumRequests: Double?
    let laneCount: Int?

    init(clients: [AIMetricClient]) {
        ramLoad = Self.averageClientLoad(clients.map(\.ram))
        cpuLoad = Self.averageClientLoad(clients.map(\.cpu))
        gpuLoad = Self.averageClientLoad(clients.map(\.gpu))
        throughput = Self.mean(clients.map(\.model.tps))

        guard !clients.isEmpty, clients.allSatisfy({ $0.lanes != nil }) else {
            activeRequests = nil
            availableRequests = nil
            maximumRequests = nil
            laneCount = nil
            return
        }
        let lanes = clients.flatMap { $0.lanes ?? [] }
        activeRequests = Self.sum(lanes.map(\.active))
        availableRequests = Self.sum(lanes.map(\.available))
        maximumRequests = Self.sum(lanes.map(\.maximum))
        laneCount = lanes.count
    }

    private static func averageClientLoad(_ groups: [[AIMetricSensor]?]) -> Double? {
        guard !groups.isEmpty else { return nil }
        let clientAverages = groups.compactMap { group -> Double? in
            guard let group, !group.isEmpty else { return nil }
            return mean(group.map(\.load))
        }
        guard clientAverages.count == groups.count else { return nil }
        return mean(clientAverages.map(Optional.some))
    }

    private static func mean(_ values: [Double?]) -> Double? {
        guard !values.isEmpty, values.allSatisfy({ $0 != nil }) else { return nil }
        let result = values.compactMap { $0 }.reduce(0, +) / Double(values.count)
        return result.isFinite ? result : nil
    }

    private static func sum(_ values: [Double?]) -> Double? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        let result = values.compactMap { $0 }.reduce(0, +)
        return result.isFinite ? result : nil
    }
}

enum AIMetricPromptPhase: Equatable { case ready, connecting, running, completed, failed, uncertain }
enum AIMetricLiveRecovery {
    static func shouldReconnect(onManualRefresh manual: Bool, liveState: String, promptPhase: AIMetricPromptPhase) -> Bool {
        manual && (liveState != "Connected" || promptPhase == .uncertain)
    }
}

struct AIMetricPromptMessage: Codable, Equatable { let role: String; let content: String }
struct AIMetricReviewGate: Equatable {
    private(set) var requiresReview = false
    private var freshHTTPReview = false
    private var freshLiveSnapshot = false
    mutating func markUncertain() { requiresReview = true; freshHTTPReview = false; freshLiveSnapshot = false }
    mutating func markManualHTTPReview(succeeded: Bool) { freshHTTPReview = succeeded; clearIfReviewed() }
    mutating func markFreshLiveSnapshot() { freshLiveSnapshot = true; clearIfReviewed() }
    mutating func resetScope() { requiresReview = false; freshHTTPReview = false; freshLiveSnapshot = false }
    private mutating func clearIfReviewed() { if requiresReview && freshHTTPReview && freshLiveSnapshot { resetScope() } }
}
@MainActor enum AIMetricSocketDeadline {
    static func schedule(after duration: Duration, onTimeout: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task {
            do { try await Task.sleep(for: duration) } catch { return }
            guard !Task.isCancelled else { return }
            onTimeout()
        }
    }
}

enum AIMetricsValidation {
    static let maxBytes = 2 * 1024 * 1024
    static func boundedJSON(_ data: Data) throws -> Any {
        guard data.count <= maxBytes else { throw AIMetricsError.invalid("AI telemetry exceeded its 2 MiB size limit.") }
        return try JSONSerialization.jsonObject(with: data)
    }
    static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite, number.doubleValue >= 0 else { return nil }
        return number.doubleValue
    }
    static func integer(_ value: Double?) -> Int? {
        // Double(Int.max) rounds up to 2^63 on 64-bit platforms, which Int cannot represent.
        guard let value, value < Double(Int.max), value >= Double(Int.min) else { return nil }
        return Int(value)
    }
    static func text(_ value: Any?, limit: Int = 300) -> String { String((value as? String ?? "").prefix(limit)) }
    static func record(_ value: Any?) -> [String: Any] { value as? [String: Any] ?? [:] }
    static func sensorRows(_ value: Any?) throws -> [AIMetricSensor]? {
        guard let rows = value as? [[String: Any]] else { return nil }
        guard rows.count <= 512 else { throw AIMetricsError.invalid("Too many sensor rows. Refresh to try again.") }
        return rows.map { row in
            let load = number(row["load"])
            return AIMetricSensor(name: text(row["name"]), load: (load ?? 2) <= 1 ? load : nil,
                memoryUsedMb: number(row["memoryUsedMb"]), memoryTotalMb: number(row["memoryTotalMb"]),
                powerDrawWatts: number(row["powerDrawWatts"]), temperatureC: number(row["temperatureC"]))
        }
    }
    static func client(_ raw: Any) throws -> AIMetricClient {
        let row = record(raw), model = record(row["model"]), power = record(row["power"])
        guard let name = row["name"] as? String, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.count <= 300 else { throw AIMetricsError.invalid("Invalid AI client telemetry. Refresh to try again.") }
        let lanesRaw = row["lanes"] as? [[String: Any]]
        guard (lanesRaw?.count ?? 0) <= 512 else { throw AIMetricsError.invalid("Too many AI lanes. Refresh to try again.") }
        let lanes = lanesRaw?.enumerated().map { index, lane in AIMetricLane(
            identifier: text(lane["id"]).isEmpty ? String(index) : text(lane["id"]), label: text(lane["label"]).isEmpty ? "Lane \(index + 1)" : text(lane["label"]),
            model: text(lane["model"]), tier: text(lane["tier"]), gpuName: text(lane["gpuName"]), active: number(lane["activeRequests"]), available: number(lane["availableRequests"]), maximum: number(lane["maxRequests"]), queued: number(lane["queuedRequests"]), context: number(lane["contextMaxTokens"]), memoryUsedMb: number(lane["memoryUsedMb"]), memoryTotalMb: number(lane["memoryTotalMb"]), watts: number(lane["powerDrawWatts"]), temperatureC: number(lane["temperatureC"])) }
        let metrics = AIModelMetrics(conversationId: model["conversationId"] as? String, status: text(model["status"]), currentTokens: integer(number(model["currentTokens"])), maxTokens: integer(number(model["maxTokens"])), promptTokens: integer(number(model["promptTokens"])), generatedTokens: integer(number(model["generatedTokens"])), contextTokens: integer(number(model["contextTokens"])), contextMaxTokens: integer(number(model["contextMaxTokens"])), tps: number(model["tps"]), lastUpdated: text(model["lastUpdated"]), lastError: text(model["lastError"], limit: 1000))
        return AIMetricClient(name: name, displayName: text(row["displayName"]), modelId: text(row["modelId"]), profile: text(row["profile"]), ram: try sensorRows(row["ram"]), cpu: try sensorRows(row["cpu"]), gpu: try sensorRows(row["gpu"]), lanes: lanes, watts: number(power["totalWatts"]), monthlyKwh: number(power["monthlyKwh"]), sampledAt: text(power["sampledAt"]), model: metrics)
    }
    static func event(_ data: Data) throws -> [String: Any] {
        let value = try boundedJSON(data)
        guard let object = value as? [String: Any], let type = object["type"] as? String, type.count <= 64 else { throw AIMetricsError.invalid("Invalid live AI event.") }
        return object
    }
    static func eventMatches(_ event: [String: Any], conversationID: String, clientName: String) -> Bool {
        guard event["conversationId"] as? String == conversationID else { return false }
        return (event["clientName"] as? String).map { $0 == clientName } ?? true
    }
    static func promptRequest(clientName: String, conversationID: String, messages: [AIMetricPromptMessage]) throws -> [String: Any] {
        guard !clientName.isEmpty, clientName.count <= 300, !conversationID.isEmpty, conversationID.count <= 128,
              messages.count <= 40, messages.allSatisfy({ ["user", "assistant"].contains($0.role) }),
              let encoded = try? JSONEncoder().encode(messages), encoded.count <= 64 * 1024 else { throw AIMetricsError.invalid("Prompt request exceeds its safe bounds.") }
        return ["type": "prompt_request", "conversationId": conversationID, "clientName": clientName,
                "messages": try JSONSerialization.jsonObject(with: encoded), "maxTokens": 512, "temperature": 0.7]
    }
    static func canTestPrompt(settings: HanasandDesktopSettings, selectedClient: String, liveClients: [AIMetricClient], hasFreshSnapshot: Bool, requiresReview: Bool) -> Bool {
        guard settings.impersonatingUserID.isEmpty, settings.impersonationToken.isEmpty,
              !selectedClient.isEmpty, hasFreshSnapshot, !requiresReview else { return false }
        return liveClients.contains { $0.name == selectedClient }
    }
    static func prompt(_ prompt: String, history: [AIMetricPromptMessage]) throws -> [AIMetricPromptMessage] {
        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 8_000 else { throw AIMetricsError.invalid("Enter a prompt up to 8,000 characters.") }
        let messages = history + [AIMetricPromptMessage(role: "user", content: trimmed)]
        guard messages.count <= 40, messages.allSatisfy({ ["user", "assistant"].contains($0.role) }),
              let data = try? JSONEncoder().encode(messages), data.count <= 64 * 1024 else { throw AIMetricsError.invalid("Prompt history exceeds its safe message or size limit.") }
        return messages
    }
}

import CoreFoundation
enum AIMetricsError: Error, LocalizedError {
    case invalid(String); case http(Int); case unavailable(String)
    var errorDescription: String? {
        switch self { case .invalid(let message): return message; case .http(401), .http(403): return "AI access could not be verified. Refresh manually before continuing."; case .http: return "AI telemetry is unavailable. Refresh to try again."; case .unavailable(let message): return message }
    }
}
