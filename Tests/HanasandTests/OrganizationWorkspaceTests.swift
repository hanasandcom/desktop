import Foundation
import XCTest
@testable import Hanasand

private final class OrganizationWorkspaceRequestRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedRequests: [URLRequest] = []

    func append(_ request: URLRequest) {
        lock.lock()
        storedRequests.append(request)
        lock.unlock()
    }

    var requests: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }
}

final class OrganizationWorkspaceTests: XCTestCase {
    private var settings: HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.websiteBaseURL = "https://hanasand.test"
        value.userID = "owner"
        value.authToken = "token_abc-123"
        value.selectedOrganizationID = "org/a"
        value.selectedOrganizationUserID = "owner"
        return value
    }

    private func http(_ json: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    private let settingsJSON = #"{"organization":{"id":"org/a","name":"Example Org","slug":"example-org","lifecycleStatus":"active","role":"owner"},"settings":{"defaultWebhookPolicy":"active_destinations","alertVisibilityPolicy":"members","lifecycleStatus":"active","retentionDays":365,"auditSafeMetadata":{}},"permissions":{"canEdit":true,"editableFields":["name","slug","defaultWebhookPolicy","alertVisibilityPolicy","retentionDays","auditSafeMetadata"]},"lifecycleReadiness":{}}"#

    func testSettingsReadUsesSecureScopedNoStoreAuthenticatedRequest() async throws {
        var captured: URLRequest?
        let client = try OrganizationWorkspaceClient(settings: settings, organizationID: "org/a") { request in
            captured = request
            return self.http(self.settingsJSON, request: request)
        }
        let page = try await client.loadSettings()
        XCTAssertEqual(page.organization.id, "org/a")
        XCTAssertEqual(page.settings.name, "Example Org")
        XCTAssertEqual(captured?.url?.absoluteString, "https://hanasand.test/api/organizations/org%2Fa/settings")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
    }

    func testRecordsLoadUsesOrganizationBoundEventAndCaseRoutes() async throws {
        let recorder = OrganizationWorkspaceRequestRecorder()
        let client = try OrganizationWorkspaceClient(settings: settings, organizationID: "org/a") { request in
            recorder.append(request)
            if request.url?.path.hasSuffix("/api/findings/alerts") == true {
                return self.http(#"{"organization":{"id":"org/a"},"visibilityDecision":{"allowed":true},"alerts":[],"total":0,"nextCursor":null}"#, request: request)
            }
            return self.http(#"{"organizationId":"org/a","items":[],"cases":[],"warnings":[]}"#, request: request)
        }
        let result = try await client.loadRecords()
        let requests = recorder.requests
        XCTAssertTrue(result.events.isEmpty)
        XCTAssertTrue(result.cases.isEmpty)
        XCTAssertEqual(requests.count, 2)
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer token_abc-123" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
        let alerts = requests.first { $0.url?.path.hasSuffix("/api/findings/alerts") == true }!
        let alertQuery = URLComponents(url: alerts.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(alertQuery.first(where: { $0.name == "organizationId" })?.value, "org/a")
        XCTAssertEqual(alertQuery.first(where: { $0.name == "tenantId" })?.value, "org/a")
        let cases = requests.first { $0.url?.path.hasSuffix("/api/cases") == true }!
        XCTAssertEqual(URLComponents(url: cases.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, "org/a")
    }

    func testSettingsWriteRechecksServerPermissionAndValidatesReceipt() async throws {
        var requests: [URLRequest] = []
        let client = try OrganizationWorkspaceClient(settings: settings, organizationID: "org/a") { request in
            requests.append(request)
            if request.httpMethod == "GET" { return self.http(self.settingsJSON, request: request) }
            return self.http(#"{"organization":{"id":"org/a","name":"New Name","slug":"new-name","lifecycleStatus":"active","role":"owner"},"settings":{"defaultWebhookPolicy":"active_destinations","alertVisibilityPolicy":"members","lifecycleStatus":"active","retentionDays":90},"settingsMutationReceipt":{"schemaVersion":"organization.lifecycle_settings_mutation_receipt.v1","organizationId":"org/a","lifecycleStatus":"active","mutatedFields":["name","slug","retentionDays"]}}"#, request: request)
        }
        let draft = OrganizationWorkspaceSettings(name: "New Name", slug: "new-name", defaultWebhookPolicy: "active_destinations", alertVisibilityPolicy: "members", lifecycleStatus: "active", retentionDays: 90)
        let receipt = try await client.updateSettings(draft)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT"])
        XCTAssertEqual(receipt.organization?.id, "org/a")
        XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        XCTAssertEqual(body["name"] as? String, "New Name")
        XCTAssertEqual(body["slug"] as? String, "new-name")
        XCTAssertEqual(body["defaultWebhookPolicy"] as? String, "active_destinations")
        XCTAssertEqual(body["alertVisibilityPolicy"] as? String, "members")
        XCTAssertEqual(body["lifecycleStatus"] as? String, "active")
        XCTAssertEqual(body["retentionDays"] as? Int, 90)
    }

    func testSettingsWriteStopsWhenFreshServerPermissionsDenyEdit() async throws {
        let denied = settingsJSON.replacingOccurrences(of: #""canEdit":true"#, with: #""canEdit":false"#)
        let client = try OrganizationWorkspaceClient(settings: settings, organizationID: "org/a") { request in
            self.http(denied, request: request)
        }
        let draft = OrganizationWorkspaceSettings(name: "New Name", slug: "new-name", defaultWebhookPolicy: "active_destinations", alertVisibilityPolicy: "members", lifecycleStatus: "active", retentionDays: 90)
        do {
            _ = try await client.updateSettings(draft)
            XCTFail("Expected permission denial")
        } catch OrganizationWorkspaceError.permissionChanged {}
    }

    func testClientRejectsCrossOrganizationAndImpersonatedWrites() async throws {
        XCTAssertThrowsError(try OrganizationWorkspaceClient(settings: settings, organizationID: "other"))
        var impersonating = settings
        impersonating.impersonationToken = "impersonation-token"
        let client = try OrganizationWorkspaceClient(settings: impersonating, organizationID: "org/a") { request in
            self.http(self.settingsJSON, request: request)
        }
        XCTAssertFalse(OrganizationWorkspacePolicy.canEdit(
            settings: try JSONDecoder().decode(OrganizationWorkspaceSettingsPage.self, from: Data(settingsJSON.utf8)),
            selectedOrganizationID: "org/a", signedInUserID: "owner", isAuthenticated: true, isImpersonating: true
        ))
        do {
            _ = try await client.updateSettings(.init(name: "New Name", slug: "new-name", defaultWebhookPolicy: "disabled", alertVisibilityPolicy: "owners", lifecycleStatus: "active", retentionDays: 90))
            XCTFail("Expected impersonation write denial")
        } catch OrganizationWorkspaceError.impersonationUnsupported {}
    }

    func testSettingsPolicyRejectsMalformedValues() {
        XCTAssertTrue(OrganizationWorkspacePolicy.valid(.init(name: "Example Org", slug: "example-org", defaultWebhookPolicy: "active_destinations", alertVisibilityPolicy: "members", lifecycleStatus: "active", retentionDays: 365)))
        XCTAssertFalse(OrganizationWorkspacePolicy.valid(.init(name: "x", slug: "../other", defaultWebhookPolicy: "*", alertVisibilityPolicy: "public", lifecycleStatus: "deleted", retentionDays: 0)))
    }

    func testOverviewSummarizesEventsCasesAndLatestActivity() {
        let events = [
            OrganizationWorkspaceRecord(id: "event-1", title: "Older event", status: "new", severity: "low",
                updatedAt: "2026-10-20T10:00:00Z", createdAt: "", organizationId: "org/a"),
            OrganizationWorkspaceRecord(id: "event-2", title: "Latest event", status: "new", severity: "high",
                updatedAt: "2026-10-23T10:00:00Z", createdAt: "", organizationId: "org/a"),
        ]
        let cases = [
            OrganizationWorkspaceRecord(id: "case-open", title: "Open", status: "investigating", severity: "high",
                updatedAt: "2026-10-22T10:00:00Z", createdAt: "", organizationId: "org/a"),
            OrganizationWorkspaceRecord(id: "case-closed", title: "Closed", status: "resolved", severity: "low",
                updatedAt: "2026-10-21T10:00:00Z", createdAt: "", organizationId: "org/a"),
        ]

        let overview = OrganizationWorkspaceOverview(events: events, cases: cases)

        XCTAssertEqual(overview.eventCount, 2)
        XCTAssertEqual(overview.caseCount, 2)
        XCTAssertEqual(overview.openCaseCount, 1)
        XCTAssertEqual(overview.latestActivity, "2026-10-23T10:00:00Z")
        XCTAssertNil(OrganizationWorkspaceOverview(events: [], cases: []).latestActivity)
    }
}
