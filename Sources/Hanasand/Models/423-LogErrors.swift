import Foundation

struct LogErrorsFilters: Equatable {
    var surface = ""
    var statusCode: Int?
    var errorCode = ""
    var query = ""
    var includeExpected = false

    static func fromRouteQuery(_ query: [String: String]) -> Self {
        var filters = Self()
        if let surface = boundedLogsRouteValue(query["surface"], maximum: 120) { filters.surface = surface }
        if let code = boundedLogsRouteValue(query["code"], maximum: 120) { filters.errorCode = code }
        if let search = boundedLogsRouteValue(query["q"], maximum: 120) { filters.query = search }
        if let status = query["status"].flatMap(Int.init), (400...599).contains(status) { filters.statusCode = status }
        filters.includeExpected = ["1", "true"].contains(query["includeExpected"]?.lowercased() ?? "")
        return filters
    }
}

struct LogErrorEvent: Decodable, Identifiable, Equatable {
    let id: String
    let source: String?
    let service: String?
    let surface: String?
    let method: String?
    let path: String?
    let statusCode: Int?
    let errorCode: String?
    let message: String?
    let requestID: String?
    let userID: String?
    let level: String?
    let createdAt: String?
    let raw: [String: APIReferenceJSONValue]

    private struct DynamicKey: CodingKey {
        let stringValue: String
        let intValue: Int?
        init?(stringValue: String) { self.stringValue = stringValue; intValue = nil }
        init?(intValue: Int) { self.stringValue = String(intValue); self.intValue = intValue }
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: DynamicKey.self)
        func text(_ key: String) -> String? {
            guard let key = DynamicKey(stringValue: key) else { return nil }
            return try? values.decodeIfPresent(String.self, forKey: key)
        }
        func integer(_ key: String) -> Int? {
            guard let key = DynamicKey(stringValue: key) else { return nil }
            if let value = try? values.decode(Int.self, forKey: key) { return value }
            if let value = try? values.decode(Double.self, forKey: key), value.isFinite,
               value.rounded() == value, value >= Double(Int.min), value <= Double(Int.max) { return Int(value) }
            return nil
        }
        var raw: [String: APIReferenceJSONValue] = [:]
        for key in values.allKeys {
            raw[key.stringValue] = try? values.decode(APIReferenceJSONValue.self, forKey: key)
        }
        guard let eventID = text("id"), !eventID.isEmpty else {
            throw LogErrorsClientError.invalidResponse
        }
        id = eventID
        source = text("source")
        service = text("service")
        surface = text("surface")
        method = text("method")
        path = text("path")
        statusCode = integer("status_code")
        errorCode = text("error_code")
        message = text("message")
        requestID = text("request_id")
        userID = text("user_id")
        level = text("level")
        createdAt = text("created_at")
        self.raw = raw
    }

    var prettyJSON: String {
        APIReferenceJSONValue.object(raw).prettyJSON
    }

    func validate() throws {
        let strings = [id, source, service, surface, method, path, errorCode, message, requestID, userID, level, createdAt].compactMap { $0 }
        guard !id.isEmpty, id.utf8.count <= 256,
              statusCode == nil || (400...599).contains(statusCode!),
              (source?.utf8.count ?? 0) <= 40,
              (service?.utf8.count ?? 0) <= 300,
              (surface?.utf8.count ?? 0) <= 120,
              (method?.utf8.count ?? 0) <= 32,
              (path?.utf8.count ?? 0) <= 2_048,
              (errorCode?.utf8.count ?? 0) <= 256,
              (message?.utf8.count ?? 0) <= 20_000,
              (requestID?.utf8.count ?? 0) <= 256,
              (userID?.utf8.count ?? 0) <= 256,
              (level?.utf8.count ?? 0) <= 40,
              (createdAt?.utf8.count ?? 0) <= 100,
              !strings.contains(where: Self.hasDisallowedControlCharacters),
              raw.count <= 64 else {
            throw LogErrorsClientError.invalidResponse
        }
    }

    private static func hasDisallowedControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t" }
    }
}

struct LogErrorCount: Decodable, Equatable {
    let count: Int
    let label: String

    private enum CodingKeys: String, CodingKey { case count, statusCode = "status_code", surface, errorCode = "error_code" }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        count = try values.decode(Int.self, forKey: .count)
        if values.contains(.statusCode) {
            label = try values.decodeIfPresent(Int.self, forKey: .statusCode).map(String.init) ?? "unreported"
        }
        else if let surface = try? values.decode(String.self, forKey: .surface) { label = surface }
        else { label = (try? values.decode(String.self, forKey: .errorCode)) ?? "uncategorized" }
    }

    func validate() throws {
        guard count >= 0, label.utf8.count <= 256, !label.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            throw LogErrorsClientError.invalidResponse
        }
    }
}

struct LogErrorsSummary: Decodable, Equatable {
    let total: Int
    let lastHour: Int
    let last24Hours: Int
    let serverErrors: Int
    let clientErrors: Int
    let statusCounts: [LogErrorCount]
    let surfaceCounts: [LogErrorCount]
    let codeCounts: [LogErrorCount]

    private enum CodingKeys: String, CodingKey {
        case total
        case lastHour = "last_hour"
        case last24Hours = "last_24h"
        case serverErrors = "server_errors"
        case clientErrors = "client_errors"
        case statusCounts = "status_counts"
        case surfaceCounts = "surface_counts"
        case codeCounts = "code_counts"
    }

    func validate() throws {
        guard [total, lastHour, last24Hours, serverErrors, clientErrors].allSatisfy({ $0 >= 0 }),
              statusCounts.count <= 512, surfaceCounts.count <= 512, codeCounts.count <= 512 else {
            throw LogErrorsClientError.invalidResponse
        }
        for item in statusCounts + surfaceCounts + codeCounts { try item.validate() }
    }
}

struct LogErrorsEnvelope: Decodable, Equatable {
    let generatedAt: String
    let summary: LogErrorsSummary?
    let summaryAvailable: Bool?
    let summaryCheckedAt: String?
    let summaryWarning: String?
    let warnings: [String]
    let errors: [LogErrorEvent]

    private enum CodingKeys: String, CodingKey {
        case generatedAt = "generated_at"
        case summary
        case summaryAvailable = "summary_available"
        case summaryCheckedAt = "summary_checked_at"
        case summaryWarning = "summary_warning"
        case warnings
        case errors
    }

    func validate() throws {
        guard !generatedAt.isEmpty, generatedAt.utf8.count <= 100,
              (summaryCheckedAt?.utf8.count ?? 0) <= 100,
              (summaryWarning?.utf8.count ?? 0) <= 2_000,
              warnings.count <= 100, warnings.allSatisfy({ $0.utf8.count <= 2_000 }),
              errors.count <= LogErrorsClient.pageSize,
              Set(errors.map(\.id)).count == errors.count else {
            throw LogErrorsClientError.invalidResponse
        }
        for item in errors { try item.validate() }
        try summary?.validate()
    }
}
