import Foundation
import XCTest

@testable import Hanasand

final class SandboxHistoryTests: XCTestCase {
    private let api = URL(string: "https://api.example.test/api")!

    func testDefaultHistoryAndReportClientsUseBrowserServiceAPI() {
        XCTAssertEqual(SandboxHistoryClient.defaultAPIBaseURL.absoluteString, "https://browsers.hanasand.com/api")
        XCTAssertEqual(SandboxHistoryReportClient.defaultAPIBaseURL.absoluteString, "https://browsers.hanasand.com/api")
    }

    func testLoadsOwnerHistoryWithNarrowAuthenticatedRequest() async throws {
        var captured: URLRequest?
        let client = try makeClient { request in
            captured = request
            return (Data(Self.pageJSON.utf8), Self.response(for: request, status: 200))
        }

        let page = try await client.loadPage()

        XCTAssertEqual(captured?.url?.absoluteString, "https://api.example.test/api/browser/runs?history=all&offset=0")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner.test")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(captured?.httpBody)
        XCTAssertFalse(captured?.url?.absoluteString.contains("clientId") ?? true)
        XCTAssertEqual(page.runs.count, 1)
        XCTAssertEqual(page.runs[0].target, "https://example.test")
        XCTAssertEqual(page.runs[0].network, "residential")
        XCTAssertEqual(page.runs[0].providerResults, [
            SandboxHistoryProviderResult(id: "urlquery", status: "suspicious", label: "3 alerts"),
            SandboxHistoryProviderResult(id: "virustotal", status: "clean", label: "0 detections"),
        ])
        XCTAssertEqual(page.nextOffset, 50)
    }

    func testLoadsOwnerQuotaWithAuthenticatedRegularRunsRequest() async throws {
        var captured: URLRequest?
        let client = try makeClient { request in
            captured = request
            let body = #"{"runs":[],"quota":{"plan":"free","limit":null,"used":12,"remaining":null,"active":1,"paid":false,"advancedAnalysis":false,"sessionSeconds":90,"concurrentLimit":2,"identityKind":"user"}}"#
            return (Data(body.utf8), Self.response(for: request, status: 200))
        }

        let quota = try await client.loadQuota()

        XCTAssertEqual(captured?.url?.absoluteString, "https://api.example.test/api/browser/runs")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner.test")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertNil(captured?.httpBody)
        XCTAssertEqual(quota, SandboxHistoryQuota(plan: "free", limit: nil, used: 12, active: 1, paid: false,
                                                   advancedAnalysis: false, sessionSeconds: 90, concurrentLimit: 2))
        XCTAssertEqual(quota.summary, "1 min 30 sec per run · 2 simultaneous browsers · no daily run limit")
    }

    func testDeleteRunUsesScopedOwnerRequestAndRequiresDeletionReceipt() async throws {
        var captured: URLRequest?
        let client = try makeClient { request in
            captured = request
            return (Data(#"{"deleted":2}"#.utf8), Self.response(for: request, status: 200))
        }

        try await client.deleteRun(id: "run-1")

        XCTAssertEqual(captured?.url?.absoluteString, "https://api.example.test/api/browser/runs")
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner.test")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        let body = try XCTUnwrap(captured?.httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: [String]])
        XCTAssertEqual(payload, ["ids": ["run-1"]])
    }

    func testDeleteRunKeepsFailureWhenServiceRejectsOrReturnsNoDeletion() async throws {
        let rejected = try makeClient { request in
            (Data(#"{"error":"try later"}"#.utf8), Self.response(for: request, status: 503))
        }
        do {
            try await rejected.deleteRun(id: "run-1")
            XCTFail("Service failures must keep the run available for retry")
        } catch { XCTAssertEqual(error as? SandboxHistoryError, .requestFailed(503)) }

        let stale = try makeClient { request in
            (Data(#"{"deleted":0}"#.utf8), Self.response(for: request, status: 200))
        }
        do {
            try await stale.deleteRun(id: "run-1")
            XCTFail("A zero deletion receipt must not be treated as success")
        } catch { XCTAssertEqual(error as? SandboxHistoryError, .runNotFound) }
    }

    func testRejectsMalformedQuotaAndBadQuotaTypes() async throws {
        for body in [
            #"{"runs":[]}"#,
            #"{"quota":{"plan":"free","limit":null,"used":true,"remaining":null,"active":0,"paid":false,"advancedAnalysis":false,"sessionSeconds":90,"concurrentLimit":null}}"#,
            #"{"quota":{"plan":"free","limit":null,"used":1.5,"remaining":null,"active":0,"paid":false,"advancedAnalysis":false,"sessionSeconds":90,"concurrentLimit":null}}"#,
        ] {
            let client = try makeClient { request in
                (Data(body.utf8), Self.response(for: request, status: 200))
            }
            do {
                _ = try await client.loadQuota()
                XCTFail("Malformed quota payloads must be rejected")
            } catch { XCTAssertEqual(error as? SandboxHistoryError, .invalidResponse) }
        }
    }

    func testPaginationUsesInjectedBaseAndSkipsMalformedOrDuplicateRows() async throws {
        var captured: URLRequest?
        let body = #"{"runs":[{"id":"run-2","resultId":"result-2","target":"https://two.test","network":"direct","status":"complete","startedAt":"2026-10-22T10:00:00Z","providerResults":{"secret":"ignored"}},{"id":"bad id","resultId":"x","target":"x","network":"n","status":"s","startedAt":"t"},{"id":"run-2","resultId":"result-2","target":"duplicate","network":"n","status":"s","startedAt":"t"},null],"nextOffset":null}"#
        let client = try makeClient { request in
            captured = request
            return (Data(body.utf8), Self.response(for: request, status: 200))
        }

        let page = try await client.loadPage(offset: 50)

        XCTAssertEqual(captured?.url?.absoluteString, "https://api.example.test/api/browser/runs?history=all&offset=50")
        XCTAssertEqual(page.runs.map(\.id), ["run-2"])
        XCTAssertNil(page.nextOffset)
    }

    func testHandlesEmptyHistoryAndRejectsMalformedPageMetadata() async throws {
        let empty = try makeClient { request in
            (Data(#"{"runs":[],"nextOffset":null}"#.utf8), Self.response(for: request, status: 200))
        }
        let page = try await empty.loadPage()
        XCTAssertTrue(page.runs.isEmpty)
        XCTAssertNil(page.nextOffset)

        let invalid = try makeClient { request in
            (Data(#"{"runs":[],"nextOffset":0}"#.utf8), Self.response(for: request, status: 200))
        }
        do {
            _ = try await invalid.loadPage()
            XCTFail("Non-advancing pagination must be rejected")
        } catch { XCTAssertEqual(error as? SandboxHistoryError, .invalidResponse) }
    }

    func testRejectsOversizedResponseAndWrongPageShape() async throws {
        let oversized = try makeClient { request in
            (Data(repeating: 0x20, count: SandboxHistoryLimits.responseBytes + 1), Self.response(for: request, status: 200))
        }
        do {
            _ = try await oversized.loadPage()
            XCTFail("Oversized response must be rejected")
        } catch { XCTAssertEqual(error as? SandboxHistoryError, .responseTooLarge) }

        let wrongShape = try makeClient { request in
            (Data(#"{"runs":[{}, {}, {}, {}]}"#.utf8), Self.response(for: request, status: 200))
        }
        let page = try await wrongShape.loadPage()
        XCTAssertTrue(page.runs.isEmpty)
    }

    func testRejectsImpersonationInsecureEndpointAndInvalidOffset() async throws {
        XCTAssertThrowsError(try SandboxHistoryClient(apiBaseURL: api, userID: "owner.test", token: "token", impersonationToken: "proxy")) {
            XCTAssertEqual($0 as? SandboxHistoryError, .ownAccountRequired)
        }
        XCTAssertThrowsError(try SandboxHistoryClient(apiBaseURL: URL(string: "http://api.example.test/api")!, userID: "owner.test", token: "token")) {
            XCTAssertEqual($0 as? SandboxHistoryError, .invalidBaseURL)
        }
        let client = try makeClient { request in (Data(#"{"runs":[],"nextOffset":null}"#.utf8), Self.response(for: request, status: 200)) }
        do {
            _ = try await client.loadPage(offset: 25)
            XCTFail("Offsets must align to the API page size")
        } catch { XCTAssertEqual(error as? SandboxHistoryError, .invalidOffset) }
    }

    func testLoadsOwnerReportWithBoundedSameOriginAuthenticatedRequest() async throws {
        var captured: URLRequest?
        let client = try makeReportClient { request in
            captured = request
            let body = #"{"target":"https://sample.test","captures":[{"type":"page","title":"Landing","url":"https://sample.test/","text":"Rendered content"}],"evidenceEvents":[{"type":"request","url":"https://sample.test/api","message":"GET"}]}"#
            return (Data(body.utf8), Self.response(for: request, status: 200))
        }
        let report = try await client.loadReport(resultID: "result-1")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.example.test/api/browser/results/result-1")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner.test")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(report.entries.count, 2)
        XCTAssertEqual(report.entries[0].title, "Landing")
        XCTAssertEqual(report.entries[0].detail, "Rendered content")
    }

    func testRejectsOversizedOrCrossOriginReportResponse() async throws {
        let oversized = try makeReportClient { request in
            (Data(repeating: 0x20, count: SandboxHistoryLimits.reportResponseBytes + 1), Self.response(for: request, status: 200))
        }
        do {
            _ = try await oversized.loadReport(resultID: "result-1")
            XCTFail("Oversized reports must be rejected")
        } catch { XCTAssertEqual(error as? SandboxHistoryError, .responseTooLarge) }

        let crossOrigin = try makeReportClient { request in
            let response = HTTPURLResponse(url: URL(string: "https://elsewhere.example/result")!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (Data(#"{"target":"https://sample.test","captures":[],"evidenceEvents":[]}"#.utf8), response)
        }
        do {
            _ = try await crossOrigin.loadReport(resultID: "result-1")
            XCTFail("Cross-origin report responses must be rejected")
        } catch { XCTAssertEqual(error as? SandboxHistoryError, .invalidResponse) }
    }

    func testReportClientRejectsImpersonatedAccounts() {
        XCTAssertThrowsError(try SandboxHistoryReportClient(apiBaseURL: api, userID: "owner.test", token: "session-token", impersonationToken: "proxy")) {
            XCTAssertEqual($0 as? SandboxHistoryError, .ownAccountRequired)
        }
        XCTAssertThrowsError(try SandboxHistoryReportClient(apiBaseURL: api, userID: "owner.test", token: "session-token", impersonatingUserID: "other-user")) {
            XCTAssertEqual($0 as? SandboxHistoryError, .ownAccountRequired)
        }
    }

    private func makeReportClient(send: @escaping SandboxHistoryReportClient.Sender) throws -> SandboxHistoryReportClient {
        try SandboxHistoryReportClient(apiBaseURL: api, userID: "owner.test", token: "session-token", send: send)
    }

    private func makeClient(send: @escaping SandboxHistoryClient.Sender) throws -> SandboxHistoryClient {
        try SandboxHistoryClient(apiBaseURL: api, userID: "owner.test", token: "session-token", send: send)
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }

    private static let pageJSON = #"{"runs":[{"id":"run-1","resultId":"result-1","target":"https://example.test","network":"residential","status":"complete","startedAt":"2026-10-22T10:00:00Z","providerResults":{"virustotal":{"status":"clean","label":"0 detections"},"urlquery":{"status":"suspicious","label":"3 alerts"},"bad key":{"status":"clean","label":"ignored"},"unknown":{"status":"other","label":"ignored"}}}],"nextOffset":50}"#
}
