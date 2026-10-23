import Foundation

private final class LogsSearchRedirectBlocker: NSObject, URLSessionTaskDelegate {
  func urlSession(
    _ session: URLSession, task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
  ) {
    completionHandler(nil)
  }
}

private enum LogsSearchSession {
  static let shared: URLSession = {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.urlCache = nil
    return URLSession(
      configuration: configuration, delegate: LogsSearchRedirectBlocker(), delegateQueue: nil)
  }()

  static func send(_ request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
    let (bytes, response) = try await shared.bytes(for: request)
    if let http = response as? HTTPURLResponse,
      let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
      length > limit
    {
      throw LogsSearchClientError.invalidResponse
    }
    var data = Data()
    data.reserveCapacity(min(limit, 64 * 1024))
    for try await byte in bytes {
      guard data.count < limit else { throw LogsSearchClientError.invalidResponse }
      data.append(byte)
    }
    return (data, response)
  }
}

struct LogsSearchClient {
  typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

  static let pageSize = 200
  static let responseBytes = 4 * 1024 * 1024
  static let cursorBytes = 2_048

  private let apiBaseURL: URL
  private let userID: String
  private let token: String
  private let send: Sender

  init(
    apiBaseURL: URL, userID: String, token: String, impersonationToken: String = "",
    impersonatingUserID: String = "", send: Sender? = nil
  ) throws {
    let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
    let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
    guard impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
      impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw LogsSearchClientError.impersonationUnsupported }
    guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
      apiBaseURL.user == nil, apiBaseURL.password == nil,
      apiBaseURL.query == nil, apiBaseURL.fragment == nil
    else { throw LogsSearchClientError.insecureEndpoint }
    guard !user.isEmpty, !credential.isEmpty else { throw LogsSearchClientError.signInRequired }
    guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
      credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil
    else { throw LogsSearchClientError.insecureEndpoint }
    self.apiBaseURL = apiBaseURL
    self.userID = user
    self.token = credential
    self.send =
      send ?? { request in
        try await LogsSearchSession.send(request, limit: Self.responseBytes)
      }
  }

  func load(filters: LogsSearchFilters, cursor: String? = nil) async throws -> LogsSearchPage {
    guard (1...(24 * 90)).contains(filters.hours),
      ["all", "low", "medium", "high", "critical"].contains(filters.severity),
      filters.search.count <= 120, filters.service.count <= 300,
      filters.search.rangeOfCharacter(from: .controlCharacters) == nil,
      filters.service.rangeOfCharacter(from: .controlCharacters) == nil,
      (cursor?.utf8.count ?? 0) <= Self.cursorBytes,
      !(cursor ?? "").unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    else { throw LogsSearchClientError.invalidFilters }

    let url = try Self.requestURL(apiBaseURL: apiBaseURL, filters: filters, cursor: cursor)
    var request = URLRequest(url: url, timeoutInterval: 30)
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
    else { throw LogsSearchClientError.invalidResponse }
    guard (200..<300).contains(http.statusCode) else {
      throw LogsSearchClientError.requestFailed(http.statusCode)
    }
    guard data.count <= Self.responseBytes else { throw LogsSearchClientError.invalidResponse }
    let page: LogsSearchPage
    do { page = try JSONDecoder().decode(LogsSearchPage.self, from: data) } catch {
      throw LogsSearchClientError.invalidResponse
    }
    try page.validate()
    return page
  }

  static func requestURL(
    apiBaseURL: URL, filters: LogsSearchFilters, cursor: String? = nil
  ) throws -> URL {
    guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
      apiBaseURL.user == nil, apiBaseURL.password == nil,
      apiBaseURL.query == nil, apiBaseURL.fragment == nil
    else { throw LogsSearchClientError.insecureEndpoint }
    var components = URLComponents(
      url: apiBaseURL.appendingAPIPath("logs/search"), resolvingAgainstBaseURL: false)
    var queryItems = [
      URLQueryItem(name: "hours", value: String(filters.hours)),
      URLQueryItem(name: "paginate", value: "1"),
    ]
    let search = filters.search.trimmingCharacters(in: .whitespacesAndNewlines)
    let service = filters.service.trimmingCharacters(in: .whitespacesAndNewlines)
    if !search.isEmpty { queryItems.append(URLQueryItem(name: "search", value: search)) }
    if !service.isEmpty { queryItems.append(URLQueryItem(name: "service", value: service)) }
    if filters.severity != "all" {
      queryItems.append(URLQueryItem(name: "severity", value: filters.severity))
    }
    if let cursor, !cursor.isEmpty {
      queryItems.append(URLQueryItem(name: "cursor", value: cursor))
    }
    components?.queryItems = queryItems
    guard let url = components?.url, url.host == apiBaseURL.host else {
      throw LogsSearchClientError.insecureEndpoint
    }
    return url
  }
}
