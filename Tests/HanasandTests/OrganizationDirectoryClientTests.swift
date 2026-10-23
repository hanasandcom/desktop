import Foundation
import XCTest
@testable import Hanasand

final class OrganizationDirectoryClientTests: XCTestCase {
    private var settings: HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.apiBaseURL = "https://api.hanasand.test/api"
        value.userID = "member-1"
        value.authToken = "token_abc-123"
        return value
    }

    private func response(_ json: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        let value = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        return (Data(json.utf8), value)
    }

    func testAdminDirectoryStillLoadsGlobalRowsAndChecksCallerMemberships() async throws {
        var requests: [URLRequest] = []
        let client = try OrganizationDirectoryClient(settings: settings) { request in
            requests.append(request)
            if request.url?.path == "/api/management/organizations" {
                return self.response(#"{"organizations":[{"id":"org-global","name":"Global Org","slug":"global","status":"active","member_count":5}]}"#, request: request)
            }
            return self.response(#"{"organizations":[{"id":"org-member","name":"Member Org","slug":"member","lifecycleStatus":"active","role":"owner","memberCount":1}]}"#, request: request)
        }

        let snapshot = try await client.loadSnapshot()

        XCTAssertEqual(snapshot.organizations.map(\.id), ["org-global"])
        XCTAssertEqual(snapshot.memberships.map(\.id), ["org-member"])
        XCTAssertEqual(requests.map(\.url?.path), ["/api/management/organizations", "/api/organizations"])
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "id"), "member-1")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "id"), "member-1")
        XCTAssertEqual(requests[1].url?.host, "api.hanasand.test")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(requests[0].httpShouldHandleCookies)
    }

    func testDefaultProductionAPIUsesIdentityBaseAndFallsBackOnAdmin403() async throws {
        var configured = settings
        configured.apiBaseURL = "https://api.hanasand.com/api"
        var requests: [URLRequest] = []
        let client = try OrganizationDirectoryClient(settings: configured) { request in
            requests.append(request)
            if request.url?.host == "api.hanasand.com" {
                return self.response(#"{"error":{"message":"Administrator access required"}}"#, request: request, status: 403)
            }
            return self.response(#"{"organizations":[{"id":"org-own","name":"My Org","slug":"my-org","lifecycleStatus":"active","role":"reader","memberCount":4}]}"#, request: request)
        }

        let snapshot = try await client.loadSnapshot()

        XCTAssertEqual(requests.map(\.url?.absoluteString), [
            "https://api.hanasand.com/api/management/organizations",
            "https://identity.hanasand.com/api/organizations",
        ])
        XCTAssertEqual(snapshot.organizations.map(\.id), ["org-own"])
        XCTAssertEqual(snapshot.organizations[0].status, "active")
        XCTAssertEqual(snapshot.organizations[0].memberCount, 4)
        XCTAssertEqual(snapshot.memberships.map(\.id), ["org-own"])
        XCTAssertEqual(snapshot.memberships[0].role, "reader")
        XCTAssertEqual(snapshot.memberships[0].status, "active")
    }

    func testCreateUsesAuthenticatedIdentityPostThenRefreshesAndVerifiesActiveMembership() async throws {
        var requests: [URLRequest] = []
        let client = try OrganizationDirectoryClient(settings: settings) { request in
            requests.append(request)
            switch request.httpMethod {
            case "POST":
                return self.response(#"{"organization":{"id":"org-created","name":"New Workspace"},"lifecycleReadiness":{"ready":true}}"#, request: request, status: 201)
            case "GET" where request.url?.path == "/api/management/organizations":
                return self.response(#"{"error":{"message":"Administrator access required"}}"#, request: request, status: 403)
            default:
                return self.response(#"{"organizations":[{"id":"org-created","name":"New Workspace","slug":"new-workspace","lifecycleStatus":"active","role":"owner","memberCount":1}]}"#, request: request)
            }
        }

        let createdID = try await client.createOrganization(name: "  New Workspace  ")
        let refreshed = try await client.loadSnapshot()
        let organization = try XCTUnwrap(refreshed.organizations.first { $0.id == createdID })
        let membership = try XCTUnwrap(refreshed.memberships.first { $0.id == createdID })

        XCTAssertEqual(createdID, "org-created")
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "GET", "GET"])
        XCTAssertEqual(requests[0].url?.absoluteString, "https://api.hanasand.test/api/organizations")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "id"), "member-1")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(requests[0].httpShouldHandleCookies)
        let body = try XCTUnwrap(requests[0].httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(payload, ["name": "New Workspace"])
        XCTAssertEqual(organization.status, "active")
        XCTAssertEqual(membership.role, "owner")
        XCTAssertEqual(membership.status, "active")
        XCTAssertTrue(DashboardOrganizationSwitchPolicy.canSwitch(
            organizationID: organization.id,
            organizationStatus: organization.status,
            membershipStatus: membership.status,
            isAuthenticated: true,
            isOwnAccount: true,
            isImpersonating: false
        ))
    }

    func testCreateRejectsMalformedReceiptAndInvalidOwnMembershipResponse() async throws {
        let malformedReceipt = try OrganizationDirectoryClient(settings: settings) { request in
            self.response(#"{"organization":{"id":""},"lifecycleReadiness":{}}"#, request: request, status: 201)
        }
        do {
            _ = try await malformedReceipt.createOrganization(name: "Workspace")
            XCTFail("Expected an empty returned organization ID to be rejected")
        } catch OrganizationDirectoryClientError.invalidResponse {}

        let malformedMembership = try OrganizationDirectoryClient(settings: settings) { request in
            if request.url?.path == "/api/management/organizations" {
                return self.response(#"{"error":{"message":"Administrator access required"}}"#, request: request, status: 403)
            }
            return self.response(#"{"organizations":[{"id":"org-one","name":"Missing role","lifecycleStatus":"active"}]}"#, request: request)
        }
        do {
            _ = try await malformedMembership.loadSnapshot()
            XCTFail("Expected an incomplete membership response to be rejected")
        } catch OrganizationDirectoryClientError.invalidResponse {}
    }

    func testCreateDoesNotSendRequestsWhenImpersonating() async throws {
        var impersonating = settings
        impersonating.impersonationToken = "target-session"
        impersonating.impersonatingUserID = "target-user"
        var sent = false
        let client = try OrganizationDirectoryClient(settings: impersonating) { request in
            sent = true
            return self.response("{}", request: request)
        }

        do {
            _ = try await client.createOrganization(name: "Workspace")
            XCTFail("Expected organization creation to be blocked during impersonation")
        } catch OrganizationDirectoryClientError.impersonationUnsupported {}
        XCTAssertFalse(sent)
    }
}
