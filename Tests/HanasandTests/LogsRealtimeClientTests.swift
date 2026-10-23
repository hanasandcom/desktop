import XCTest

@testable import Hanasand

final class LogsRealtimeClientTests: XCTestCase {
  func testRequestURLMatchesAuthenticatedWebsiteRealtimeQuery() throws {
    let url = try LogsRealtimeClient.requestURL(
      apiBaseURL: URL(string: "https://api.example.test/api")!)
    let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
    XCTAssertEqual(components.path, "/api/logs/search")
    let query = Dictionary(
      uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value) })
    XCTAssertEqual(query["hours"], "24")
    XCTAssertEqual(query["hql"], "Logs | take 100")
    XCTAssertEqual(query["realtime"], "1")
    XCTAssertEqual(query["severity"], "high,critical")
    XCTAssertEqual(query["paginate"], "1")
  }

  func testLoadUsesOwnAccountBearerAndDecodesBoundedHighSeverityRows() async throws {
    let apiBase = URL(string: "https://api.example.test/api")!
    let responseURL = try LogsRealtimeClient.requestURL(apiBaseURL: apiBase)
    let json =
      #"{"rows":[{"id":"event-1","event_timestamp":"2026-10-23T09:20:00Z","normalized":{"severity":"critical","service":"api","host":"node-1","message":"Read only event"}}],"generated_at":"2026-10-23T09:20:01Z"}"#
      .data(using: .utf8)!
    var captured: URLRequest?
    let client = try LogsRealtimeClient(
      apiBaseURL: apiBase, userID: "user-1", token: "opaque-token"
    ) { request in
      captured = request
      return (
        json,
        HTTPURLResponse(url: responseURL, statusCode: 200, httpVersion: nil, headerFields: nil)!
      )
    }

    let envelope = try await client.load()
    XCTAssertEqual(captured?.httpMethod, "GET")
    XCTAssertEqual(captured?.url, responseURL)
    XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-token")
    XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "user-1")
    XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(
      envelope.rows,
      [
        LogsRealtimeEvent(
          id: "event-1", timestamp: "2026-10-23T09:20:00Z", severity: "critical", service: "api",
          host: "node-1", message: "Read only event")
      ])
  }

  func testImpersonatedAndInsecureClientsAreRejected() {
    XCTAssertThrowsError(
      try LogsRealtimeClient(
        apiBaseURL: URL(string: "https://api.example.test/api")!, userID: "user-1", token: "token",
        impersonationToken: "delegated")
    ) { error in
      XCTAssertEqual(error as? LogsRealtimeClientError, .impersonationUnsupported)
    }
    XCTAssertThrowsError(
      try LogsRealtimeClient(
        apiBaseURL: URL(string: "http://api.example.test/api")!, userID: "user-1", token: "token")
    ) { error in
      XCTAssertEqual(error as? LogsRealtimeClientError, .insecureEndpoint)
    }
  }

  func testDecoderRejectsRowsOutsideRealtimeSeverityContract() throws {
    let json =
      #"{"rows":[{"id":"event-1","event_timestamp":"2026-10-23T09:20:00Z","normalized":{"severity":"low","service":"api","message":"not realtime"}}]}"#
      .data(using: .utf8)!
    let envelope = try JSONDecoder().decode(LogsRealtimeEnvelope.self, from: json)
    XCTAssertThrowsError(try envelope.validate()) { error in
      XCTAssertEqual(error as? LogsRealtimeClientError, .invalidResponse)
    }
  }
}
