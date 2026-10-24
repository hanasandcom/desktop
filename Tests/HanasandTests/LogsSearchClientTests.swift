import XCTest

@testable import Hanasand

final class LogsSearchClientTests: XCTestCase {
  private let apiBase = URL(string: "https://api.example.test/api")!

  func testRequestURLIncludesWebsiteTableQueryAndBasicFilters() throws {
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
    XCTAssertEqual(query["hql"], "Logs | take 200")
    XCTAssertNil(query["kql"])
    XCTAssertNil(query["realtime"])
  }

  func testRequestURLSupportsLogTableAndAdvancedHQLWithoutPagination() throws {
    let tableFilters = LogsSearchFilters(table: "SystemLogs")
    let tableURL = try LogsSearchClient.requestURL(apiBaseURL: apiBase, filters: tableFilters)
    let tableQuery = Dictionary(uniqueKeysWithValues: URLComponents(url: tableURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(tableQuery["hql"], "SystemLogs | take 200")
    XCTAssertEqual(tableQuery["paginate"], "1")

    let advanced = LogsSearchFilters(advanced: true, hql: "ProcessLogs | where Severity == \"high\" | take 50")
    let advancedURL = try LogsSearchClient.requestURL(apiBaseURL: apiBase, filters: advanced)
    let advancedQuery = Dictionary(uniqueKeysWithValues: URLComponents(url: advancedURL, resolvingAgainstBaseURL: false)!.queryItems!.map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(advancedQuery["hql"], advanced.hql)
    XCTAssertNil(advancedQuery["paginate"])
  }

  func testDashboardRequestIncludesStatsWithoutChangingPaginationContract() throws {
    let url = try LogsSearchClient.requestURL(
      apiBaseURL: apiBase, filters: LogsSearchFilters(dashboardStats: true))
    let query = Dictionary(
      uniqueKeysWithValues: try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems).map { ($0.name, $0.value ?? "") })
    XCTAssertEqual(query["stats"], "1")
    XCTAssertEqual(query["paginate"], "1")
    XCTAssertEqual(query["hql"], "Logs | take 200")
  }

  func testDashboardResponseDecodesCountsAndCatchupStatus() async throws {
    let filters = LogsSearchFilters(dashboardStats: true)
    let url = try LogsSearchClient.requestURL(apiBaseURL: apiBase, filters: filters)
    let body = #"{"rows":[],"counts":[{"severity":"high","count":12}],"services":[{"service":"api","count":9}],"processing":{"updated_at":"2026-10-24T06:00:00Z","last_error":null,"catchup":{"remaining":2000,"processed":8000,"total":10000,"rate":15.5,"estimated_seconds":129,"updated_at":"2026-10-24T06:00:00Z"}},"generated_at":"2026-10-24T06:00:01Z"}"#.data(using: .utf8)!
    let client = try LogsSearchClient(apiBaseURL: apiBase, userID: "user-1", token: "token") { _ in
      (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let page = try await client.load(filters: filters)
    XCTAssertEqual(page.counts, [LogsSearchCount(severity: "high", count: 12)])
    XCTAssertEqual(page.services, [LogsSearchServiceCount(service: "api", count: 9)])
    XCTAssertEqual(page.processing?.catchup?.remaining, 2_000)
    XCTAssertEqual(page.processing?.catchup?.estimatedSeconds, 129)
  }

  func testCopyJSONPreservesAllNormalizedEventFields() throws {
    let body = #"{"id":"event-1","event_timestamp":"2026-10-24T06:00:00Z","normalized":{"severity":"high","level":"error","log_type":"application","service":"api","host":"node-1","message":"request failed","process":{"executable":"worker","command_line":"worker --safe"},"detections":[{"rule_id":"r-1","summary":"matched","severity":"high"}]}}"#.data(using: .utf8)!
    let event = try JSONDecoder().decode(LogsSearchEvent.self, from: body)
    let copied = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(event.copyJSON.utf8)) as? [String: Any])
    let normalized = try XCTUnwrap(copied["normalized"] as? [String: Any])
    XCTAssertEqual(normalized["process"] as? [String: String], ["executable": "worker", "command_line": "worker --safe"])
    XCTAssertEqual((normalized["detections"] as? [[String: String]])?.first?["rule_id"], "r-1")
  }

  func testDashboardSummaryAndPublicMetricsUseBoundedReadOnlyRequests() async throws {
    let summaryURL = apiBase.appendingAPIPath("logs/services/summary")
    let metricsURL = apiBase.appendingAPIPath("logs/metrics/public")
    var requests: [URLRequest] = []
    let client = try LogsSearchClient(apiBaseURL: apiBase, userID: "user-1", token: "opaque-token") { request in
      requests.append(request)
      let body: Data
      if request.url == summaryURL {
        body = #"{"last_24h":{"services":[{"service":"api","count":12}],"severities":{"low":1,"medium":2,"high":3,"critical":4}},"total":{"services":[],"severities":{"low":0,"medium":0,"high":0,"critical":0}}}"#.data(using: .utf8)!
      } else {
        body = #"{"generated_at":"2026-10-24T06:00:00Z","current":{"pps":20,"eps":5,"historical_eps":15,"npps":1,"remaining":100,"thresholds":{"npps_below":false,"eps_above":false,"pps_below":false},"alert":false},"history":[]}"#.data(using: .utf8)!
      }
      return (body, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let summary = try await client.loadDashboardSummary()
    let metrics = try await client.loadPublicThroughputMetrics()
    XCTAssertEqual(summary.last24Hours.services.first?.service, "api")
    XCTAssertEqual(summary.total.severities["high"], 0)
    XCTAssertEqual(metrics.current.pps, 20)
    XCTAssertEqual(metrics.current.remaining, 100)
    XCTAssertEqual(requests.count, 2)
    XCTAssertEqual(requests[0].url, summaryURL)
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer opaque-token")
    XCTAssertEqual(requests[0].value(forHTTPHeaderField: "id"), "user-1")
    XCTAssertEqual(requests[1].url, metricsURL)
    XCTAssertNil(requests[1].value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(requests[1].value(forHTTPHeaderField: "id"))
    XCTAssertFalse(requests.contains { $0.httpMethod != "GET" })
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

  func testLoadDecodesAdvancedSummaryRows() async throws {
    let filters = LogsSearchFilters(advanced: true, hql: "Logs | summarize count() by Service | take 50")
    let url = try LogsSearchClient.requestURL(apiBaseURL: apiBase, filters: filters)
    let body = #"{"rows":[{"value":"api","count":4}],"summarize":"service","limit":50}"#.data(using: .utf8)!
    let client = try LogsSearchClient(apiBaseURL: apiBase, userID: "user-1", token: "token") { _ in
      (body, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
    let page = try await client.load(filters: filters)
    XCTAssertEqual(page.summarize, "service")
    XCTAssertEqual(page.summaryRows, [LogsSearchSummaryRow(value: "api", count: 4)])
    XCTAssertTrue(page.rows.isEmpty)
    XCTAssertNil(page.nextCursor)
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

    do {
      _ = try await client.load(filters: LogsSearchFilters(advanced: true, hql: ""))
      XCTFail("Expected empty advanced query rejection")
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
