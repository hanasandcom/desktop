import Foundation

struct LogsRealtimeEvent: Decodable, Identifiable, Equatable {
  let id: String
  let timestamp: String
  let severity: String
  let service: String
  let host: String
  let message: String
  let rawNormalized: APIReferenceJSONValue
  var detections: [LogsDetection] { logsDetections(from: rawNormalized) }

  var copyJSON: String {
    let payload: [String: Any] = ["id": id, "event_timestamp": timestamp, "normalized": logsJSONFoundationValue(rawNormalized)]
    guard let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
      let value = String(data: data, encoding: .utf8) else { return "{}" }
    return value
  }

  private enum CodingKeys: String, CodingKey {
    case id
    case eventTimestamp = "event_timestamp"
    case normalized
  }
  private enum NormalizedKeys: String, CodingKey { case severity, service, host, message }

  init(
    id: String, timestamp: String, severity: String, service: String, host: String, message: String,
    rawNormalized: APIReferenceJSONValue? = nil
  ) {
    self.id = id
    self.timestamp = timestamp
    self.severity = severity
    self.service = service
    self.host = host
    self.message = message
    self.rawNormalized = rawNormalized ?? .object([
      "severity": .string(severity), "service": .string(service),
      "host": .string(host), "message": .string(message),
    ])
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    if let stringID = try? values.decode(String.self, forKey: .id) {
      id = stringID
    } else if let numberID = try? values.decode(Int64.self, forKey: .id) {
      id = String(numberID)
    } else {
      throw LogsRealtimeClientError.invalidResponse
    }
    timestamp = try values.decode(String.self, forKey: .eventTimestamp)
    rawNormalized = try values.decode(APIReferenceJSONValue.self, forKey: .normalized)
    let normalized = try values.nestedContainer(keyedBy: NormalizedKeys.self, forKey: .normalized)
    severity = try normalized.decode(String.self, forKey: .severity).lowercased()
    service = try normalized.decode(String.self, forKey: .service)
    host = (try? normalized.decode(String.self, forKey: .host)) ?? ""
    message = try normalized.decode(String.self, forKey: .message)
  }

  func validate() throws {
    guard !id.isEmpty, id.count <= 200,
      ["high", "critical"].contains(severity),
      !service.isEmpty, service.count <= 300,
      host.count <= 500, message.count <= 20_000,
      !timestamp.isEmpty, timestamp.count <= 80,
      ![id, service, host, message, timestamp].contains(where: Self.hasControlCharacters)
    else {
      throw LogsRealtimeClientError.invalidResponse
    }
  }

  private static func hasControlCharacters(_ value: String) -> Bool {
    value.unicodeScalars.contains {
      CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
    }
  }
}

struct LogsRealtimeFilters: Equatable {
  var hours = 24
  var service = ""
  var search = ""
  var table = "Logs"
  var advanced = false
  var hql = "ProcessLogs | where Severity in (\"high\", \"critical\") | order by TimeGenerated desc | take 100"

  static func fromRouteQuery(_ query: [String: String]) -> Self {
    var filters = Self()
    if let hours = query["hours"].flatMap(Int.init), [1, 24, 168, 720, 2_160].contains(hours) {
      filters.hours = hours
    }
    if let service = boundedLogsRouteValue(query["service"], maximum: 300) { filters.service = service }
    if let search = boundedLogsRouteValue(query["search"], maximum: 120) { filters.search = search }
    if let table = query["table"], LogsSearchClient.tables.contains(table) { filters.table = table }
    if let hql = boundedLogsRouteValue(query["hql"] ?? query["kql"], maximum: 4_000, allowsNewlines: true), !hql.isEmpty {
      filters.hql = hql
      filters.advanced = true
    }
    return filters
  }
}

struct LogsRealtimeEnvelope: Decodable {
  let rows: [LogsRealtimeEvent]
  let summaryRows: [LogsSearchSummaryRow]
  let summarize: String?
  let generatedAt: String?
  let nextCursor: String?
  let totalEvents: Int?

  private enum CodingKeys: String, CodingKey {
    case rows
    case summarize
    case generatedAt = "generated_at"
    case nextCursor = "next_cursor"
    case totalEvents = "total_events"
  }

  init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    summarize = try values.decodeIfPresent(String.self, forKey: .summarize)
    if summarize != nil {
      rows = []
      summaryRows = try values.decode([LogsSearchSummaryRow].self, forKey: .rows)
    } else {
      rows = try values.decode([LogsRealtimeEvent].self, forKey: .rows)
      summaryRows = []
    }
    generatedAt = try values.decodeIfPresent(String.self, forKey: .generatedAt)
    nextCursor = try values.decodeIfPresent(String.self, forKey: .nextCursor)
    totalEvents = try values.decodeIfPresent(Int.self, forKey: .totalEvents)
  }

  func validate() throws {
    guard rows.count <= LogsRealtimeClient.pageSize,
      summaryRows.count <= LogsSearchClient.summaryLimit,
      (summarize?.utf8.count ?? 0) <= 120,
      Set(rows.map(\.id)).count == rows.count,
      (nextCursor?.utf8.count ?? 0) <= LogsSearchClient.cursorBytes,
      !(nextCursor ?? "").unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      totalEvents == nil || totalEvents! >= 0
    else { throw LogsRealtimeClientError.invalidResponse }
    for row in rows {
      try row.validate()
    }
    for row in summaryRows { try row.validate() }
  }
}

enum LogsRealtimeClientError: LocalizedError, Equatable {
  case signInRequired
  case impersonationUnsupported
  case insecureEndpoint
  case invalidResponse
  case requestFailed(Int)

  var errorDescription: String? {
    switch self {
    case .signInRequired: "Sign in to view realtime logs."
    case .impersonationUnsupported: "Realtime logs are available only in your own account."
    case .insecureEndpoint: "Realtime logs require a valid HTTPS API address."
    case .invalidResponse: "The log service returned an invalid response."
    case .requestFailed(401): "Sign in again to view realtime logs."
    case .requestFailed(403): "Current account does not have log access."
    case .requestFailed: "Realtime logs are unavailable. Refresh to try again."
    }
  }
}

struct LogsRealtimeClient {
  static let pageSize = 100
  static let retainedLimit = 600
  static let refreshInterval: Duration = .seconds(10)

  private let apiBaseURL: URL
  private let userID: String
  private let token: String
  private let send: (URLRequest) async throws -> (Data, URLResponse)

  init(
    apiBaseURL: URL, userID: String, token: String, impersonationToken: String = "",
    impersonatingUserID: String = "",
    send: ((URLRequest) async throws -> (Data, URLResponse))? = nil
  ) throws {
    let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !user.isEmpty, !credential.isEmpty else { throw LogsRealtimeClientError.signInRequired }
    guard impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw LogsRealtimeClientError.impersonationUnsupported
    }
    guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
      apiBaseURL.user == nil, apiBaseURL.password == nil,
      apiBaseURL.query == nil, apiBaseURL.fragment == nil,
      user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
      credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil
    else {
      throw LogsRealtimeClientError.insecureEndpoint
    }
    self.apiBaseURL = apiBaseURL
    self.userID = user
    self.token = credential
    self.send = try send ?? Self.urlSessionSender()
  }

  func load(filters: LogsRealtimeFilters = LogsRealtimeFilters(), cursor: String? = nil) async throws -> LogsRealtimeEnvelope {
    let url = try Self.requestURL(apiBaseURL: apiBaseURL, filters: filters, cursor: cursor)
    var request = URLRequest(url: url, timeoutInterval: 15)
    request.httpMethod = "GET"
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.setValue(userID, forHTTPHeaderField: "id")

    let (data, response) = try await send(request)
    guard let http = response as? HTTPURLResponse,
      response.url?.scheme?.lowercased() == "https", response.url?.host == apiBaseURL.host
    else {
      throw LogsRealtimeClientError.invalidResponse
    }
    guard (200..<300).contains(http.statusCode) else {
      throw LogsRealtimeClientError.requestFailed(http.statusCode)
    }
    guard data.count <= 2 * 1024 * 1024 else { throw LogsRealtimeClientError.invalidResponse }
    let envelope: LogsRealtimeEnvelope
    do { envelope = try JSONDecoder().decode(LogsRealtimeEnvelope.self, from: data) } catch {
      throw LogsRealtimeClientError.invalidResponse
    }
    try envelope.validate()
    return envelope
  }

  static func requestURL(apiBaseURL: URL, filters: LogsRealtimeFilters = LogsRealtimeFilters(), cursor: String? = nil) throws -> URL {
    guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
      apiBaseURL.user == nil, apiBaseURL.password == nil,
      apiBaseURL.query == nil, apiBaseURL.fragment == nil
    else { throw LogsRealtimeClientError.insecureEndpoint }
    let hours = filters.hours
    let service = filters.service.trimmingCharacters(in: .whitespacesAndNewlines)
    let search = filters.search.trimmingCharacters(in: .whitespacesAndNewlines)
    guard (1...(24 * 90)).contains(hours), service.utf8.count <= 300,
      search.utf8.count <= 120,
      ![service, search].contains(where: { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
      LogsSearchClient.tables.contains(filters.table), filters.hql.utf8.count <= 4_000,
      !filters.hql.unicodeScalars.contains(where: {
        CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\t"
      }),
      !filters.advanced || !filters.hql.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      (cursor?.utf8.count ?? 0) <= LogsSearchClient.cursorBytes,
      !(cursor ?? "").unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
      !filters.advanced || cursor == nil
    else { throw LogsRealtimeClientError.invalidResponse }
    var components = URLComponents(
      url: apiBaseURL.appendingAPIPath("logs/search"), resolvingAgainstBaseURL: false)
    var queryItems = [
      URLQueryItem(name: "hours", value: String(hours)),
      URLQueryItem(name: "hql", value: filters.advanced ? filters.hql.trimmingCharacters(in: .whitespacesAndNewlines) : "\(filters.table) | take 100"),
      URLQueryItem(name: "realtime", value: "1"),
      URLQueryItem(name: "severity", value: "high,critical"),
    ]
    if !filters.advanced { queryItems.append(URLQueryItem(name: "paginate", value: "1")) }
    if !service.isEmpty { queryItems.append(URLQueryItem(name: "service", value: service)) }
    if !filters.advanced, !search.isEmpty { queryItems.append(URLQueryItem(name: "search", value: search)) }
    if !filters.advanced, let cursor, !cursor.isEmpty { queryItems.append(URLQueryItem(name: "cursor", value: cursor)) }
    components?.queryItems = queryItems
    guard let url = components?.url, url.host == apiBaseURL.host else {
      throw LogsRealtimeClientError.insecureEndpoint
    }
    return url
  }

  private static func urlSessionSender() throws -> (URLRequest) async throws -> (Data, URLResponse)
  {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.urlCache = nil
    let session = URLSession(
      configuration: configuration, delegate: LogsRealtimeRedirectBlocker(), delegateQueue: nil)
    return { request in try await session.data(for: request) }
  }
}

private final class LogsRealtimeRedirectBlocker: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}
