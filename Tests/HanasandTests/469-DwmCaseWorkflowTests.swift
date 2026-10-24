import Foundation
import XCTest
@testable import Hanasand

final class DwmCaseWorkflowTests: XCTestCase {
    func testScopedExportAndHistoryUseAuthenticatedNoCookieHTTPS() async throws {
        var settings = makeSettings(organization: "org-1")
        settings.selectedOrganizationUserID = settings.userID
        var requests: [URLRequest] = []
        let client = try DwmCaseWorkflowClient(settings: settings) { request in
            requests.append(request)
            return (self.responseBody(for: request), self.response(request))
        }

        let result = try await client.load(caseID: "case-1", alertID: "alert-1")

        XCTAssertEqual(result.exportChecksum, String(repeating: "a", count: 64))
        XCTAssertEqual(result.deliveries.count, 1)
        XCTAssertEqual(result.receiverReceipts.count, 1)
        XCTAssertTrue(requests.allSatisfy { $0.url?.scheme == "https" && $0.httpShouldHandleCookies == false })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        let export = try XCTUnwrap(requests.first { $0.url?.path == "/v1/cases/case-1/export" })
        XCTAssertEqual(URLComponents(url: export.url!, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "organizationId" })?.value, "org-1")
        XCTAssertTrue(requests.contains { $0.url?.path == "/api/dwm/webhook-deliveries" && $0.httpMethod == "GET" })
        XCTAssertTrue(requests.contains { $0.url?.path == "/api/findings/webhook-receiver" && $0.httpMethod == "GET" })
    }

    func testReportExportUsesSelectedScopedEvidenceAndRejectsMismatchedResponse() async throws {
        var settings = makeSettings(organization: "org-1")
        settings.selectedOrganizationUserID = settings.userID
        var requests: [URLRequest] = []
        let client = try DwmCaseWorkflowClient(settings: settings) { request in
            requests.append(request)
            return (self.reportExportResponse(format: "json"), self.response(request))
        }
        let snapshot = DwmCaseWorkflowSnapshot(export: [
            "evidenceSummary": .array([.object(["id": .string("evidence-1")]), .object(["id": .string("evidence-2")])]),
        ], destinations: [], deliveries: [], receiverReceipts: [], customerNotificationReceipts: [],
            caseID: "case-1", organizationID: "org-1", alertID: "alert-1", canManageDestinations: false, liveDeliveryEnabled: false)
        let report = try await client.reportExport(caseID: "case-1", evidenceIDs: ["evidence-2", "evidence-1"], format: "json",
            alertID: "alert-1", caseDetail: caseDetail(readOnly: true, enabledAction: false, organizationID: "org-1"),
            snapshot: snapshot, currentSettings: settings)

        XCTAssertEqual(report["schemaVersion"]?.stringValue, "analyst.case_export.v1")
        XCTAssertEqual(requests.count, 1)
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains { $0.name == "report" && $0.value == "true" })
        XCTAssertTrue(query.contains { $0.name == "format" && $0.value == "json" })
        XCTAssertEqual(query.filter { $0.name == "evidenceId" }.compactMap(\.value), ["evidence-1", "evidence-2"])
        XCTAssertEqual(query.first { $0.name == "organizationId" }?.value, "org-1")

        let stixClient = try DwmCaseWorkflowClient(settings: settings) { request in
            XCTAssertTrue(URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "format" && $0.value == "stix" } == true)
            return (self.reportExportResponse(format: "stix"), self.response(request))
        }
        let stixReport = try await stixClient.reportExport(caseID: "case-1", evidenceIDs: ["evidence-1", "evidence-2"], format: "stix",
            alertID: "alert-1", caseDetail: caseDetail(readOnly: true, enabledAction: false, organizationID: "org-1"),
            snapshot: snapshot, currentSettings: settings)
        XCTAssertEqual(stixReport["bundle"]?["type"]?.stringValue, "bundle")

        let mismatched = try DwmCaseWorkflowClient(settings: settings) { request in
            let body = String(data: self.reportExportResponse(format: "json"), encoding: .utf8)!.replacingOccurrences(of: "evidence-2", with: "evidence-3")
            return (Data(body.utf8), self.response(request))
        }
        do {
            _ = try await mismatched.reportExport(caseID: "case-1", evidenceIDs: ["evidence-1", "evidence-2"], format: "json",
                alertID: "alert-1", caseDetail: caseDetail(readOnly: true, enabledAction: false, organizationID: "org-1"),
                snapshot: snapshot, currentSettings: settings)
            XCTFail("A report for a different evidence selection must be rejected.")
        } catch { XCTAssertEqual(error as? DwmCaseWorkflowError, .malformedResponse) }

        do {
            _ = try await client.reportExport(caseID: "case-1", evidenceIDs: ["evidence-1", "not-loaded"], format: "json",
                alertID: "alert-1", caseDetail: caseDetail(readOnly: true, enabledAction: false, organizationID: "org-1"),
                snapshot: snapshot, currentSettings: settings)
            XCTFail("Evidence outside the loaded case snapshot must not be exported.")
        } catch { XCTAssertEqual(error as? DwmCaseWorkflowError, .invalidInput) }

        let oversized = try DwmCaseWorkflowClient(settings: settings) { request in
            (self.reportExportResponse(format: "json", paddingBytes: 256_001), self.response(request))
        }
        do {
            _ = try await oversized.reportExport(caseID: "case-1", evidenceIDs: ["evidence-1", "evidence-2"], format: "json",
                alertID: "alert-1", caseDetail: caseDetail(readOnly: true, enabledAction: false, organizationID: "org-1"),
                snapshot: snapshot, currentSettings: settings)
            XCTFail("An export above the API report size limit must be rejected.")
        } catch { XCTAssertEqual(error as? DwmCaseWorkflowError, .malformedResponse) }
    }

    func testNotificationIsDryRunAndRequiresDurableReceipt() async throws {
        let client = try DwmCaseWorkflowClient(settings: makeSettings()) { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertTrue(request.url!.path.hasSuffix("/customer-notification"))
            let body = try XCTUnwrap(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            XCTAssertEqual(body["deliveryMode"] as? String, "dry_run")
            XCTAssertNotNil(body["idempotencyKey"] as? String)
            return (Data(#"{"receipt":{"id":"notify-1"}}"#.utf8), self.response(request))
        }
        let receipt = try await client.notifyCustomerDryRun(caseID: "case-1", note: "Customer-safe summary", currentSettings: makeSettings(), caseDetail: caseDetail(readOnly: false, enabledAction: true))
        XCTAssertEqual(receipt["id"]?.stringValue, "notify-1")

        let malformed = try DwmCaseWorkflowClient(settings: makeSettings()) { request in
            (Data(#"{"receipt":{}}"#.utf8), self.response(request))
        }
        do {
            _ = try await malformed.notifyCustomerDryRun(caseID: "case-1", note: "Summary", currentSettings: makeSettings(), caseDetail: caseDetail(readOnly: false, enabledAction: true))
            XCTFail("Expected a missing receipt to be uncertain.")
        } catch { XCTAssertTrue(isUncertain(error)) }
    }

    func testReportRequiresCurrentPolicyAndSeparateLiveConfirmation() async throws {
        var settings = makeSettings(organization: "org-1")
        settings.selectedOrganizationUserID = settings.userID
        let detail = caseDetail(readOnly: false, enabledAction: true, organizationID: "org-1")
        var postBodies: [[String: Any]] = []
        let client = try DwmCaseWorkflowClient(settings: settings) { request in
            if request.httpMethod == "POST", let data = request.httpBody,
               let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { postBodies.append(body) }
            return (self.reportResponse(for: request), self.response(request))
        }

        do {
            _ = try await client.deliverReport(caseID: "case-1", evidenceIDs: ["evidence-1"], destinationID: "dest-1", alertID: "alert-1", dryRun: false, caseDetail: detail, currentSettings: settings)
            XCTFail("Live delivery must require a separate confirmation.")
        } catch { XCTAssertEqual(error as? DwmCaseWorkflowError, .invalidInput) }
        XCTAssertTrue(postBodies.isEmpty)

        let readonly = caseDetail(readOnly: true, enabledAction: true, organizationID: "org-1")
        do {
            _ = try await client.deliverReport(caseID: "case-1", evidenceIDs: ["evidence-1"], destinationID: "dest-1", alertID: "alert-1", dryRun: true, caseDetail: readonly, currentSettings: settings)
            XCTFail("A read-only case must block report delivery.")
        } catch { XCTAssertEqual(error as? DwmCaseWorkflowError, .invalidInput) }
        XCTAssertTrue(postBodies.isEmpty)

        let receipt = try await client.deliverReport(caseID: "case-1", evidenceIDs: ["evidence-1"], destinationID: "dest-1", alertID: "alert-1", dryRun: true, caseDetail: detail, currentSettings: settings)
        XCTAssertEqual(receipt["status"]?.stringValue, "dry_run")
        let body = try XCTUnwrap(postBodies.first)
        XCTAssertEqual(body["dryRun"] as? Bool, true)
        XCTAssertEqual(body["live"] as? Bool, false)
        XCTAssertEqual(body["caseId"] as? String, "case-1")
        XCTAssertEqual(body["destinationId"] as? String, "dest-1")
        XCTAssertEqual(body["evidenceIds"] as? [String], ["evidence-1"])

        let liveClient = try DwmCaseWorkflowClient(settings: settings) { request in
            (self.liveReportResponse(for: request), self.response(request))
        }
        let liveReceipt = try await liveClient.deliverReport(caseID: "case-1", evidenceIDs: ["evidence-1"], destinationID: "dest-1", alertID: "alert-1", dryRun: false, confirmedLive: true, caseDetail: detail, currentSettings: settings)
        XCTAssertEqual(liveReceipt["status"]?.stringValue, "delivered")
    }

    func testUnknownWriteOutcomeDoesNotRetryAndWrongReceiptIsRejected() async throws {
        var settings = makeSettings(organization: "org-1")
        settings.selectedOrganizationUserID = settings.userID
        var postCount = 0
        let uncertain = try DwmCaseWorkflowClient(settings: settings) { request in
            if request.httpMethod == "POST" { postCount += 1; throw URLError(.timedOut) }
            return (self.reportResponse(for: request), self.response(request))
        }
        do {
            _ = try await uncertain.deliverReport(caseID: "case-1", evidenceIDs: ["evidence-1"], destinationID: "dest-1", alertID: "alert-1", dryRun: true, caseDetail: caseDetail(readOnly: false, enabledAction: true, organizationID: "org-1"), currentSettings: settings)
            XCTFail("Expected uncertain outcome.")
        } catch { XCTAssertTrue(isUncertain(error)) }
        XCTAssertEqual(postCount, 1)

        let mismatched = try DwmCaseWorkflowClient(settings: settings) { request in
            let data = request.httpMethod == "POST"
                ? Data(#"{"deliveries":[{"id":"d-1","orgId":"org-other","alertId":"alert-1","reportCaseId":"case-1","destinationId":"dest-1","thirdPartyReport":true,"status":"dry_run"}]}"#.utf8)
                : self.reportResponse(for: request)
            return (data, self.response(request))
        }
        do {
            _ = try await mismatched.deliverReport(caseID: "case-1", evidenceIDs: ["evidence-1"], destinationID: "dest-1", alertID: "alert-1", dryRun: true, caseDetail: caseDetail(readOnly: false, enabledAction: true, organizationID: "org-1"), currentSettings: settings)
            XCTFail("Expected a cross-organization receipt to be rejected.")
        } catch { XCTAssertTrue(isUncertain(error)) }
    }

    func testLiveDelivery502KeepsDurableFailureReceiptAndUnreceipted5xxIsUncertain() async throws {
        var settings = makeSettings(organization: "org-1")
        settings.selectedOrganizationUserID = settings.userID
        let detail = caseDetail(readOnly: false, enabledAction: true, organizationID: "org-1")
        var postCount = 0
        let recordedFailure = try DwmCaseWorkflowClient(settings: settings) { request in
            if request.httpMethod == "POST" {
                postCount += 1
                return (Data(#"{"error":"Webhook delivery failed.","deliveries":[{"id":"d-failed","orgId":"org-1","alertId":"alert-1","reportCaseId":"case-1","destinationId":"dest-1","thirdPartyReport":true,"status":"failed","retryable":true,"retryDue":true,"nextRetryAt":"2026-10-24T12:00:00Z"}]}"#.utf8), self.response(request, statusCode: 502))
            }
            return (self.liveReportResponse(for: request), self.response(request))
        }

        let failure = try await recordedFailure.deliverReport(caseID: "case-1", evidenceIDs: ["evidence-1"], destinationID: "dest-1",
            alertID: "alert-1", dryRun: false, confirmedLive: true, caseDetail: detail, currentSettings: settings)
        XCTAssertEqual(failure["status"]?.stringValue, "failed")
        XCTAssertEqual(postCount, 1)

        let unreceipted = try DwmCaseWorkflowClient(settings: settings) { request in
            if request.httpMethod == "POST" {
                postCount += 1
                return (Data(#"{"error":"The delivery outcome could not be confirmed."}"#.utf8), self.response(request, statusCode: 503))
            }
            return (self.liveReportResponse(for: request), self.response(request))
        }
        do {
            _ = try await unreceipted.deliverReport(caseID: "case-1", evidenceIDs: ["evidence-1"], destinationID: "dest-1",
                alertID: "alert-1", dryRun: false, confirmedLive: true, caseDetail: detail, currentSettings: settings)
            XCTFail("An unreceipted post-dispatch 5xx must require reconciliation.")
        } catch { XCTAssertTrue(isUncertain(error)) }
        XCTAssertEqual(postCount, 2)

        let rejected = try DwmCaseWorkflowClient(settings: settings) { request in
            if request.httpMethod == "POST" {
                return (Data(#"{"error":"Forbidden."}"#.utf8), self.response(request, statusCode: 403))
            }
            return (self.liveReportResponse(for: request), self.response(request))
        }
        do {
            _ = try await rejected.deliverReport(caseID: "case-1", evidenceIDs: ["evidence-1"], destinationID: "dest-1",
                alertID: "alert-1", dryRun: false, confirmedLive: true, caseDetail: detail, currentSettings: settings)
            XCTFail("A request rejected by authorization must remain a known client error.")
        } catch { XCTAssertEqual(error as? DwmCaseWorkflowError, .requestFailed(403)) }
    }

    func testEvidenceLimitsAndScopeChangesBlockBeforeWrite() async throws {
        var settings = makeSettings(organization: "org-1")
        settings.selectedOrganizationUserID = settings.userID
        var writes = 0
        let client = try DwmCaseWorkflowClient(settings: settings) { request in
            if request.httpMethod == "POST" { writes += 1 }
            return (self.reportResponse(for: request), self.response(request))
        }
        let detail = caseDetail(readOnly: false, enabledAction: true, organizationID: "org-1")
        let tooMany = (1...26).map { "e\($0)" }
        do {
            _ = try await client.deliverReport(caseID: "case-1", evidenceIDs: tooMany, destinationID: "dest-1", alertID: "alert-1", dryRun: true, caseDetail: detail, currentSettings: settings)
            XCTFail("Expected evidence count limit.")
        } catch { XCTAssertEqual(error as? DwmCaseWorkflowError, .invalidInput) }
        var changed = settings; changed.selectedOrganizationID = "org-2"
        do {
            _ = try await client.deliverReport(caseID: "case-1", evidenceIDs: ["evidence-1"], destinationID: "dest-1", alertID: "alert-1", dryRun: true, caseDetail: detail, currentSettings: changed)
            XCTFail("Expected scope change to block the request.")
        } catch { XCTAssertEqual(error as? DwmCaseWorkflowError, .invalidInput) }
        XCTAssertEqual(writes, 0)
    }

    func testReconciliationUnlocksOnlyAfterMatchingReceiptAndRetryRequiresDueExactRow() throws {
        let notification = DwmCaseWorkflowReconciliation(kind: .notification, key: "notify-key")
        let base = DwmCaseWorkflowSnapshot(export: [:], destinations: [], deliveries: [], receiverReceipts: [],
            customerNotificationReceipts: [], organizationID: "org-1", alertID: "alert-1", canManageDestinations: true, liveDeliveryEnabled: true)
        XCTAssertFalse(notification.hasReceipt(in: base, caseID: "case-1"))
        let withReceipt = DwmCaseWorkflowSnapshot(export: [:], destinations: [], deliveries: [], receiverReceipts: [],
            customerNotificationReceipts: [["idempotencyKey": .string("notify-key")]], organizationID: "org-1", alertID: "alert-1",
            canManageDestinations: true, liveDeliveryEnabled: true)
        XCTAssertTrue(notification.hasReceipt(in: withReceipt, caseID: "case-1"))

        let retryRow: [String: IntelligenceCaseJSON] = [
            "id": .string("d-1"), "orgId": .string("org-1"), "alertId": .string("alert-1"),
            "reportCaseId": .string("case-1"), "thirdPartyReport": .bool(true), "dryRun": .bool(false),
            "status": .string("failed"), "retryable": .bool(true), "retryDue": .bool(true), "nextRetryAt": .string("2026-10-24T10:00:00Z"),
        ]
        let due = ISO8601DateFormatter().date(from: "2026-10-24T11:00:00Z")!
        XCTAssertNil(DwmCaseWorkflowSnapshot.retryBlock(retryRow, organizationID: "org-1", caseID: "case-1", alertID: "alert-1", now: due))
        var foreignRow = retryRow
        foreignRow["orgId"] = .string("org-other")
        XCTAssertNotNil(DwmCaseWorkflowSnapshot.retryBlock(foreignRow, organizationID: "org-1", caseID: "case-1", alertID: "alert-1", now: due))
        var noRetryDue = retryRow
        noRetryDue.removeValue(forKey: "retryDue")
        XCTAssertNotNil(DwmCaseWorkflowSnapshot.retryBlock(noRetryDue, organizationID: "org-1", caseID: "case-1", alertID: "alert-1", now: due))
        var notDue = retryRow
        notDue["retryDue"] = .bool(false)
        XCTAssertNotNil(DwmCaseWorkflowSnapshot.retryBlock(notDue, organizationID: "org-1", caseID: "case-1", alertID: "alert-1", now: due))
    }

    func testManualRetryPostsExactIdentityAndVerifiesRefreshedAttempt() async throws {
        var settings = makeSettings(organization: "org-1")
        settings.selectedOrganizationUserID = settings.userID
        var ledgerReads = 0
        var postedBody: [String: Any]?
        let client = try DwmCaseWorkflowClient(settings: settings) { request in
            if request.url?.path == "/api/dwm/webhook-deliveries" {
                if request.httpMethod == "POST" {
                    postedBody = try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any]
                    return (Data(#"{"deliveries":[{"id":"d-1","orgId":"org-1","alertId":"alert-1","reportCaseId":"case-1","destinationId":"dest-1","thirdPartyReport":true,"status":"delivered"}]}"#.utf8), self.response(request))
                }
                ledgerReads += 1
                let row = ledgerReads == 1
                    ? #"{"deliveryId":"d-1","orgId":"org-1","alertId":"alert-1","reportCaseId":"case-1","destinationId":"dest-1","thirdPartyReport":true,"dryRun":false,"status":"failed","retryable":true,"retryDue":true,"nextRetryAt":"2000-01-01T00:00:00Z","attemptCount":1,"attemptedAt":"2000-01-01T00:00:00Z"}"#
                    : #"{"deliveryId":"d-1","orgId":"org-1","alertId":"alert-1","reportCaseId":"case-1","destinationId":"dest-1","thirdPartyReport":true,"dryRun":false,"status":"delivered","retryable":false,"retryDue":false,"attemptCount":2,"attemptedAt":"2026-10-24T11:00:00Z"}"#
                return (Data("{\"deliveryLedger\":[\(row)],\"deliveryOperations\":{\"liveDeliveryEnabled\":true}}".utf8), self.response(request))
            }
            return (self.responseBody(for: request), self.response(request))
        }
        let failed: [String: IntelligenceCaseJSON] = [
            "deliveryId": .string("d-1"), "orgId": .string("org-1"), "alertId": .string("alert-1"),
            "reportCaseId": .string("case-1"), "destinationId": .string("dest-1"), "thirdPartyReport": .bool(true),
            "dryRun": .bool(false), "status": .string("failed"), "retryable": .bool(true), "retryDue": .bool(true),
            "nextRetryAt": .string("2000-01-01T00:00:00Z"), "attemptCount": .number(1), "attemptedAt": .string("2000-01-01T00:00:00Z"),
        ]
        let result = try await client.retryReport(delivery: failed, caseID: "case-1", alertID: "alert-1", currentSettings: settings)
        XCTAssertEqual(result["attemptCount"]?.numberValue, 2)
        XCTAssertEqual(postedBody?.keys.sorted(), ["deliveryId", "organizationId"])
        XCTAssertEqual(postedBody?["organizationId"] as? String, "org-1")
        XCTAssertEqual(postedBody?["deliveryId"] as? String, "d-1")
    }

    private func makeSettings(organization: String = "") -> HanasandDesktopSettings {
        var settings = HanasandDesktopSettings()
        settings.userID = "user-1"; settings.authToken = "test-token"
        settings.apiBaseURL = "https://api.example.test/api"
        settings.websiteBaseURL = "https://hanasand.com"
        settings.selectedOrganizationID = organization
        if !organization.isEmpty { settings.selectedOrganizationUserID = settings.userID }
        return settings
    }

    private func caseDetail(readOnly: Bool, enabledAction: Bool, organizationID: String = "") -> IntelligenceCaseDetailEnvelope {
        let actions = enabledAction ? #"[{"id":"assign","enabled":true,"method":"PATCH"}]"# : "[]"
        let tenantID = organizationID.isEmpty ? "user-1" : organizationID
        let json = Data("""
        {"case":{"id":"case-1","organizationId":"\(organizationID)","tenantId":"\(tenantID)"},"timeline":[],"evidence":[],"workflowActionPolicy":{"summary":{"readOnly":\(readOnly)},"actions":\(actions)},"access":{"readOnly":\(readOnly)},"alertContext":{"id":"alert-1"}}
        """.utf8)
        return try! JSONDecoder().decode(IntelligenceCaseDetailEnvelope.self, from: json)
    }

    private func responseBody(for request: URLRequest) -> Data {
        switch request.url?.path {
        case "/v1/cases/case-1/export": return Data(#"{"exportChecksum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","evidenceSummary":[{"id":"evidence-1","title":"Evidence"}],"copyText":"Case summary"}"#.utf8)
        case "/v1/cases/case-1": return Data(#"{"case":{"id":"case-1","tenantId":"org-1","organizationId":"org-1","customerNotifications":[]},"customerNotificationContext":{"ready":true}}"#.utf8)
        case "/api/dwm/webhook-destinations": return integrationBody()
        case "/api/organizations/org-1": return Data(#"{"organization":{"id":"org-1","lifecycleStatus":"active","privacyDeletionInProgress":false}}"#.utf8)
        case "/api/dwm/webhook-deliveries": return Data(#"{"deliveryLedger":[{"deliveryId":"d-1","orgId":"org-1","alertId":"alert-1","reportCaseId":"case-1","thirdPartyReport":true,"status":"delivered"}],"deliveryOperations":{"liveDeliveryEnabled":true}}"#.utf8)
        case "/api/findings/webhook-receiver": return Data(#"{"receipts":[{"id":"r-1","orgId":"org-1","reportCaseId":"case-1"}]}"#.utf8)
        default: return Data("{}".utf8)
        }
    }

    private func reportResponse(for request: URLRequest) -> Data {
        switch request.url?.path {
        case "/v1/dwm/alerts/alert-1": return Data(#"{"alert":{"id":"alert-1","severity":"high"}}"#.utf8)
        case "/v1/cases/case-1": return Data(#"{"case":{"id":"case-1","tenantId":"org-1","organizationId":"org-1"},"customerNotificationContext":{"ready":true},"workflowActionPolicy":{"summary":{"readOnly":false}}}"#.utf8)
        case "/v1/cases/case-1/export":
            if URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "report" }) == true {
                return Data(#"{"exportChecksum":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","reportPolicy":{"alertId":"alert-1"}}"#.utf8)
            }
            return Data(#"{"exportChecksum":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"}"#.utf8)
        case "/api/dwm/webhook-destinations": return integrationBody()
        case "/api/organizations/org-1": return Data(#"{"organization":{"id":"org-1","lifecycleStatus":"active","privacyDeletionInProgress":false}}"#.utf8)
        case "/api/dwm/webhook-deliveries":
            if request.httpMethod == "POST" {
                return Data(#"{"deliveries":[{"id":"d-1","orgId":"org-1","alertId":"alert-1","reportCaseId":"case-1","destinationId":"dest-1","thirdPartyReport":true,"status":"dry_run"}]}"#.utf8)
            }
            return Data(#"{"deliveryLedger":[],"deliveryOperations":{"liveDeliveryEnabled":true}}"#.utf8)
        default: return Data("{}".utf8)
        }
    }

    private func liveReportResponse(for request: URLRequest) -> Data {
        if request.httpMethod == "POST" {
            return Data(#"{"deliveries":[{"id":"d-2","orgId":"org-1","alertId":"alert-1","reportCaseId":"case-1","destinationId":"dest-1","thirdPartyReport":true,"status":"delivered"}]}"#.utf8)
        }
        if request.url?.path == "/api/dwm/webhook-deliveries" {
            return Data(#"{"deliveryLedger":[],"deliveryOperations":{"liveDeliveryEnabled":true}}"#.utf8)
        }
        return reportResponse(for: request)
    }

    private func integrationBody() -> Data {
        Data(#"{"destinations":[{"id":"dest-1","orgId":"org-1","name":"Receiver","kind":"webhook","status":"active"}],"destinationLifecycle":[],"destinationTests":[],"destinationAdminProof":{"access":{"canManage":true}}}"#.utf8)
    }

    private func reportExportResponse(format: String, paddingBytes: Int = 0) -> Data {
        let checksum = String(repeating: "b", count: 64)
        let policy: [String: Any] = [
            "direction": "outbound_third_party", "format": format == "stix" ? "stix-2.1" : "hanasand-json",
            "caseId": "case-1", "alertId": "alert-1", "organizationId": "org-1",
            "evidenceIds": ["evidence-1", "evidence-2"], "evidenceCount": 2, "exportChecksum": checksum,
        ]
        var report: [String: Any] = ["exportChecksum": checksum, "reportPolicy": policy]
        if format == "json" {
            report["schemaVersion"] = "analyst.case_export.v1"
            report["evidence"] = [["id": "evidence-1"], ["id": "evidence-2"]]
        } else {
            report["bundle"] = ["type": "bundle", "objects": [
                ["type": "identity"], ["type": "report"], ["type": "x-ti-evidence"], ["type": "x-ti-evidence"],
            ]]
            report["standardsValidation"] = ["standard": "STIX 2.1", "valid": true]
        }
        if paddingBytes > 0 { report["padding"] = String(repeating: "x", count: paddingBytes) }
        return try! JSONSerialization.data(withJSONObject: report, options: [.sortedKeys])
    }

    private func response(_ request: URLRequest, statusCode: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: request.url!, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func isUncertain(_ error: Error) -> Bool {
        guard let value = error as? DwmCaseWorkflowError else { return false }
        if case .uncertainOutcome(_) = value { return true }
        return false
    }
}
