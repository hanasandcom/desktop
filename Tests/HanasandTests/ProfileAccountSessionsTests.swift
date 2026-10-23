import Foundation
import XCTest
@testable import Hanasand

final class ProfileAccountSessionsTests: XCTestCase {
    private func response(_ body: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }

    func testLoadUsesAuthenticatedNoStoreOwnAccountRequestAndDecodesDeviceMetadata() async throws {
        var captured: URLRequest?
        let client = try ProfileAccountSessionsClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token_123") { request in
            captured = request
            return self.response(#"{"sessions":[{"token_id":8,"id":"owner","ip":"203.0.113.7","private_ip":null,"current":true,"network":{"provider":"Example ISP","country":"Norway","country_code":"NO","region":"Oslo","city":"Oslo"},"user_agent":"Hanasand Desktop/1.0","created_at":"2026-10-20T10:00:00Z","last_seen_at":"2026-10-23T10:00:00Z","revoked_at":null,"ignored":"value"}]}"#, request: request)
        }

        let sessions = try await client.load()
        XCTAssertEqual(sessions.count, 1)
        XCTAssertTrue(sessions[0].current)
        XCTAssertEqual(sessions[0].deviceLabel, "Hanasand desktop app")
        XCTAssertEqual(sessions[0].addressLabel, "Public IP 203.0.113.7")
        XCTAssertEqual(sessions[0].locationLabel, "Oslo, Norway")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/auth/sessions")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token_123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
    }

    func testSessionSearchMatchesEveryTermAcrossDeviceNetworkStatusAndAddress() {
        let session = makeSession(current: false, revokedAt: nil)
        XCTAssertTrue(session.matches(search: ["chrome", "windows", "203.0.113.7"]))
        XCTAssertTrue(session.matches(search: ["example isp", "active"]))
        XCTAssertFalse(session.matches(search: ["chrome", "revoked"]))
        XCTAssertTrue(session.matches(search: []))
    }

    func testRevokeUsesSpecificSessionDeleteAndBlocksCurrentSession() async throws {
        var captured: URLRequest?
        let client = try makeClient { request in
            captured = request
            return self.response("{}", request: request)
        }
        try await client.revoke(makeSession(current: false, revokedAt: nil))
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/auth/sessions/42")
        XCTAssertEqual(captured?.httpMethod, "DELETE")

        do {
            try await client.revoke(makeSession(current: true, revokedAt: nil))
            XCTFail("Expected current session to require the logout flow")
        } catch ProfileAccountSessionsClientError.currentSessionRequiresLogout {}
    }

    func testRevokeOthersKeepsCurrentSession() async throws {
        var captured: URLRequest?
        let client = try makeClient { request in
            captured = request
            return self.response("{}", request: request)
        }
        try await client.revokeOthers()
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/auth/sessions/revoke")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(try JSONSerialization.jsonObject(with: captured?.httpBody ?? Data()) as? [String: Bool], ["keep_current": true])
    }

    func testClientRejectsImpersonationInvalidCredentialsAndServerErrors() async throws {
        XCTAssertThrowsError(try ProfileAccountSessionsClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "admin", token: "token", impersonationToken: "view")) { error in
            XCTAssertEqual(error as? ProfileAccountSessionsClientError, .impersonationUnsupported)
        }
        XCTAssertThrowsError(try ProfileAccountSessionsClient(baseURL: URL(string: "http://api.hanasand.test/api")!, userID: "owner", token: "token"))
        XCTAssertThrowsError(try ProfileAccountSessionsClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "bad token"))

        let denied = try makeClient { request in self.response(#"{"error":"forbidden"}"#, request: request, status: 403) }
        do { _ = try await denied.load(); XCTFail("Expected HTTP error") }
        catch ProfileAccountSessionsClientError.requestFailed(403) {}
    }

    private func makeClient(send: @escaping (URLRequest) async throws -> (Data, URLResponse)) throws -> ProfileAccountSessionsClient {
        try ProfileAccountSessionsClient(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", token: "token", send: send)
    }

    private func makeSession(current: Bool, revokedAt: String?) -> ProfileAccountSession {
        let data = Data(#"{"token_id":42,"ip":"203.0.113.7","private_ip":null,"current":\#(current),"network":{"provider":"Example ISP","country":"Norway","region":"Oslo","city":"Oslo"},"user_agent":"Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/130.0 Safari/537.36","created_at":"2026-10-20T10:00:00Z","last_seen_at":"2026-10-23T10:00:00Z","revoked_at":\#(revokedAt.map { "\"\($0)\"" } ?? "null")}"#.utf8)
        return try! JSONDecoder().decode(ProfileAccountSession.self, from: data)
    }
}
