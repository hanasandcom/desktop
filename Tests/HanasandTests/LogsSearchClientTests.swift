import XCTest

@testable import Hanasand

final class LogsSearchClientTests: XCTestCase {
  private let apiBase = URL(string: "https://api.example.test/api")!

  func testRequestURLUsesOnlyBasicFiltersAndNoHQL() throws {
    let filters = LogsSearchFilters(
      hours: 168, service: "gateway", severity: "high", search: "timeout")
    let url = try LogsSearchClient.requestURL(
      apiBaseURL: apiBase, filters: filters, cursor: "eyJvayI6MX0")
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.path, "/api/logs/search")
    let query = Dictionary(
      uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map {
        ($0.name, $0.value ?? "")
      })
    XCTAssertEqual(query["hours"], "168")
    XCTAssertEqual(query["paginate"], "1")
    XCTAssertEqual(query["service"], "gateway")
    XCTAssertEqual(query["severity"], "high")
    XCTAssertEqual(query["search"], "timeout")
    XCTAssertEqual(query["cursor"], "eyJvayI6MX0")
    XCTAssertNil(query["hql"])
    XCTAssertNil(query["kql"])
    XCTAssertNil(query["realtime"])
  }

  func testLoadSendsOwnAccountHeadersAndDecodesBoundedEvents() async throws {
    let filters = LogsSearchFilters(hours: 24, service: "api", severity: "all", search: "")
    let url = try LogsSearchClient.requestURL(apiBaseURL: apiBase, filters: filters)
    let body =
      #"{"rows":[{"id":"e-1","event_timestamp":"2026-10-23T12:00:00Z","normalized":{"severity":"medium","level":"warn","log_type":"application","service":"api","host":"node-1","message":"A bounded message"}}],"next_cursor":"eyJ0aW1lIjoiMjAyNiJ9"}"#
      .data(using: .utf8)!
    var captured: URLRequest?
    let client = try LogsSearchClient(apiBaseURL: apiBase, userID: "user-1", token: "opaque-token")
    {
      request in
      captured = request
      return (
        body,
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }

    let page = try await client.load(filters: filters)
    XCTAssertEqual(captured?.httpMethod, "GET")
    XCTAssertEqual(captured?.url, url)
    XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-token")
    XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "user-1")
    XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(page.rows.first?.service, "api")
    XCTAssertEqual(page.rows.first?.severity, "medium")
    XCTAssertEqual(page.nextCursor, "eyJ0aW1lIjoiMjAyNiJ9")
  }

  func testRejectsImpersonationInsecureEndpointAndInvalidFilters() async throws {
    XCTAssertThrowsError(
      try LogsSearchClient(
        apiBaseURL: apiBase, userID: "user-1", token: "token", impersonationToken: "delegate")
    ) { XCTAssertEqual($0 as? LogsSearchClientError, .impersonationUnsupported) }
    XCTAssertThrowsError(
      try LogsSearchClient(
        apiBaseURL: URL(string: "http://api.example.test/api")!, userID: "user-1", token: "token")
    ) { XCTAssertEqual($0 as? LogsSearchClientError, .insecureEndpoint) }

    let client = try LogsSearchClient(apiBaseURL: apiBase, userID: "user-1", token: "token")
    do {
      _ = try await client.load(
        filters: LogsSearchFilters(hours: 24, service: "", severity: "debug", search: ""))
      XCTFail("Expected invalid filters")
    } catch {
      XCTAssertEqual(error as? LogsSearchClientError, .invalidFilters)
    }
  }

  func testRejectsOversizedResponseAndRowsWithOutOfRangeSeverity() async throws {
    let filters = LogsSearchFilters()
    let url = try LogsSearchClient.requestURL(apiBaseURL: apiBase, filters: filters)
    let oversized = Data(repeating: 0x20, count: LogsSearchClient.responseBytes + 1)
    let oversizedClient = try LogsSearchClient(
      apiBaseURL: apiBase, userID: "user-1", token: "token"
    ) { _ in
      (oversized, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    do {
      _ = try await oversizedClient.load(filters: filters)
      XCTFail("Expected oversized response rejection")
    } catch {
      XCTAssertEqual(error as? LogsSearchClientError, .invalidResponse)
    }

    let invalid =
      #"{"rows":[{"id":"e-1","event_timestamp":"2026-10-23T12:00:00Z","normalized":{"severity":"debug","service":"api","message":"not in the contract"}}]}"#
      .data(using: .utf8)!
    let invalidClient = try LogsSearchClient(
      apiBaseURL: apiBase, userID: "user-1", token: "token"
    ) { _ in
      (invalid, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    do {
      _ = try await invalidClient.load(filters: filters)
      XCTFail("Expected invalid row rejection")
    } catch {
      XCTAssertEqual(error as? LogsSearchClientError, .invalidResponse)
    }
  }

}
