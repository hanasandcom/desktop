import Foundation
import XCTest
@testable import Hanasand

final class SocialConnectionsClientTests: XCTestCase {
    private var settings: HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.apiBaseURL = "https://api.example.test/api"
        value.userID = "owner.test"
        value.authToken = "session-token_123"
        return value
    }

    func testLoadsReadOnlyConnectionsUsingBearerSessionWithoutCookies() async throws {
        var captured: URLRequest?
        let client = try SocialConnectionsClient(settings: settings) { request in
            captured = request
            return self.response(#"{"connections":[{"provider":"google","email":"person@example.test","created_at":"2026-10-01T00:00:00.000Z"}]}"#, for: request)
        }

        let connections = try await client.load()

        XCTAssertEqual(client.endpoint.absoluteString, "https://api.example.test/api/auth/social/connections")
        XCTAssertEqual(connections, [SocialConnection(provider: "google", email: "person@example.test")])
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer session-token_123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner.test")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
        XCTAssertNil(captured?.httpBody)
    }

    func testProductionAPIUsesIdentityHostForConnectionsRead() async throws {
        var configured = settings
        configured.apiBaseURL = "https://api.hanasand.com/api"
        let client = try SocialConnectionsClient(settings: configured) { request in
            self.response(#"{"connections":[]}"#, for: request)
        }

        XCTAssertEqual(client.endpoint.absoluteString, "https://identity.hanasand.com/api/auth/social/connections")
        let connections = try await client.load()
        XCTAssertEqual(connections, [])
    }

    func testEmptyAndAppleOnlyConnectionsDoNotManufactureGoogleConnection() async throws {
        let appleOnly = try SocialConnectionsClient(settings: settings) { request in
            self.response(#"{"connections":[{"provider":"apple","email":null,"created_at":"2026-10-01T00:00:00.000Z"}]}"#, for: request)
        }
        let appleConnections = try await appleOnly.load()
        XCTAssertNil(appleConnections.first { $0.provider == "google" })

        let empty = try SocialConnectionsClient(settings: settings) { request in
            self.response(#"{"connections":[]}"#, for: request)
        }
        let emptyConnections = try await empty.load()
        XCTAssertTrue(emptyConnections.isEmpty)
    }

    func testRejectsMalformedProviderAndDuplicateProviderRows() async throws {
        let malformed = try SocialConnectionsClient(settings: settings) { request in
            self.response(#"{"connections":[{"provider":"unknown","email":null}]}"#, for: request)
        }
        do { _ = try await malformed.load(); XCTFail("Expected malformed provider rejection") }
        catch let error as SocialConnectionsClientError { XCTAssertEqual(error, .invalidResponse) }

        let duplicate = try SocialConnectionsClient(settings: settings) { request in
            self.response(#"{"connections":[{"provider":"google","email":null},{"provider":"google","email":"person@example.test"}]}"#, for: request)
        }
        do { _ = try await duplicate.load(); XCTFail("Expected duplicate provider rejection") }
        catch let error as SocialConnectionsClientError { XCTAssertEqual(error, .invalidResponse) }
    }

    func testRejectsInsecureEndpointsAndImpersonatedScopeBeforeRequest() throws {
        var insecure = settings
        insecure.apiBaseURL = "http://api.example.test/api"
        XCTAssertThrowsError(try SocialConnectionsClient(settings: insecure)) {
            XCTAssertEqual($0 as? SocialConnectionsClientError, .invalidEndpoint)
        }

        var impersonated = settings
        impersonated.impersonationToken = "delegated-session"
        XCTAssertThrowsError(try SocialConnectionsClient(settings: impersonated)) {
            XCTAssertEqual($0 as? SocialConnectionsClientError, .ownAccountRequired)
        }

        var impersonatedUser = settings
        impersonatedUser.impersonatingUserID = "another-user"
        XCTAssertThrowsError(try SocialConnectionsClient(settings: impersonatedUser)) {
            XCTAssertEqual($0 as? SocialConnectionsClientError, .ownAccountRequired)
        }
    }

    func testRejectsUnexpectedResponseOriginAndNonSuccessStatus() async throws {
        let client = try SocialConnectionsClient(settings: settings) { request in
            let foreign = HTTPURLResponse(url: URL(string: "https://attacker.example/api/auth/social/connections")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"connections":[]}"#.utf8), foreign)
        }
        do { _ = try await client.load(); XCTFail("Expected response-origin rejection") }
        catch let error as SocialConnectionsClientError { XCTAssertEqual(error, .invalidResponse) }

        let unauthorized = try SocialConnectionsClient(settings: settings) { request in
            (Data(#"{"error":"Sign in first."}"#.utf8), self.httpResponse(for: request, status: 401))
        }
        do { _ = try await unauthorized.load(); XCTFail("Expected authentication failure") }
        catch let error as SocialConnectionsClientError { XCTAssertEqual(error, .requestFailed(401)) }
    }

    private func response(_ json: String, for request: URLRequest) -> (Data, URLResponse) {
        (Data(json.utf8), httpResponse(for: request, status: 200))
    }

    private func httpResponse(for request: URLRequest, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}
