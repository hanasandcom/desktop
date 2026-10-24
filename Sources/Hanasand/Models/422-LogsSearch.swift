import Foundation

struct LogsSearchFilters: Equatable {
  var hours = 24
  var service = ""
  var severity = "all"
  var search = ""
  var table = "Logs"
  var advanced = false
  var hql = "ProcessLogs | where Severity in (\"high\", \"critical\") | order by TimeGenerated desc | take 100"
  var dashboardStats = false
}

struct LogsSearchEvent: Decodable, Identifiable, Equatable {
  let id: String
  let timestamp: String
  let severity: String
  let level: String
  let type: String
  let service: String
  let host: String
  let message: String
  let rawNormalized: APIReferenceJSONValue

  var copyJSON: String {
    let payload: [String: Any] = ["id": id, "event_timestamp": timestamp, "normalized": logsJSONFoundationValue(rawNormalized)]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
      let value = String(data: data, encoding: .utf8)
    else { return "{}" }
    return value
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case eventTimestamp = "event_timestamp"
    case normalized
  }
  private enum NormalizedKeys: String, CodingKey {
    case severity, level, service, host, message
    case type = "log_type"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    if let stringID = try? values.decode(String.self, forKey: .id) {
      id = stringID
    } else if let numberID = try? values.decode(Int64.self, forKey: .id) {
      id = String(numberID)
    } else {
      throw LogsSearchClientError.invalidResponse
    }
    timestamp = try values.decode(String.self, forKey: .eventTimestamp)
    rawNormalized = try values.decode(APIReferenceJSONValue.self, forKey: .normalized)
    let normalized = try values.nestedContainer(keyedBy: NormalizedKeys.self, forKey: .normalized)
    severity = try normalized.decode(String.self, forKey: .severity).lowercased()
    level = (try? normalized.decode(String.self, forKey: .level)) ?? severity
    type = (try? normalized.decode(String.self, forKey: .type)) ?? ""
    service = try normalized.decode(String.self, forKey: .service)
    host = (try? normalized.decode(String.self, forKey: .host)) ?? ""
    message = try normalized.decode(String.self, forKey: .message)
  }

  func validate() throws {
    let values = [id, timestamp, severity, level, type, service, host, message]
    guard !id.isEmpty, id.count <= 200, !timestamp.isEmpty, timestamp.count <= 80,
      ["low", "medium", "high", "critical"].contains(severity),
      level.count <= 80, type.count <= 120, !service.isEmpty, service.count <= 300,
      host.count <= 500, message.count <= 20_000,
      !values.contains(where: Self.hasDisallowedControlCharacters)
    else { throw LogsSearchClientError.invalidResponse }
  }

  private static func hasDisallowedControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
    }
  }
}

func logsJSONFoundationValue(_ value: APIReferenceJSONValue) -> Any {
  switch value {
  case .string(let string): string
  case .number(let number): number
  case .bool(let boolean): boolean
  case .null: NSNull()
  case .object(let object): object.mapValues(logsJSONFoundationValue)
  case .array(let array): array.map(logsJSONFoundationValue)
  }
}

struct LogsSearchPage: Decodable, Equatable {
  let rows: [LogsSearchEvent]
  let summaryRows: [LogsSearchSummaryRow]
  let summarize: String?
  let nextCursor: String?
  let counts: [LogsSearchCount]
  let services: [LogsSearchServiceCount]
  let processing: LogsProcessingStatus?
  let generatedAt: String?

  private enum CodingKeys: String, CodingKey {
    case rows
    case summarize
    case nextCursor = "next_cursor"
    case counts, services, processing
    case generatedAt = "generated_at"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    summarize = try values.decodeIfPresent(String.self, forKey: .summarize)
    if summarize != nil {
      rows = []
      summaryRows = try values.decode([LogsSearchSummaryRow].self, forKey: .rows)
    } else {
      rows = try values.decode([LogsSearchEvent].self, forKey: .rows)
      summaryRows = []
    }
    nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
    counts = (try? values.decode([LogsSearchCount].self, forKey: .counts)) ?? []
    services = (try? values.decode([LogsSearchServiceCount].self, forKey: .services)) ?? []
    processing = try? values.decodeIfPresent(LogsProcessingStatus.self, forKey: .processing)
    generatedAt = try? values.decodeIfPresent(String.self, forKey: .generatedAt)
  }

  func validate() throws {
    guard rows.count <= LogsSearchClient.pageSize,
      summaryRows.count <= LogsSearchClient.summaryLimit,
      counts.count <= 4, services.count <= 100,
      (summarize?.utf8.count ?? 0) <= 120,
      Set(rows.map(\.id)).count == rows.count,
      (nextCursor?.utf8.count ?? 0) <= LogsSearchClient.cursorBytes,
      !(nextCursor ?? "").unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw LogsSearchClientError.invalidResponse }
    for row in rows {
      try row.validate()
    }
    for row in summaryRows { try row.validate() }
    guard counts.allSatisfy({ ["low", "medium", "high", "critical"].contains($0.severity) && $0.count >= 0 }),
      services.allSatisfy({ $0.service.utf8.count <= 300 && $0.count >= 0 && !$0.service.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
      (generatedAt?.utf8.count ?? 0) <= 80,
      (processing?.lastError?.utf8.count ?? 0) <= 2_000,
      (processing?.skippedEvents ?? 0) >= 0
    else { throw LogsSearchClientError.invalidResponse }
    if let progress = processing?.catchup {
      guard progress.remaining >= 0, progress.processed >= 0, progress.total >= 0,
        progress.updatedAt.utf8.count <= 80,
        (progress.lastError?.utf8.count ?? 0) <= 2_000,
        [progress.rate, progress.estimatedSeconds].compactMap({ $0 }).allSatisfy({ $0.isFinite && $0 >= 0 })
      else { throw LogsSearchClientError.invalidResponse }
    }
  }
}

struct LogsSearchCount: Decodable, Equatable {
  let severity: String
  let count: Int
}

struct LogsSearchServiceCount: Decodable, Equatable {
  let service: String
  let count: Int
}

struct LogsProcessingStatus: Decodable, Equatable {
  let updatedAt: String
  let lastError: String?
  let skippedEvents: Int?
  let skippedEventsAvailable: Bool?
  let skippedEventsCheckedAt: String?
  let skippedEventsWarning: String?
  let catchup: LogsCatchupProgress?

  private enum CodingKeys: String, CodingKey {
    case updatedAt = "updated_at", lastError = "last_error", skippedEvents = "skipped_events"
    case skippedEventsAvailable = "skipped_events_available", skippedEventsCheckedAt = "skipped_events_checked_at"
    case skippedEventsWarning = "skipped_events_warning", catchup
  }
}

struct LogsCatchupProgress: Decodable, Equatable {
  let remaining: Int
  let processed: Int
  let total: Int
  let rate: Double?
  let estimatedSeconds: Double?
  let updatedAt: String
  let lastError: String?

  private enum CodingKeys: String, CodingKey {
    case remaining, processed, total, rate, updatedAt = "updated_at"
    case estimatedSeconds = "estimated_seconds", lastError = "last_error"
  }
}

struct LogsDashboardSummary: Decodable, Equatable {
  struct Scope: Decodable, Equatable {
    let services: [LogsSearchServiceCount]
    let severities: [String: Int]
  }
  let last24Hours: Scope
  let total: Scope
  private enum CodingKeys: String, CodingKey { case last24Hours = "last_24h", total }

  func validate() throws {
    for scope in [last24Hours, total] {
      guard scope.services.count <= 10,
        scope.services.allSatisfy({ $0.service.utf8.count <= 300 && $0.count >= 0 && !$0.service.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
        scope.severities.keys.allSatisfy({ ["low", "medium", "high", "critical"].contains($0) }),
        scope.severities.values.allSatisfy({ $0 >= 0 })
      else { throw LogsSearchClientError.invalidResponse }
    }
  }
}

struct LogsThroughputMetrics: Decodable, Equatable {
  struct Point: Decodable, Equatable {
    let sampledAt: String
    let pps: Double
    let eps: Double
    let historicalEps: Double
    let npps: Double
    let remaining: Int
    private enum CodingKeys: String, CodingKey {
      case sampledAt = "sampled_at", pps, eps, historicalEps = "historical_eps", npps, remaining
    }
  }
  struct Current: Decodable, Equatable {
    let pps: Double
    let eps: Double
    let historicalEps: Double
    let npps: Double
    let remaining: Int
    private enum CodingKeys: String, CodingKey { case pps, eps, historicalEps = "historical_eps", npps, remaining }
  }
  let generatedAt: String
  let current: Current
  let history: [Point]
  private enum CodingKeys: String, CodingKey { case generatedAt = "generated_at", current, history }

  func validate() throws {
    let values = [current.pps, current.eps, current.historicalEps, current.npps]
      + history.flatMap { [$0.pps, $0.eps, $0.historicalEps, $0.npps] }
    guard generatedAt.utf8.count <= 80, history.count <= 300,
      current.remaining >= 0, history.allSatisfy({ $0.remaining >= 0 && $0.sampledAt.utf8.count <= 80 }),
      values.allSatisfy({ $0.isFinite && $0 >= 0 })
    else { throw LogsSearchClientError.invalidResponse }
  }
}

struct LogsSearchSummaryRow: Decodable, Equatable {
  let value: String
  let count: Int

  private enum CodingKeys: String, CodingKey { case value, count }

  init(value: String, count: Int) {
    self.value = value
    self.count = count
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    let raw = try values.decode(APIReferenceJSONValue.self, forKey: .value)
    switch raw {
    case .string(let value): self.value = value
    case .number(let value):
      if value.isFinite, value.rounded() == value,
        value >= Double(Int.min), value <= Double(Int.max)
      { self.value = String(Int(value)) }
      else { self.value = String(value) }
    case .bool(let value): self.value = value ? "true" : "false"
    case .null: self.value = ""
    case .object, .array: self.value = raw.prettyJSON
    }
    count = try values.decode(Int.self, forKey: .count)
  }

  func validate() throws {
    guard value.utf8.count <= 2_048, count >= 0,
      !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw LogsSearchClientError.invalidResponse }
  }
}

enum LogsSearchClientError: LocalizedError, Equatable {
  case signInRequired
  case impersonationUnsupported
  case insecureEndpoint
  case invalidFilters
  case invalidResponse
  case requestFailed(Int)

  var errorDescription: String? {
    switch self {
    case .signInRequired: "Sign in to search logs."
    case .impersonationUnsupported: "Log search is available only in your own account."
    case .insecureEndpoint: "Log search requires a valid HTTPS API address."
    case .invalidFilters: "Choose valid log search filters."
    case .invalidResponse: "The log service returned an invalid response."
    case .requestFailed(401): "Sign in again to search logs."
    case .requestFailed(403): "Current account does not have log access."
    case .requestFailed: "Log search is unavailable. Refresh to try again."
    }
  }
}
