import Foundation

struct LogsSearchFilters: Equatable {
  var hours = 24
  var service = ""
  var severity = "all"
  var search = ""
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

struct LogsSearchPage: Decodable, Equatable {
  let rows: [LogsSearchEvent]
  let nextCursor: String?

  private enum CodingKeys: String, CodingKey {
    case rows
    case nextCursor = "next_cursor"
  }

  func validate() throws {
    guard rows.count <= LogsSearchClient.pageSize,
      Set(rows.map(\.id)).count == rows.count,
      (nextCursor?.utf8.count ?? 0) <= LogsSearchClient.cursorBytes,
      !(nextCursor ?? "").unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw LogsSearchClientError.invalidResponse }
    for row in rows {
      try row.validate()
    }
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
