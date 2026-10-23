import Foundation

struct LogsRealtimeEvent: Decodable, Identifiable, Equatable {
  let id: String
  let timestamp: String
  let severity: String
  let service: String
  let host: String
  let message: String

  private enum CodingKeys: String, CodingKey {
    case id
    case eventTimestamp = "event_timestamp"
    case normalized
  }
  private enum NormalizedKeys: String, CodingKey { case severity, service, host, message }

  init(
    id: String, timestamp: String, severity: String, service: String, host: String, message: String
  ) {
    self.id = id
    self.timestamp = timestamp
    self.severity = severity
    self.service = service
    self.host = host
    self.message = message
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

struct LogsRealtimeEnvelope: Decodable {
  let rows: [LogsRealtimeEvent]
  let generatedAt: String?

  private enum CodingKeys: String, CodingKey {
    case rows
    case generatedAt = "generated_at"
  }

  func validate() throws {
    guard rows.count <= LogsRealtimeClient.pageSize,
      Set(rows.map(\.id)).count == rows.count
    else { throw LogsRealtimeClientError.invalidResponse }
    for row in rows {
      try row.validate()
    }
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
  static let retainedLimit = 120
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

  func load() async throws -> LogsRealtimeEnvelope {
    let url = try Self.requestURL(apiBaseURL: apiBaseURL)
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

  static func requestURL(apiBaseURL: URL) throws -> URL {
    guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
      apiBaseURL.user == nil, apiBaseURL.password == nil,
      apiBaseURL.query == nil, apiBaseURL.fragment == nil
    else { throw LogsRealtimeClientError.insecureEndpoint }
    var components = URLComponents(
      url: apiBaseURL.appendingAPIPath("logs/search"), resolvingAgainstBaseURL: false)
    components?.queryItems = [
      URLQueryItem(name: "hours", value: "24"),
      URLQueryItem(name: "hql", value: "Logs | take 100"),
      URLQueryItem(name: "realtime", value: "1"),
      URLQueryItem(name: "severity", value: "high,critical"),
      URLQueryItem(name: "paginate", value: "1"),
    ]
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
