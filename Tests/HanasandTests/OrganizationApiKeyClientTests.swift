import Foundation
import XCTest
@testable import Hanasand

final class OrganizationApiKeyClientTests: XCTestCase {
    private var settings: HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.apiBaseURL = "https://api.hanasand.test/api"
        value.userID = "owner"
        value.authToken = "token_abc-123"
        value.selectedOrganizationID = "org/a"
        value.selectedOrganizationUserID = "owner"
        return value
    }

    private func http(_ json: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(json.utf8), response)
    }

    private let listedKey = #"{"id":"key-1","organizationId":"org/a","name":"Production","enabled":true,"keyPrefix":"012345abcdef","expiresAt":"2027-01-21T00:00:00.000Z","lastUsedAt":null,"createdAt":"2026-10-23T00:00:00.000Z","scopes":[{"method":"POST","route":"/mill","enabled":true}]}"#

    func testListUsesOrganizationScopedNoStoreAuthenticatedRoute() async throws {
        var captured: URLRequest?
        let client = try OrganizationApiKeyClient(settings: settings, organizationID: "org/a") { request in
            captured = request
            return self.http("{\"organizationId\":\"org/a\",\"apiKeys\":[" + self.listedKey + "]}", request: request)
        }

        let keys = try await client.list()
        XCTAssertEqual(keys.map(\.id), ["key-1"])
        XCTAssertEqual(keys[0].organizationId, "org/a")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/organizations/org%2Fa/api-keys")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(captured?.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
    }

    func testCreateRechecksMembershipBeforePostingNameOnlyAndReturnsOneTimeSecret() async throws {
        var requests: [URLRequest] = []
        let client = try OrganizationApiKeyClient(settings: settings, organizationID: "org/a") { request in
            requests.append(request)
            if request.httpMethod == "GET" {
                return self.http(#"{"organizationId":"org/a","apiKeys":[]}"#, request: request)
            }
            return self.http(#"{"apiKey":{"id":"key-2","organizationId":"org/a","name":"New integration","enabled":true,"keyPrefix":"abcdef012345","expiresAt":"2027-01-21T00:00:00.000Z","lastUsedAt":null,"createdAt":"2026-10-23T00:00:00.000Z","scopes":[{"method":"POST","route":"/mill","enabled":true}]},"secret":"hsk_abcdef012345_0123456789abcdef0123456789abcdef0123456789abcdef"}"#, request: request, status: 201)
        }

        let result = try await client.create(name: "  New integration  ")
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        XCTAssertEqual(requests[1].url?.absoluteString, "https://api.hanasand.test/api/organizations/org%2Fa/api-keys")
        XCTAssertEqual(String(data: requests[1].httpBody ?? Data(), encoding: .utf8), #"{"name":"New integration"}"#)
        XCTAssertEqual(result.apiKey.id, "key-2")
        XCTAssertEqual(result.secret, "hsk_abcdef012345_0123456789abcdef0123456789abcdef0123456789abcdef")
        XCTAssertFalse(String(data: requests[1].httpBody ?? Data(), encoding: .utf8)!.contains(result.secret))
    }

    func testCreateRejectsInvalidNamesBeforeNetwork() async throws {
        var sent = false
        let client = try OrganizationApiKeyClient(settings: settings, organizationID: "org/a") { request in
            sent = true
            return self.http("{}", request: request)
        }
        do {
            _ = try await client.create(name: "x")
            XCTFail("Expected short API key names to be rejected")
        } catch OrganizationApiKeyError.invalidName {}
        XCTAssertFalse(sent)
    }

    func testRevokeRefreshesMembershipAndTargetsOnlyTheSelectedOrganizationsActiveKey() async throws {
        var requests: [URLRequest] = []
        let client = try OrganizationApiKeyClient(settings: settings, organizationID: "org/a") { request in
            requests.append(request)
            if request.httpMethod == "GET" {
                return self.http("{\"organizationId\":\"org/a\",\"apiKeys\":[" + self.listedKey + "]}", request: request)
            }
            return self.http(#"{"apiKey":{"id":"key-1","organizationId":"org/a","name":"Production","enabled":false,"keyPrefix":"012345abcdef","expiresAt":"2027-01-21T00:00:00.000Z","lastUsedAt":null,"createdAt":"2026-10-23T00:00:00.000Z","scopes":[]}}"#, request: request)
        }

        let key = try JSONDecoder().decode(OrganizationApiKey.self, from: Data(listedKey.utf8))
        let revoked = try await client.revoke(key)
        XCTAssertFalse(revoked.enabled)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "DELETE"])
        XCTAssertEqual(requests[1].url?.absoluteString, "https://api.hanasand.test/api/organizations/org%2Fa/api-keys/key-1")
    }

    func testClientRequiresOwnerBoundOrganizationAndRejectsImpersonation() throws {
        XCTAssertThrowsError(try OrganizationApiKeyClient(settings: settings, organizationID: "org-b"))
        var anotherAccountSelected = settings
        anotherAccountSelected.selectedOrganizationUserID = "someone-else"
        XCTAssertThrowsError(try OrganizationApiKeyClient(settings: anotherAccountSelected, organizationID: "org/a"))
        var impersonating = settings
        impersonating.impersonationToken = "impersonation-token"
        XCTAssertThrowsError(try OrganizationApiKeyClient(settings: impersonating, organizationID: "org/a"))
        XCTAssertTrue(OrganizationApiKeyPermission.canManage(role: "admin", isOwnAccount: true, isImpersonating: false))
        XCTAssertFalse(OrganizationApiKeyPermission.canManage(role: "editor", isOwnAccount: true, isImpersonating: false))
        XCTAssertFalse(OrganizationApiKeyPermission.canManage(role: "owner", isOwnAccount: true, isImpersonating: true))
    }

    func testListRejectsCrossOrganizationResponse() async throws {
        let client = try OrganizationApiKeyClient(settings: settings, organizationID: "org/a") { request in
            self.http(#"{"organizationId":"other-org","apiKeys":[]}"#, request: request)
        }
        do {
            _ = try await client.list()
            XCTFail("Expected response scope mismatch")
        } catch OrganizationApiKeyError.organizationScopeChanged {}
    }
}
