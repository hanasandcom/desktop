import Foundation
import XCTest

@testable import Hanasand

final class SandboxHistoryTests: XCTestCase {
    private let api = URL(string: "https://api.example.test/api")!

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
        XCTAssertEqual(page.nextOffset, 50)
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

    private func makeClient(send: @escaping SandboxHistoryClient.Sender) throws -> SandboxHistoryClient {
        try SandboxHistoryClient(apiBaseURL: api, userID: "owner.test", token: "session-token", send: send)
    }

    private static func response(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }

    private static let pageJSON = #"{"runs":[{"id":"run-1","resultId":"result-1","target":"https://example.test","network":"residential","status":"complete","startedAt":"2026-10-22T10:00:00Z","providerResults":[{"large":"ignored"}]}],"nextOffset":50}"#
}
