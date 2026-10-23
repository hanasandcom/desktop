import Foundation
import XCTest
@testable import Hanasand

final class OrganizationPrivacyClientTests: XCTestCase {
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

    private let snapshotJSON = #"{"schemaVersion":"organization.privacy_state.v1","organization":{"id":"org/a","name":"Example Org","status":"active","retention_days":90},"runs":[{"id":"run-1","organization_id":"org/a","status":"completed","request_id":"req-1","trigger_type":"manual","created_at":"2026-10-20T10:00:00Z"}],"requests":[{"id":"privacy-1","organization_id":"org/a","status":"completed","request_id":"req-2","request_type":"export","requested_at":"2026-10-21T10:00:00Z"}],"items":[{"run_id":"run-1","organization_id":"org/a","source_service":"hanasand-api","record_type":"event","record_id":"event-1","status":"protected","processed_at":"2026-10-21T10:00:00Z","reason":"legal_hold"}],"itemPage":{"offset":0,"limit":50,"nextOffset":50},"protection":{"protected_events":3,"total_retention_items":101,"access_recovery_holds":1,"immutable_system_events":2,"immutable_webhook_audit_events":4,"immutable_log_events":5,"explanation":"Legal holds and audit evidence remain protected."},"permissions":{"canExport":true,"canRunRetention":true,"canRequestDeletion":false,"deletionRequiresReauthentication":true}}"#

    func testLoadUsesSelectedOrganizationAndNoStoreAuthenticatedReadOnlyRoute() async throws {
        var captured: URLRequest?
        let client = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { request in
            captured = request
            return self.http(self.snapshotJSON, request: request)
        }
        let result = try await client.load()
        XCTAssertEqual(result.organization.name, "Example Org")
        XCTAssertEqual(result.protection.protectedEvents, 3)
        XCTAssertEqual(result.requests.first?.requestType, "export")
        XCTAssertEqual(result.items.first?.recordID, "event-1")
        XCTAssertEqual(result.items.first?.id, "run-1:hanasand-api:event:event-1")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/organizations/org%2Fa/privacy?itemOffset=0&itemLimit=50")
        XCTAssertEqual(captured?.httpMethod, "GET")
        XCTAssertNil(captured?.httpBody)
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "owner")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertEqual(captured?.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertFalse(captured?.httpShouldHandleCookies ?? true)
    }

    func testHistoryOffsetIsBoundedAndReturnedPageMustMatch() async throws {
        let client = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { request in
            self.http(self.snapshotJSON.replacingOccurrences(of: #""offset":0"#, with: #""offset":50"#), request: request)
        }
        do {
            _ = try await client.load(offset: 50)
            XCTFail("Expected a response offset mismatch")
        } catch OrganizationPrivacyError.invalidResponse {}
        do {
            _ = try await client.load(offset: 51)
            XCTFail("Expected a misaligned page to be rejected")
        } catch OrganizationPrivacyError.invalidOffset {}
    }

    func testClientRequiresOwnerBoundOrganizationAndRejectsImpersonation() throws {
        XCTAssertThrowsError(try OrganizationPrivacyClient(settings: settings, organizationID: "other"))
        var anotherAccount = settings
        anotherAccount.selectedOrganizationUserID = "someone-else"
        XCTAssertThrowsError(try OrganizationPrivacyClient(settings: anotherAccount, organizationID: "org/a"))
        var impersonating = settings
        impersonating.impersonationToken = "impersonation-token"
        XCTAssertThrowsError(try OrganizationPrivacyClient(settings: impersonating, organizationID: "org/a"))
    }

    func testClientRejectsCrossOrganizationRowsAndImpossibleCounts() async throws {
        for changed in [
            snapshotJSON.replacingOccurrences(of: #""organization_id":"org/a""#, with: #""organization_id":"other""#),
            snapshotJSON.replacingOccurrences(of: #""protected_events":3"#, with: #""protected_events":-3"#),
            snapshotJSON.replacingOccurrences(of: #""nextOffset":50"#, with: #""nextOffset":0"#),
        ] {
            let client = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { request in self.http(changed, request: request) }
            do {
                _ = try await client.load()
                XCTFail("Expected invalid privacy response")
            } catch OrganizationPrivacyError.invalidResponse {}
        }
    }

    func testEndpointFailureIsReportedWithoutAttemptingWrites() async throws {
        var request: URLRequest?
        let client = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { incoming in
            request = incoming
            return self.http(#"{"error":{"message":"unavailable"}}"#, request: incoming, status: 503)
        }
        do {
            _ = try await client.load()
            XCTFail("Expected service error")
        } catch OrganizationPrivacyError.requestFailed(let status, let message) {
            XCTAssertEqual(status, 503)
            XCTAssertEqual(message, "unavailable")
        }
        XCTAssertEqual(request?.httpMethod, "GET")
    }
}
