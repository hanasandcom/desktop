import Foundation
import XCTest

@testable import Hanasand

final class IntelligenceCasesTests: XCTestCase {
    func testDecodesIntelligenceCasePageAndUntrustedStructuredSummary() throws {
        let page = try JSONDecoder().decode(IntelligenceCasePage.self, from: data(#"{"items":[{"id":"case-1","source":"intelligence","title":"Source-backed alert","summary":"Unverified report","status":"open","severity":"high","assignedOwner":"analyst@example.test","organizationId":"org-1","updatedAt":"2026-10-20T12:00:00Z","evidence":[{"private":"field"}]}],"nextCursor":"opaque-2","total":2}"#))
        XCTAssertEqual(page.items.first?.id, "case-1")
        XCTAssertEqual(page.items.first?.organizationID, "org-1")
        XCTAssertEqual(page.items.first?.severity, "high")
        XCTAssertEqual(page.items.first?.raw["evidence"]?.arrayValue.first?["private"]?.stringValue, "field")
        XCTAssertEqual(page.nextCursor, "opaque-2")
    }

    func testDecodesCaseDetailTimelineEvidenceAndServerActionPolicy() throws {
        let detail = try JSONDecoder().decode(IntelligenceCaseDetailEnvelope.self, from: data(#"{"case":{"id":"case-1","source":"intelligence","title":"Incident","status":"open","organizationId":"org-1","resolution":{"type":"human","actor":"reviewer"}},"timeline":[{"id":"event-1","action":"note","actor":"analyst","note":"Reviewed evidence"}],"evidence":[{"id":"evidence-1","sourceName":"Example feed","contentHash":"abc"}],"access":{"readOnly":false},"workflowActionPolicy":{"summary":{"readOnly":false},"actions":[{"id":"assign","label":"Assign","method":"PATCH","requiresRationale":true,"enabled":true},{"id":"close","enabled":false,"disabledReason":"Evidence review is required."}]}}"#))
        XCTAssertEqual(detail.caseRecord.id, "case-1")
        XCTAssertEqual(detail.timeline.first?["note"]?.stringValue, "Reviewed evidence")
        XCTAssertEqual(detail.evidence.first?["contentHash"]?.stringValue, "abc")
        XCTAssertFalse(detail.readOnly)
        XCTAssertEqual(detail.actions.map(\.id), ["assign", "close"])
        XCTAssertTrue(detail.actions[0].requiresRationale)
        XCTAssertFalse(detail.actions[1].enabled)
    }

    func testListUsesAuthenticatedTIEndpointAndExplicitOrganizationScope() async throws {
        var captured: URLRequest?
        let client = try IntelligenceCasesClient(settings: makeSettings(organization: "org-1")) { request in
            captured = request
            return (self.data(#"{"items":[{"id":"case-1","source":"intelligence","organizationId":"org-1","status":"open"}],"total":1}"#), self.response(for: request.url!))
        }
        let page = try await client.load()
        XCTAssertEqual(page.items.first?.id, "case-1")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(captured?.url?.host, "ti.hanasand.com")
        XCTAssertEqual(captured?.url?.path, "/v1/cases")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "user-1")
        let query = URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "tenantId" })?.value, "org-1")
        XCTAssertEqual(query.first(where: { $0.name == "organizationId" })?.value, "org-1")
        XCTAssertEqual(query.first(where: { $0.name == "page" })?.value, "1")
        XCTAssertEqual(captured?.httpShouldHandleCookies, false)
    }

    func testListCursorAndDetailKeepSelectedOrganizationScope() async throws {
        var captured: [URLRequest] = []
        let client = try IntelligenceCasesClient(settings: makeSettings(organization: "org-1")) { request in
            captured.append(request)
            let body = request.url?.path == "/v1/cases/case-1"
                ? #"{"case":{"id":"case-1","source":"intelligence","organizationId":"org-1"},"timeline":[],"evidence":[],"nextAllowedActions":[]}"#
                : #"{"items":[],"nextCursor":"cursor-2","total":2}"#
            return (self.data(body), self.response(for: request.url!))
        }
        let page = try await client.load(cursor: "cursor-1")
        let detail = try await client.detail(caseID: "case-1")
        XCTAssertEqual(page.nextCursor, "cursor-2")
        XCTAssertEqual(detail.caseRecord.id, "case-1")
        XCTAssertEqual(URLComponents(url: captured[0].url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "cursor" })?.value, "cursor-1")
        for request in captured {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
            XCTAssertEqual(query.first(where: { $0.name == "organizationId" })?.value, "org-1")
        }
    }

    func testCaseLinkOrganizationContextOverridesTheDefaultSelection() async throws {
        var captured: URLRequest?
        let client = try IntelligenceCasesClient(settings: makeSettings(), organizationIDOverride: "org-linked") { request in
            captured = request
            return (self.data(#"{"items":[],"total":0}"#), self.response(for: request.url!))
        }

        _ = try await client.load()

        let query = URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "tenantId" })?.value, "org-linked")
        XCTAssertEqual(query.first(where: { $0.name == "organizationId" })?.value, "org-linked")
    }

    func testActionRequiresCurrentServerAuthorizationAndMatchingDurableReceipt() async throws {
        var captured: URLRequest?
        let settings = makeSettings(organization: "org-1")
        let client = try IntelligenceCasesClient(settings: settings) { request in
            captured = request
            return (self.data(#"{"case":{"id":"case-1","status":"in_progress"}}"#), self.response(for: request.url!))
        }
        let record = try JSONDecoder().decode(IntelligenceCaseRow.self, from: data(#"{"id":"case-1","source":"intelligence","organizationId":"org-1","status":"open","updatedAt":"2026-10-20T12:00:00Z"}"#))
        let action = try JSONDecoder().decode(IntelligenceCaseAction.self, from: data(#"{"id":"assign","label":"Assign","method":"PATCH","requiresRationale":true,"enabled":true}"#))
        try await client.perform(action, caseRecord: record, alertID: "alert-1", note: "  Evidence reviewed  ", assignedOwner: " analyst ", currentSettings: settings)
        XCTAssertEqual(captured?.httpMethod, "PATCH")
        XCTAssertEqual(captured?.url?.path, "/v1/cases/case-1")
        let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: captured!.httpBody!) as? [String: Any])
        XCTAssertEqual(body["action"] as? String, "assign")
        XCTAssertEqual(body["note"] as? String, "Evidence reviewed")
        XCTAssertEqual(body["assignedOwner"] as? String, "analyst")
        XCTAssertEqual(body["organizationId"] as? String, "org-1")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "alertId" })?.value, "alert-1")
        XCTAssertTrue((body["idempotencyKey"] as? String)?.hasPrefix("desktop-case:case-1:assign:") == true)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
    }

    func testRejectsCrossOrganizationRowsAndUnsafeOrImpersonatedSettings() async throws {
        let client = try IntelligenceCasesClient(settings: makeSettings(organization: "org-1")) { request in
            (self.data(#"{"items":[{"id":"case-2","source":"intelligence","organizationId":"org-other"}],"total":1}"#), self.response(for: request.url!))
        }
        do { _ = try await client.load(); XCTFail("Expected cross-organization data to be rejected.") }
        catch { XCTAssertEqual(error as? IntelligenceCasesError, .invalidResponse) }

        var impersonated = makeSettings()
        impersonated.impersonatingUserID = "other-user"
        XCTAssertThrowsError(try IntelligenceCasesClient(settings: impersonated))
        var insecure = makeSettings()
        insecure.websiteBaseURL = "http://hanasand.test"
        XCTAssertThrowsError(try IntelligenceCasesClient(settings: insecure))
    }

    private func makeSettings(organization: String = "") -> HanasandDesktopSettings {
        var settings = HanasandDesktopSettings()
        settings.websiteBaseURL = "https://hanasand.com"
        settings.userID = "user-1"
        settings.authToken = "test-token"
        settings.selectedOrganizationID = organization
        return settings
    }
    private func data(_ value: String) -> Data { Data(value.utf8) }
    private func response(for url: URL) -> HTTPURLResponse { HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])! }
}
