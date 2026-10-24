import Foundation
import CryptoKit
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

    func testRunRetentionRechecksRoleAndPostsIdempotencyKey() async throws {
        var methods: [String] = []
        let responseJSON = snapshotJSON
            .replacingOccurrences(of: #""limit":50"#, with: #""limit":100"#)
            .replacingOccurrences(of: #""request_id":"req-1"#, with: #""request_id":"stable-123"#)
            .replacingOccurrences(of: #""status":"completed""#, with: #""status":"completed""#)
            .replacingOccurrences(of: #""permissions":{"canExport":true,"canRunRetention":true,"canRequestDeletion":false,"deletionRequiresReauthentication":true}"#, with: #""permissions":{"canExport":true,"canRunRetention":true,"canRequestDeletion":false,"deletionRequiresReauthentication":true},"worker":{"runId":"run-1","claimed":true}"#)
        let client = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { request in
            methods.append(request.httpMethod ?? "")
            if request.httpMethod == "GET" { return self.http(self.snapshotJSON, request: request) }
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(object["action"], "run_retention")
            XCTAssertEqual(object["requestId"], "stable-123")
            return self.http(responseJSON, request: request)
        }
        let receipt = try await client.perform(.runRetention, requestID: "stable-123", expectedName: "Example Org")
        XCTAssertEqual(receipt.status, "completed")
        XCTAssertEqual(methods, ["GET", "POST"])
    }

    func testRoleDenialStopsBeforePostAndBadDeletionConfirmationIsRejected() async throws {
        var postCount = 0
        let denied = snapshotJSON.replacingOccurrences(of: #""canExport":true,"canRunRetention":true"#, with: #""canExport":false,"canRunRetention":false"#)
        let client = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { request in
            if request.httpMethod == "POST" { postCount += 1 }
            return self.http(denied, request: request)
        }
        do {
            _ = try await client.perform(.runRetention, requestID: "role-test", expectedName: "Example Org")
            XCTFail("Expected role check")
        } catch OrganizationPrivacyError.permissionDenied {}
        XCTAssertEqual(postCount, 0)

        let ownerClient = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { request in
            self.http(self.snapshotJSON.replacingOccurrences(of: #""canRequestDeletion":false"#, with: #""canRequestDeletion":true"#), request: request)
        }
        do {
            _ = try await ownerClient.perform(.delete, requestID: "delete-test", expectedName: "Example Org", deletionName: "wrong", currentPassword: "password")
            XCTFail("Expected exact-name guard")
        } catch OrganizationPrivacyError.invalidDeletionConfirmation {}
    }

    func testIntentRegistryPreventsSecondUnresolvedSubmission() throws {
        let registry = OrganizationPrivacyIntentRegistry(baseURL: URL(string: "https://api.example.test")!, userID: "owner", organizationID: "org")
        let first = OrganizationPrivacyIntent(action: .runRetention, requestID: "request-1")
        try registry.claim(first)
        XCTAssertThrowsError(try registry.claim(OrganizationPrivacyIntent(action: .delete, requestID: "request-2"))) { error in
            guard case OrganizationPrivacyError.duplicateSubmission = error else { return XCTFail("Unexpected error: \(error)") }
        }
        registry.resolve(first)
        XCTAssertNoThrow(try registry.claim(OrganizationPrivacyIntent(action: .export, requestID: "request-3")))
    }

    func testExportRequiresMatchingRequestScopeAndRawDataChecksum() async throws {
        let dataJSON = #"{"public":{"organization":{"id":"org/a"}},"threatIntelligence":{"schemaVersion":"organization.privacy_export.ti.v1","organizationId":"org/a","tenantId":"org/a"}}"#
        let checksum = SHA256.hash(data: Data(dataJSON.utf8)).map { String(format: "%02x", $0) }.joined()
        let export = #"{"schemaVersion":"organization.privacy_export.v1","organizationID":"org/a","tenantID":"org/a","exportedAt":"2026-10-21T10:00:00Z","data":\#(dataJSON),"checksum":"\#(checksum)"}"#
        let response = #"{"export":\#(export),"request":{"id":"privacy-1","status":"completed"}}"#
        let client = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { request in
            self.http(request.httpMethod == "GET" ? self.snapshotJSON.replacingOccurrences(of: #""request_id":"req-2""#, with: #""request_id":"export-1""#) : response, request: request)
        }
        let receipt = try await client.perform(.export, requestID: "export-1", expectedName: "Example Org")
        XCTAssertEqual(receipt.status, "completed")
        XCTAssertEqual(receipt.checksum, checksum)
        XCTAssertTrue(String(data: try XCTUnwrap(receipt.exportFile), encoding: .utf8)?.contains(#""organizationID":"org/a""#) == true)

        let invalid = response.replacingOccurrences(of: checksum, with: String(repeating: "0", count: 64))
        let badClient = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { request in
            self.http(request.httpMethod == "GET" ? self.snapshotJSON.replacingOccurrences(of: #""request_id":"req-2""#, with: #""request_id":"export-2""#) : invalid, request: request)
        }
        do {
            _ = try await badClient.perform(.export, requestID: "export-2", expectedName: "Example Org")
            XCTFail("Expected checksum rejection")
        } catch OrganizationPrivacyError.unconfirmedOutcome {}
    }

    func testFailedExportReceiptIsKnownOnlyWhenHistoryMatchesAndResolvesIntent() async throws {
        let recordJSON = #"{"id":"privacy-1","organization_id":"org/a","status":"completed","request_id":"req-2","request_type":"export","requested_at":"2026-10-21T10:00:00Z"}"#
        func history(recordID: String = "privacy-failed", requestID: String = "export-failed", type: String = "export", status: String = "failed", orgID: String = "org/a") -> String {
            let record = #"{"id":"\#(recordID)","organization_id":"\#(orgID)","status":"\#(status)","request_id":"\#(requestID)","request_type":"\#(type)","requested_at":"2026-10-21T10:00:00Z"}"#
            return snapshotJSON.replacingOccurrences(of: recordJSON, with: record)
        }

        let expectedIntent = OrganizationPrivacyIntent(action: .export, requestID: "export-failed")
        let registry = OrganizationPrivacyIntentRegistry(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", organizationID: "org/a")
        var reads = 0
        let client = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a", send: { request in
            if request.httpMethod == "GET" {
                reads += 1
                let response = reads == 1 ? self.snapshotJSON : history()
                return self.http(response, request: request)
            }
            XCTAssertEqual(request.httpMethod, "POST")
            return self.http(#"{"error":"Private export error detail","request":{"id":"privacy-failed","status":"failed"}}"#, request: request, status: 502)
        }, registry: registry)

        let receipt = try await client.perform(.export, requestID: expectedIntent.requestID, expectedName: "Example Org")
        XCTAssertEqual(receipt.status, "failed")
        XCTAssertNil(receipt.exportFile)
        XCTAssertNil(receipt.checksum)
        XCTAssertEqual(receipt.serverRecordID, "privacy-failed")
        XCTAssertNil(registry.unresolved())
        XCTAssertEqual(reads, 2)
        XCTAssertNoThrow(try registry.claim(OrganizationPrivacyIntent(action: .export, requestID: "next-export")))
    }

    func testFailedExportReceiptMustMatchPersistedRequestOrIntentStaysLocked() async throws {
        let recordJSON = #"{"id":"privacy-1","organization_id":"org/a","status":"completed","request_id":"req-2","request_type":"export","requested_at":"2026-10-21T10:00:00Z"}"#
        func history(recordID: String = "privacy-failed", requestID: String = "export-failed", type: String = "export", status: String = "failed", orgID: String = "org/a") -> String {
            let record = #"{"id":"\#(recordID)","organization_id":"\#(orgID)","status":"\#(status)","request_id":"\#(requestID)","request_type":"\#(type)","requested_at":"2026-10-21T10:00:00Z"}"#
            return snapshotJSON.replacingOccurrences(of: recordJSON, with: record)
        }
        let scenarios: [(String, Int, String, String)] = [
            ("server record ID", 502, #"{"request":{"id":"other-record","status":"failed"}}"#, history()),
            ("client request ID", 502, #"{"request":{"id":"privacy-failed","status":"failed"}}"#, history(requestID: "other-request")),
            ("request type", 502, #"{"request":{"id":"privacy-failed","status":"failed"}}"#, history(type: "deletion")),
            ("persisted status", 502, #"{"request":{"id":"privacy-failed","status":"failed"}}"#, history(status: "completed")),
            ("organization scope", 502, #"{"request":{"id":"privacy-failed","status":"failed"}}"#, history(orgID: "other-org")),
            ("receipt status", 502, #"{"request":{"id":"privacy-failed","status":"completed"}}"#, history()),
            ("missing receipt", 502, #"{"error":"Private error detail"}"#, history()),
            ("malformed receipt", 502, "{malformed", history()),
            ("unreceipted server error", 503, #"{"error":"Private error detail"}"#, history()),
        ]

        for (label, status, receiptJSON, historyJSON) in scenarios {
            let registry = OrganizationPrivacyIntentRegistry(baseURL: URL(string: "https://api.hanasand.test/api")!, userID: "owner", organizationID: "org/a")
            var reads = 0
            let client = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a", send: { request in
                if request.httpMethod == "GET" {
                    reads += 1
                    return self.http(reads == 1 ? self.snapshotJSON : historyJSON, request: request)
                }
                return self.http(receiptJSON, request: request, status: status)
            }, registry: registry)
            do {
                _ = try await client.perform(.export, requestID: "export-failed", expectedName: "Example Org")
                XCTFail("Expected an uncertain outcome for mismatched \(label)")
            } catch OrganizationPrivacyError.unconfirmedOutcome {}
            XCTAssertEqual(registry.unresolved(), OrganizationPrivacyIntent(action: .export, requestID: "export-failed"), label)
        }
    }

    func testDeletionRequiresReauthenticationAndValidatesLinkedRunReceipt() async throws {
        let ownerRead = snapshotJSON.replacingOccurrences(of: #""canRequestDeletion":false"#, with: #""canRequestDeletion":true"#)
        let deletionState = #"{"schemaVersion":"organization.privacy_state.v1","organization":{"id":"org/a","name":"Example Org","status":"active","retention_days":90},"runs":[{"id":"delete-run","organization_id":"org/a","status":"completed","request_id":"delete-ok","trigger_type":"privacy_deletion","privacy_request_id":"delete-request"}],"requests":[{"id":"delete-request","organization_id":"org/a","status":"completed","request_id":"delete-ok","request_type":"deletion"}],"items":[],"itemPage":{"offset":0,"limit":100,"nextOffset":null},"protection":{"protected_events":3,"total_retention_items":101,"access_recovery_holds":1,"immutable_system_events":2,"immutable_webhook_audit_events":4,"immutable_log_events":5,"explanation":"Protected records remain."},"worker":{"runId":"delete-run","claimed":true}}"#
        let client = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { request in
            if request.httpMethod == "GET" { return self.http(ownerRead, request: request) }
            let body = try XCTUnwrap(request.httpBody)
            let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
            XCTAssertEqual(object["confirmation"], "Example Org")
            XCTAssertEqual(object["currentPassword"], "current-secret")
            XCTAssertEqual(object["action"], "delete")
            XCTAssertEqual(object["requestId"], "delete-ok")
            return self.http(deletionState, request: request)
        }
        let receipt = try await client.perform(.delete, requestID: "delete-ok", expectedName: "Example Org", deletionName: "Example Org", currentPassword: "current-secret")
        XCTAssertEqual(receipt.status, "completed")

        let deniedClient = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { request in
            request.httpMethod == "GET" ? self.http(ownerRead, request: request) : self.http(#"{"error":{"message":"Current password is required again."}}"#, request: request, status: 403)
        }
        do {
            _ = try await deniedClient.perform(.delete, requestID: "delete-denied", expectedName: "Example Org", deletionName: "Example Org", currentPassword: "wrong")
            XCTFail("Expected password reauthentication rejection")
        } catch OrganizationPrivacyError.requestFailed(let status, _) { XCTAssertEqual(status, 403) }
    }

    func testAmbiguousConflictLocksOutDuplicateUntilExplicitResolution() async throws {
        var postCount = 0
        let client = try OrganizationPrivacyClient(settings: settings, organizationID: "org/a") { request in
            if request.httpMethod == "POST" {
                postCount += 1
                return self.http(#"{"error":"An active run already exists."}"#, request: request, status: 409)
            }
            return self.http(self.snapshotJSON, request: request)
        }
        do {
            _ = try await client.perform(.runRetention, requestID: "conflict-1", expectedName: "Example Org")
            XCTFail("Expected unresolved conflict")
        } catch OrganizationPrivacyError.unconfirmedOutcome {}
        do {
            _ = try await client.perform(.export, requestID: "conflict-2", expectedName: "Example Org")
            XCTFail("Expected duplicate submission guard")
        } catch OrganizationPrivacyError.duplicateSubmission {}
        XCTAssertEqual(postCount, 1)
    }
}
