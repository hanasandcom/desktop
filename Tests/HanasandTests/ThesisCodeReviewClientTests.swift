import Foundation
import XCTest
@testable import Hanasand

final class ThesisCodeReviewClientTests: XCTestCase {
    private let contentSHA = String(repeating: "a", count: 64)
    private let reviewHash = String(repeating: "b", count: 64)
    private let eventID = "4f2c5f7a-3d29-4a9a-8c63-2c29d08a2d61"

    private func settings(impersonating: Bool = false, website: String = "https://hanasand.test") -> HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.websiteBaseURL = website
        value.userID = "owner"
        value.authToken = "token"
        if impersonating { value.impersonationToken = "impersonation" }
        return value
    }

    private func response(_ body: String, request: URLRequest, status: Int = 200, url: URL? = nil) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    private var inventoryJSON: String {
        #"{"version":1,"hash":"inventory-1","release":"release-1","revision":"rev-1","nodes":[{"id":"src:app.ts","kind":"frontend","title":"App","file":"src/app.ts","line":2,"sha256":"\#(contentSHA)","reviewHash":"\#(reviewHash)","dependencies":["src:lib.ts"],"dependencyCount":1,"unresolved":["external:thing"]}]}"#
    }

    private var sourceJSON: String {
        #"{"item":{"id":"src:app.ts","kind":"frontend","title":"App","file":"src/app.ts","line":2,"sha256":"\#(contentSHA)","reviewHash":"\#(reviewHash)","dependencies":["src:lib.ts"],"dependencyCount":1,"unresolved":[],"content":"const app = true;"},"history":[]}"#
    }

    func testInventoryAndSourceUseWebsiteJSONRouteAndBearerIdentity() async throws {
        var requests: [URLRequest] = []
        let client = try ThesisCodeReviewClient(settings: settings()) { request in
            requests.append(request)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "owner")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
            XCTAssertFalse(request.httpShouldHandleCookies)
            return self.response(request.url?.query == nil ? self.inventoryJSON : self.sourceJSON, request: request)
        }

        let loaded = try await client.inventory()
        let inventory = try XCTUnwrap(loaded)
        XCTAssertEqual(inventory.cursor, "inventory-1:rev-1")
        XCTAssertEqual(inventory.nodes.first?.reviewStatus, "unreviewed")
        let source = try await client.source(id: "src:app.ts")
        XCTAssertEqual(source.item.content, "const app = true;")
        XCTAssertEqual(requests.map { $0.url!.path }, ["/api/thesis/code", "/api/thesis/code"])
        XCTAssertEqual(URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "src:app.ts")
    }

    func testConditionalInventoryRefreshAcceptsNoContent() async throws {
        let client = try ThesisCodeReviewClient(settings: settings()) { request in
            XCTAssertEqual(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "inventory-1:rev-1")
            return self.response("", request: request, status: 204)
        }
        let unchanged = try await client.inventory(since: "inventory-1:rev-1")
        XCTAssertNil(unchanged)
    }

    func testReviewPostsToWebsiteWithSameOriginAndValidatesReceipt() async throws {
        let node = try JSONDecoder().decode(ThesisCodeInventory.self, from: Data(inventoryJSON.utf8)).validated().nodes[0]
        let client = try ThesisCodeReviewClient(settings: settings()) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/api/thesis/code")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Origin"), "https://hanasand.test")
            let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: Any])
            XCTAssertEqual(body["id"] as? String, node.id)
            XCTAssertEqual(body["sha256"] as? String, node.sha256)
            XCTAssertEqual(body["reviewHash"] as? String, node.reviewHash)
            XCTAssertEqual(body["eventId"] as? String, self.eventID)
            XCTAssertEqual(body["approved"] as? Bool, true)
            return self.response(#"{"event_id":"4f2c5f7a-3d29-4a9a-8c63-2c29d08a2d61","item_id":"src:app.ts","content_hash":"\#(self.contentSHA)","review_hash":"\#(self.reviewHash)","approved":true,"reviewer":"owner","reviewed_at":"2026-10-25T10:00:00.123Z"}"#, request: request)
        }
        let receipt = try await client.review(node, approved: true, eventID: eventID, canReview: true)
        XCTAssertEqual(receipt.eventID, eventID)
    }

    func testReviewFailsClosedForReadOnlyOrImpersonatedAccounts() async throws {
        let node = try JSONDecoder().decode(ThesisCodeInventory.self, from: Data(inventoryJSON.utf8)).validated().nodes[0]
        let readOnly = try ThesisCodeReviewClient(settings: settings()) { _ in XCTFail("Read-only account must not send review"); throw ThesisCodeReviewError.readOnly }
        do { _ = try await readOnly.review(node, approved: true, eventID: eventID, canReview: false); XCTFail("Expected owner/editor guard") }
        catch ThesisCodeReviewError.readOnly {}
        let impersonated = try ThesisCodeReviewClient(settings: settings(impersonating: true)) { _ in XCTFail("Impersonated account must not send review"); throw ThesisCodeReviewError.readOnly }
        do { _ = try await impersonated.review(node, approved: true, eventID: eventID, canReview: true); XCTFail("Expected impersonation guard") }
        catch ThesisCodeReviewError.readOnly {}
    }

    func testRejectsAResponseFromOutsideTheConfiguredWebsiteOrigin() async throws {
        let client = try ThesisCodeReviewClient(settings: settings()) { request in
            self.response(self.inventoryJSON, request: request, url: URL(string: "https://attacker.test/api/thesis/code")!)
        }
        do { _ = try await client.inventory(); XCTFail("Expected same-host response guard") }
        catch ThesisCodeReviewError.invalidEndpoint {}
    }

    func testRejectsInvalidEndpointOversizedResponseAndMalformedInventory() async throws {
        XCTAssertThrowsError(try ThesisCodeReviewClient.endpoint(websiteBaseURL: "http://hanasand.test")) {
            XCTAssertEqual($0 as? ThesisCodeReviewError, .invalidEndpoint)
        }
        XCTAssertThrowsError(try ThesisCodeReviewClient.endpoint(websiteBaseURL: "https://user@hanasand.test")) {
            XCTAssertEqual($0 as? ThesisCodeReviewError, .invalidEndpoint)
        }
        let oversized = try ThesisCodeReviewClient(settings: settings()) { request in
            (Data(repeating: 32, count: ThesisCodeReviewClient.responseLimit + 1), self.response("{}", request: request).1)
        }
        do { _ = try await oversized.inventory(); XCTFail("Expected response limit") }
        catch ThesisCodeReviewError.responseTooLarge {}

        let duplicate = #"{"version":1,"hash":"x","release":"r","nodes":[{"id":"same","kind":"frontend","title":"A","file":"a","sha256":"\#(contentSHA)","reviewHash":"\#(reviewHash)","dependencies":[],"dependencyCount":0,"unresolved":[]},{"id":"same","kind":"frontend","title":"B","file":"b","sha256":"\#(contentSHA)","reviewHash":"\#(reviewHash)","dependencies":[],"dependencyCount":0,"unresolved":[]}]}"#
        XCTAssertThrowsError(try JSONDecoder().decode(ThesisCodeInventory.self, from: Data(duplicate.utf8)).validated()) {
            XCTAssertEqual($0 as? ThesisCodeReviewError, .invalidResponse)
        }
    }
}
