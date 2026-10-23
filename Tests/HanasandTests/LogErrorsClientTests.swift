import XCTest

@testable import Hanasand

final class LogErrorsClientTests: XCTestCase {
    private let apiBase = URL(string: "https://api.example.test/api")!

    func testRequestURLEncodesOnlyBoundedCompositeErrorFilters() throws {
        let filters = LogErrorsFilters(surface: "website", statusCode: 503, errorCode: "http_503", query: "gateway timeout", includeExpected: true)
        let url = try LogErrorsClient.requestURL(apiBaseURL: apiBase, filters: filters)
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.path, "/api/logs/errors")
        let query = Dictionary(uniqueKeysWithValues: try XCTUnwrap(components.queryItems).map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(query["limit"], "150")
        XCTAssertEqual(query["surface"], "website")
        XCTAssertEqual(query["status"], "503")
        XCTAssertEqual(query["code"], "http_503")
        XCTAssertEqual(query["q"], "gateway timeout")
        XCTAssertEqual(query["includeExpected"], "1")
        XCTAssertNil(query["organizationId"])
    }

    func testDefaultRequestReadsOwnAccountAndDecodesSummaryAndCompositeRows() async throws {
        let url = try LogErrorsClient.requestURL(apiBaseURL: apiBase, filters: LogErrorsFilters())
        let data = Self.envelope().data(using: .utf8)!
        var captured: URLRequest?
        let client = try LogErrorsClient(apiBaseURL: apiBase, userID: "user-1", token: "opaque-token") { request in
            captured = request
            return (data, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }

        let result = try await client.load(filters: LogErrorsFilters())
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.url, url)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(result.summary?.total, 8)
        XCTAssertEqual(result.summary?.codeCounts.first?.label, "http_503")
        XCTAssertEqual(result.summary?.statusCounts.first?.label, "unreported")
        XCTAssertEqual(result.errors.first?.source, "traffic")
        XCTAssertEqual(result.errors.first?.statusCode, 503)
        XCTAssertTrue(result.errors.first?.prettyJSON.contains("request_id") == true)
    }

    func testSummaryCanBeUnavailableWhileRecentErrorsRemainUsable() async throws {
        let url = try LogErrorsClient.requestURL(apiBaseURL: apiBase, filters: LogErrorsFilters())
        let payload = #"{"generated_at":"2026-10-23T15:00:00.000Z","summary":null,"summary_available":false,"summary_checked_at":"2026-10-23T14:59:59.000Z","summary_warning":"Historical totals unavailable.","warnings":["Historical totals unavailable."],"errors":[{"id":"login-5","source":"auth","service":"hanasand-api","surface":"auth","method":"POST","path":"/api/auth/login/:id","status_code":401,"error_code":"invalid_password","message":"Rejected login","request_id":"","user_id":"user-2","level":"warn","created_at":"2026-10-23T14:59:00.000Z"}]}"#.data(using: .utf8)!
        let client = try LogErrorsClient(apiBaseURL: apiBase, userID: "user-1", token: "token") { _ in
            (payload, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let result = try await client.load(filters: LogErrorsFilters())
        XCTAssertNil(result.summary)
        XCTAssertEqual(result.summaryAvailable, false)
        XCTAssertEqual(result.summaryWarning, "Historical totals unavailable.")
        XCTAssertEqual(result.errors.first?.errorCode, "invalid_password")
    }

    func testRejectsImpersonationInsecureEndpointAndOutOfRangeFilters() throws {
        XCTAssertThrowsError(try LogErrorsClient(apiBaseURL: apiBase, userID: "user-1", token: "token", impersonationToken: "delegate")) {
            XCTAssertEqual($0 as? LogErrorsClientError, .impersonationUnsupported)
        }
        XCTAssertThrowsError(try LogErrorsClient(apiBaseURL: URL(string: "http://api.example.test/api")!, userID: "user-1", token: "token")) {
            XCTAssertEqual($0 as? LogErrorsClientError, .insecureEndpoint)
        }
        XCTAssertThrowsError(try LogErrorsClient(apiBaseURL: apiBase, userID: "bad user", token: "token")) {
            XCTAssertEqual($0 as? LogErrorsClientError, .insecureEndpoint)
        }
        for filters in [
            LogErrorsFilters(surface: String(repeating: "x", count: 121)),
            LogErrorsFilters(errorCode: "bad\ncode"),
            LogErrorsFilters(query: String(repeating: "q", count: 121)),
            LogErrorsFilters(statusCode: 399),
        ] {
            XCTAssertThrowsError(try LogErrorsClient.requestURL(apiBaseURL: apiBase, filters: filters)) {
                XCTAssertEqual($0 as? LogErrorsClientError, .invalidFilters)
            }
        }
    }

    func testReportsServerAuthorizationFailuresClearly() async throws {
        let url = try LogErrorsClient.requestURL(apiBaseURL: apiBase, filters: LogErrorsFilters())
        for (status, expected) in [(401, "Sign in again"), (403, "owner or editor")] {
            let client = try LogErrorsClient(apiBaseURL: apiBase, userID: "user-1", token: "token") { _ in
                (Data(#"{"error":"denied"}"#.utf8), HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!)
            }
            do {
                _ = try await client.load(filters: LogErrorsFilters())
                XCTFail("Expected HTTP \(status) to be rejected")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(expected))
            }
        }
    }

    func testRejectsRedirectHostMismatchOversizedPayloadAndMalformedRecords() async throws {
        let url = try LogErrorsClient.requestURL(apiBaseURL: apiBase, filters: LogErrorsFilters())
        let oversizedClient = try LogErrorsClient(apiBaseURL: apiBase, userID: "user-1", token: "token") { _ in
            (Data(repeating: 0x20, count: LogErrorsClient.responseBytes + 1), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await assertInvalid(oversizedClient, url: url)

        let foreign = URL(string: "https://evil.example.test/api/logs/errors")!
        let foreignClient = try LogErrorsClient(apiBaseURL: apiBase, userID: "user-1", token: "token") { _ in
            (Data(Self.envelope().utf8), HTTPURLResponse(url: foreign, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await assertInvalid(foreignClient, url: url)

        let malformed = #"{"generated_at":"now","summary":{"total":-1,"last_hour":0,"last_24h":0,"server_errors":0,"client_errors":0,"status_counts":[],"surface_counts":[],"code_counts":[]},"errors":[]}"#.data(using: .utf8)!
        let malformedClient = try LogErrorsClient(apiBaseURL: apiBase, userID: "user-1", token: "token") { _ in
            (malformed, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        await assertInvalid(malformedClient, url: url)
    }

    private func assertInvalid(_ client: LogErrorsClient, url: URL) async {
        do {
            _ = try await client.load(filters: LogErrorsFilters())
            XCTFail("Expected response from \(url) to be rejected")
        } catch {
            XCTAssertEqual(error as? LogErrorsClientError, .invalidResponse)
        }
    }

    private static func envelope() -> String {
        #"{"generated_at":"2026-10-23T15:00:00.000Z","summary":{"total":8,"last_hour":2,"last_24h":5,"server_errors":3,"client_errors":5,"status_counts":[{"status_code":null,"count":1},{"status_code":503,"count":3}],"surface_counts":[{"surface":"website","count":5}],"code_counts":[{"error_code":"http_503","count":3}]},"summary_available":true,"summary_checked_at":"2026-10-23T14:59:59.000Z","warnings":[],"errors":[{"id":"traffic-9","source":"traffic","service":"frontend","surface":"website","method":"GET","path":"/dashboard","status_code":503,"error_code":"http_503","message":"Upstream timeout","request_id":"req-1","user_id":"user-2","level":"error","created_at":"2026-10-23T14:58:00.000Z","metadata":{"route":"dashboard"}}]}"#
    }
}
