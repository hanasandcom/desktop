import Foundation
import XCTest
@testable import Hanasand

final class IntegrationClientTests: XCTestCase {
    private let base = URL(string: "https://api.hanasand.test/api")!

    private func response(_ body: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    private let listing = #"{"destinations":[{"id":"dest_1","orgId":"owner","name":"Ops","kind":"discord","status":"active","endpointHint":"discord.com/...","lastTestedAt":null}],"destinationLifecycle":[{"destinationId":"dest_1","access":{"canManage":true,"canUpdate":true,"canDisable":true,"canTest":true}}],"destinationTests":[{"destinationId":"dest_1","access":{"canTest":true},"blockers":[]}],"destinationAdminProof":{"access":{"canManage":true}}}"#

    func testLoadUsesAccountScopeNoStoreAndDoesNotSendCookies() async throws {
        var captured: URLRequest?
        let client = try IntegrationClient(apiBaseURL: base, userID: "owner", token: "token") { request in
            captured = request
            return self.response(self.listing, request: request)
        }
        let page = try await client.load()
        XCTAssertEqual(page.destinations.first?.id, "dest_1")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/dwm/webhook-destinations?orgId=owner")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
    }

    func testLoadValidatesOrganizationLifecycleAndScopesRows() async throws {
        let client = try IntegrationClient(apiBaseURL: base, userID: "owner", token: "token", organizationID: "org_1") { request in
            if request.url?.path.hasSuffix("/organizations/org_1") == true {
                return self.response(#"{"organization":{"id":"org_1","lifecycleStatus":"active","settings":{"auditSafeMetadata":{}}}}"#, request: request)
            }
            let body = self.listing.replacingOccurrences(of: "owner", with: "org_1")
            return self.response(body, request: request)
        }
        let result = try await client.load()
        XCTAssertEqual(result.destinations.first?.orgId, "org_1")
        XCTAssertThrowsError(try IntegrationClient(apiBaseURL: URL(string: "http://api.hanasand.test/api")!, userID: "owner", token: "token"))
    }

    func testLoadFailsClosedWhenOrganizationLifecycleCannotBeVerified() async throws {
        let client = try IntegrationClient(apiBaseURL: base, userID: "owner", token: "token", organizationID: "org_1") { request in
            if request.url?.path.hasSuffix("/organizations/org_1") == true {
                return self.response(#"{"organization":{"id":"org_1","lifecycleStatus":"active"}}"#, request: request)
            }
            return self.response(self.listing.replacingOccurrences(of: "owner", with: "org_1"), request: request)
        }
        do { _ = try await client.load(); XCTFail("Expected missing lifecycle proof to block access") }
        catch IntegrationClientError.readOnly {}
    }

    func testSaveValidatesDiscordHostAndSendsScopedMutation() async throws {
        var captured: URLRequest?
        let client = try IntegrationClient(apiBaseURL: base, userID: "owner", token: "token") { request in
            captured = request
            return self.response(#"{"destination":{"id":"dest_new","orgId":"owner","name":"Alerts","kind":"discord","status":"active"}}"#, request: request, status: 201)
        }
        let page = try JSONDecoder().decode(IntegrationPage.self, from: Data(listing.utf8))
        try await client.save(page: page, draft: IntegrationDraft(id: nil, name: " Alerts ", kind: .discord, endpointURL: "https://discord.com/api/webhooks/1/secret"))
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/api/dwm/webhook-destinations")
        let payload = try XCTUnwrap(try XCTUnwrap(captured?.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: String] })
        XCTAssertEqual(payload["orgId"], "owner")
        XCTAssertEqual(payload["name"], "Alerts")
        XCTAssertThrowsError(try IntegrationClient.validate(IntegrationDraft(id: nil, name: "bad", kind: .discord, endpointURL: "https://evil.example/api/webhooks/1/x")))
    }

    func testArchiveRequiresProofAndConfirmsArchivedResult() async throws {
        var captured: URLRequest?
        let client = try IntegrationClient(apiBaseURL: base, userID: "owner", token: "token") { request in
            captured = request
            return self.response(#"{"destination":{"id":"dest_1","orgId":"owner","name":"Ops","kind":"discord","status":"archived"}}"#, request: request)
        }
        let page = try JSONDecoder().decode(IntegrationPage.self, from: Data(listing.utf8))
        try await client.archive(page: page, destination: page.destinations[0])
        XCTAssertEqual(captured?.httpMethod, "DELETE")
        // Impersonation disables mutations but remains usable for read-only requests.
        let impersonated = try IntegrationClient(apiBaseURL: base, userID: "owner", token: "token", impersonatingUserID: "other") { request in self.response(self.listing, request: request) }
        do { try await impersonated.archive(page: page, destination: page.destinations[0]); XCTFail("Expected impersonation guard") }
        catch IntegrationClientError.readOnly {}
    }

    func testLiveTestRequiresExplicitActionProofAndValidatesDeliveryScope() async throws {
        var captured: URLRequest?
        let client = try IntegrationClient(apiBaseURL: base, userID: "owner", token: "token") { request in
            captured = request
            return self.response(#"{"delivery":{"destinationId":"dest_1","orgId":"owner","status":"delivered","dryRun":false,"error":null}}"#, request: request, status: 202)
        }
        let page = try JSONDecoder().decode(IntegrationPage.self, from: Data(listing.utf8))
        let result = try await client.test(page: page, destination: page.destinations[0])
        XCTAssertTrue(result.0)
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        let json = try XCTUnwrap(captured?.httpBody).flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Bool] }
        XCTAssertEqual(json, ["dryRun": false, "live": true])
    }

    func testInvalidCredentialsAndUncertainMutationAreReported() async throws {
        XCTAssertThrowsError(try IntegrationClient(apiBaseURL: base, userID: "", token: "token"))
        let client = try IntegrationClient(apiBaseURL: base, userID: "owner", token: "token") { request in
            throw URLError(.timedOut)
        }
        let page = try JSONDecoder().decode(IntegrationPage.self, from: Data(listing.utf8))
        do { try await client.archive(page: page, destination: page.destinations[0]); XCTFail("Expected ambiguous write result") }
        catch IntegrationClientError.uncertainResult {}
    }
}
