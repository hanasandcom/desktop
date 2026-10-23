import Foundation
import XCTest
@testable import Hanasand

final class AccountActivityTests: XCTestCase {
    private func response(_ body: Data, for request: URLRequest, status: Int = 200, url: URL? = nil) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: url ?? request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (body, response)
    }

    func testLoadUsesOwnerScopedAuthenticatedNoStoreEndpointAndDecodesSummary() async throws {
        var captured: URLRequest?
        let client = try AccountActivityClient(apiBaseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token_abc-123") { request in
            captured = request
            return self.response(Data(#"{"loginDays":[{"day":"2026-10-22","logins":2,"ip":"must-not-decode"},{"day":"2026-10-20","logins":1}],"counts":{"organizations":"must-not-decode"},"token":"ignored"}"#.utf8), for: request)
        }

        let stats = try await client.load()
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/user/owner/profile-stats")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
        XCTAssertNil(captured?.httpBody)
        XCTAssertEqual(stats.loginDays.map(\.day), ["2026-10-20", "2026-10-22"])
        XCTAssertEqual(stats.loginDays.map(\.logins), [1, 2])
    }

    func testClientRejectsImpersonationAndUnsafeCredentialsBeforeSending() throws {
        XCTAssertThrowsError(try AccountActivityClient(apiBaseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token", impersonationToken: "scope")) { error in
            XCTAssertEqual(error as? AccountActivityClientError, .impersonationUnsupported)
        }
        XCTAssertThrowsError(try AccountActivityClient(apiBaseURL: URL(string: "http://api.hanasand.test/api")!, userID: "owner", token: "token"))
        XCTAssertThrowsError(try AccountActivityClient(apiBaseURL: URL(string: "https://user@api.hanasand.test/api")!, userID: "owner", token: "token"))
        XCTAssertThrowsError(try AccountActivityClient(apiBaseURL: URL(string: "https://api.hanasand.test/api")!, userID: "../other", token: "token"))
        XCTAssertThrowsError(try AccountActivityClient(apiBaseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: ""))
    }

    func testLoadRejectsAuthorizationErrorsMalformedPayloadAndForeignOrigin() async throws {
        let denied = try AccountActivityClient(apiBaseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token") { request in
            self.response(Data(#"{"error":"forbidden"}"#.utf8), for: request, status: 403)
        }
        do { _ = try await denied.load(); XCTFail("Expected owner-scope rejection") }
        catch AccountActivityClientError.requestFailed(403) {}

        let malformed = try AccountActivityClient(apiBaseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token") { request in
            self.response(Data(#"{"loginDays":[{"day":"2026-02-30","logins":1}],"counts":{"organizations":0,"containers":0,"vms":0,"shares":0,"articles":0}}"#.utf8), for: request)
        }
        do { _ = try await malformed.load(); XCTFail("Expected invalid dates to be rejected") }
        catch AccountActivityClientError.invalidResponse {}

        let foreign = try AccountActivityClient(apiBaseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token") { request in
            self.response(Data(#"{"loginDays":[],"counts":{"organizations":0,"containers":0,"vms":0,"shares":0,"articles":0}}"#.utf8), for: request, url: URL(string: "https://attacker.test/profile-stats")!)
        }
        do { _ = try await foreign.load(); XCTFail("Expected cross-origin response to be rejected") }
        catch AccountActivityClientError.invalidResponse {}
    }

    func testLoadRejectsOversizedAndUnboundedActivity() async throws {
        let oversized = try AccountActivityClient(apiBaseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token") { request in
            self.response(Data(repeating: 0x20, count: AccountActivityClient.responseByteLimit + 1), for: request)
        }
        do { _ = try await oversized.load(); XCTFail("Expected oversized payload to be rejected") }
        catch AccountActivityClientError.invalidResponse {}

        let excessiveDays = String(repeating: #"{"day":"2026-10-22","logins":1},"#, count: 4_001)
        let body = Data((#"{"loginDays":["# + excessiveDays + #"{"day":"2026-10-23","logins":1}],"counts":{"organizations":0,"containers":0,"vms":0,"shares":0,"articles":0}}"#).utf8)
        let unbounded = try AccountActivityClient(apiBaseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token") { request in
            self.response(body, for: request)
        }
        do { _ = try await unbounded.load(); XCTFail("Expected excessive activity rows to be rejected") }
        catch AccountActivityClientError.invalidResponse {}
    }
}
