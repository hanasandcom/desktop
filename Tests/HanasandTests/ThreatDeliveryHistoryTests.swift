import Foundation
import XCTest
@testable import Hanasand

final class ThreatDeliveryHistoryTests: XCTestCase {
    func testClientRequestsSelectedOrganizationWithoutCookiesOrWrites() async throws {
        var settings = makeSettings()
        settings.selectedOrganizationID = "org-123"
        settings.selectedOrganizationUserID = settings.userID
        var captured: URLRequest?
        let client = try ThreatDeliveryHistoryClient(settings: settings) { request in
            captured = request
            return (self.payload(organizationID: "org-123"), self.response(status: 200))
        }

        let result = try await client.load()

        XCTAssertEqual(result.organizationID, "org-123")
        XCTAssertEqual(result.deliveries.count, 1)
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "orgId", value: "org-123")])
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertEqual(captured?.httpShouldHandleCookies, false)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
    }

    func testRejectsPersonalOrStaleOrganizationScopeAndImpersonation() {
        var settings = makeSettings()
        XCTAssertThrowsError(try ThreatDeliveryHistoryClient(settings: settings))

        settings.selectedOrganizationID = "org-123"
        settings.selectedOrganizationUserID = "another-user"
        XCTAssertThrowsError(try ThreatDeliveryHistoryClient(settings: settings))

        settings.selectedOrganizationUserID = settings.userID
        settings.impersonationToken = "impersonation"
        XCTAssertThrowsError(try ThreatDeliveryHistoryClient(settings: settings))
    }

    func testRejectsDeniedVisibilityAndCrossOrganizationReceipts() async throws {
        var settings = makeSettings()
        settings.selectedOrganizationID = "org-123"
        settings.selectedOrganizationUserID = settings.userID

        let denied = try ThreatDeliveryHistoryClient(settings: settings) { _ in
            (self.payload(organizationID: "org-123", allowed: false), self.response(status: 200))
        }
        do {
            _ = try await denied.load()
            XCTFail("Expected denied visibility to fail.")
        } catch { XCTAssertTrue(error is ThreatDeliveryHistoryError) }

        let crossOrg = try ThreatDeliveryHistoryClient(settings: settings) { _ in
            (self.payload(organizationID: "org-other"), self.response(status: 200))
        }
        do {
            _ = try await crossOrg.load()
            XCTFail("Expected a cross-organization receipt to fail.")
        } catch { XCTAssertTrue(error is ThreatDeliveryHistoryError) }
    }

    func testUnknownStatusIsVisibleAndInvalidAttemptCountsAreOmitted() throws {
        let data = Data(#"{"id":"delivery-1","orgId":"org-1","alertId":"alert-1","status":"future_state","attemptCount":-3}"#.utf8)
        let attempt = try JSONDecoder().decode(ThreatDeliveryHistory.Attempt.self, from: data)
        XCTAssertEqual(attempt.status, .unknown)
        XCTAssertNil(attempt.attemptCount)
        XCTAssertEqual(attempt.statusLabel, "Status not reported")
    }

    private func makeSettings() -> HanasandDesktopSettings {
        var settings = HanasandDesktopSettings()
        settings.apiBaseURL = "https://api.example.test/api"
        settings.userID = "user-1"
        settings.authToken = "test-token"
        return settings
    }

    private func payload(organizationID: String, allowed: Bool = true) -> Data {
        Data("""
        {"visibility":{"allowed":\(allowed)},"deliveries":[{"id":"delivery-1","orgId":"\(organizationID)","alertId":"alert-1","eventType":"dwm.alert.created","status":"delivered","dryRun":false,"attemptCount":1,"deliveredAt":"2026-10-23T10:00:00Z","payload":{"sensitive":"must not be decoded"}}]}
        """.utf8)
    }

    private func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://api.example.test/api/dwm/webhook-deliveries")!,
                       statusCode: status, httpVersion: "HTTP/1.1", headerFields: nil)!
    }
}
