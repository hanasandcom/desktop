import Foundation
import XCTest
@testable import Hanasand

private struct ThreatDeliveryProofSigner: DesktopDeviceProofSigning {
    let publicJWK = [
        "kty": "EC",
        "crv": "P-256",
        "x": String(repeating: "A", count: 43),
        "y": String(repeating: "B", count: 43),
    ]

    func signES256(_ message: Data) throws -> Data {
        Data(repeating: 0x5a, count: 64)
    }
}

final class ThreatDeliveryHistoryTests: XCTestCase {
    func testClientRequestsSelectedOrganizationWithoutCookiesOrWrites() async throws {
        var settings = makeSettings()
        settings.selectedOrganizationID = "org-123"
        settings.selectedOrganizationUserID = settings.userID
        var captured: [URLRequest] = []
        let signer = ThreatDeliveryProofSigner()
        let client = try ThreatDeliveryHistoryClient(settings: settings, proofSigner: signer) { request in
            captured.append(request)
            return (self.payload(organizationID: "org-123"), self.response(status: 200))
        }

        let result = try await client.load()

        XCTAssertEqual(result.organizationID, "org-123")
        XCTAssertEqual(result.deliveries.count, 1)
        let historyRequest = try XCTUnwrap(captured.first { $0.url?.path.hasSuffix("/dwm/webhook-deliveries") == true })
        XCTAssertEqual(historyRequest.httpMethod, "GET")
        XCTAssertEqual(URLComponents(url: historyRequest.url!, resolvingAgainstBaseURL: false)?.queryItems,
                       [URLQueryItem(name: "orgId", value: "org-123")])
        XCTAssertGreaterThanOrEqual(captured.count, 2)
        XCTAssertTrue(captured.allSatisfy { $0.httpMethod == "GET" && $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        XCTAssertTrue(captured.allSatisfy { $0.value(forHTTPHeaderField: "id") == "user-1" && $0.httpShouldHandleCookies == false })
        XCTAssertTrue(captured.allSatisfy { $0.value(forHTTPHeaderField: "Cache-Control") == "no-store" })
        XCTAssertTrue(captured.contains { $0.url?.host == "hanasand.com" && $0.url?.path == "/api/findings/alerts" })
        for request in captured {
            try assertDeviceProof(request, signer: signer)
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-device-proof-method"), "GET")
            XCTAssertEqual(dpopClaims(for: request)?["htm"] as? String, "GET")
        }
        let historyProof = try XCTUnwrap(captured.first { $0.url?.path.hasSuffix("/dwm/webhook-deliveries") == true })
        XCTAssertEqual(dpopClaims(for: historyProof)?["htu"] as? String,
                       "https://api.example.test/api/dwm/webhook-deliveries")
    }

    func testWebhookPostTransportSignsWithInjectedDeviceProof() async throws {
        var settings = makeSettings()
        settings.selectedOrganizationID = "org-123"
        settings.selectedOrganizationUserID = settings.userID
        var captured: URLRequest?
        let signer = ThreatDeliveryProofSigner()
        let client = try ThreatDeliveryHistoryClient(settings: settings, proofSigner: signer) { request in
            captured = request
            return (Data("{}".utf8), self.response(status: 200))
        }
        var request = URLRequest(url: URL(string: "https://api.example.test/api/dwm/webhook-deliveries")!)
        request.httpMethod = "POST"
        request.setValue("Bearer test-token", forHTTPHeaderField: "Authorization")
        request.setValue("user-1", forHTTPHeaderField: "id")

        _ = try await client.sendWrite(request, scopeIsCurrent: { true })

        let signedRequest = try XCTUnwrap(captured)
        try assertDeviceProof(signedRequest, signer: signer)
        XCTAssertEqual(signedRequest.httpMethod, "POST")
        XCTAssertEqual(signedRequest.value(forHTTPHeaderField: "x-device-proof-method"), "POST")
        XCTAssertEqual(dpopClaims(for: signedRequest)?["htm"] as? String, "POST")
        XCTAssertEqual(dpopClaims(for: signedRequest)?["htu"] as? String,
                       "https://api.example.test/api/dwm/webhook-deliveries")
    }

    func testFindingsFetchNeverSendsCredentialsToUntrustedWebsiteOrigin() async throws {
        var settings = makeSettings()
        settings.websiteBaseURL = "https://attacker.example.test"
        settings.selectedOrganizationID = "org-123"
        settings.selectedOrganizationUserID = settings.userID
        var captured: [URLRequest] = []
        let client = try ThreatDeliveryHistoryClient(settings: settings, proofSigner: ThreatDeliveryProofSigner()) { request in
            captured.append(request)
            return (self.payload(organizationID: "org-123"), self.response(status: 200))
        }

        do {
            _ = try await client.load()
            XCTFail("An untrusted findings origin must not be contacted.")
        } catch {
            XCTAssertEqual(error as? ThreatDeliveryHistoryError, .requestFailed(0))
        }

        XCTAssertFalse(captured.contains { $0.url?.host == "attacker.example.test" })
        XCTAssertTrue(captured.allSatisfy { $0.value(forHTTPHeaderField: "dpop") != nil })
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

        let denied = try ThreatDeliveryHistoryClient(settings: settings, proofSigner: ThreatDeliveryProofSigner()) { _ in
            (self.payload(organizationID: "org-123", allowed: false), self.response(status: 200))
        }
        do {
            _ = try await denied.load()
            XCTFail("Expected denied visibility to fail.")
        } catch { XCTAssertTrue(error is ThreatDeliveryHistoryError) }

        let crossOrg = try ThreatDeliveryHistoryClient(settings: settings, proofSigner: ThreatDeliveryProofSigner()) { _ in
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

    func testDestinationsHandoffKeepsTheActiveOrganizationScope() throws {
        XCTAssertEqual(ThreatDeliveryDestinationsRoute.make(organizationID: "org-123"),
                       ThreatDeliveryDestinationsRoute(path: "/integrations", query: ["organizationId": "org-123"]))
        XCTAssertNil(ThreatDeliveryDestinationsRoute.make(organizationID: "personal"))
        XCTAssertNil(ThreatDeliveryDestinationsRoute.make(organizationID: "org/123"))
    }

    func testActionGatesRequireScopedFindingAndEligibleFailedLiveReceipt() {
        let finding = ThreatDeliveryHistory.Finding(id: "alert-1", title: "Acme", actor: "actor", matchedTerm: "acme",
            reviewState: "needs_review", deliveryState: "pending", caseID: "HA-1", organizationID: "org-1", full: ["id": "alert-1"])
        var failed = attempt(id: "delivery-1", status: .failed, dryRun: false, organizationID: "org-1")
        failed.retryEligible = true
        var page = ThreatDeliveryHistory(deliveries: [failed], organizationID: "org-1")
        page.findings = [finding]
        page.canTest = true; page.canSend = true; page.canRetry = true

        XCTAssertTrue(ThreatDeliveryHistory.actionAllowed(.test, page: page, finding: finding))
        XCTAssertTrue(ThreatDeliveryHistory.actionAllowed(.send, page: page, finding: finding))
        XCTAssertTrue(ThreatDeliveryHistory.actionAllowed(.retry, page: page, attempt: failed))

        let foreign = ThreatDeliveryHistory.Finding(id: finding.id, title: finding.title, actor: finding.actor, matchedTerm: finding.matchedTerm,
            reviewState: finding.reviewState, deliveryState: finding.deliveryState, caseID: finding.caseID,
            organizationID: "org-other", full: finding.full)
        XCTAssertFalse(ThreatDeliveryHistory.actionAllowed(.send, page: page, finding: foreign))
        var dryRun = attempt(id: "delivery-dry", status: .failed, dryRun: true, organizationID: "org-1")
        dryRun.retryEligible = true
        page.deliveries = [dryRun]
        XCTAssertFalse(ThreatDeliveryHistory.actionAllowed(.retry, page: page, attempt: dryRun))
        page.canSend = false
        XCTAssertFalse(ThreatDeliveryHistory.actionAllowed(.send, page: page, finding: finding))
    }

    func testActionPayloadsPreserveFindingAndKeepRetryToReceiptReference() throws {
        let finding = ThreatDeliveryHistory.Finding(id: "alert-1", title: "Acme", actor: "actor", matchedTerm: "acme",
            reviewState: "needs_review", deliveryState: "pending", caseID: "HA-1", organizationID: "org-1",
            full: ["id": "alert-1", "sourceFamily": "threat", "serverField": "preserved"])
        var failed = attempt(id: "delivery-1", status: .failed, dryRun: false, organizationID: "org-1")
        failed.retryEligible = true
        var page = ThreatDeliveryHistory(deliveries: [failed], organizationID: "org-1")
        page.findings = [finding]; page.canTest = true; page.canSend = true; page.canRetry = true

        let test = try ThreatDeliveryHistoryClient.actionPayload(.test, page: page, finding: finding)
        XCTAssertEqual(test["dryRun"] as? Bool, true)
        XCTAssertEqual(test["live"] as? Bool, false)
        XCTAssertEqual((test["alert"] as? [String: Any])?["serverField"] as? String, "preserved")
        let send = try ThreatDeliveryHistoryClient.actionPayload(.send, page: page, finding: finding)
        XCTAssertEqual(send["dryRun"] as? Bool, false)
        XCTAssertEqual(send["live"] as? Bool, true)
        let retry = try ThreatDeliveryHistoryClient.actionPayload(.retry, page: page, attempt: failed)
        XCTAssertEqual(retry["deliveryId"] as? String, "delivery-1")
        XCTAssertNil(retry["alert"])
        XCTAssertNil(retry["alertId"])
        page.canSend = false
        XCTAssertThrowsError(try ThreatDeliveryHistoryClient.actionPayload(.send, page: page, finding: finding))

        var refreshedPage = page
        refreshedPage.canRetry = true
        let currentDelivered = attempt(id: "delivery-1", status: .delivered, dryRun: false, organizationID: "org-1")
        refreshedPage.deliveries = [currentDelivered]
        XCTAssertThrowsError(try ThreatDeliveryHistoryClient.actionPayload(.retry, page: refreshedPage, attempt: failed),
                             "A stale failed UI receipt must not override its now-delivered current record.")

        var wrongAlert = attempt(id: "delivery-1", status: .failed, dryRun: false, organizationID: "org-1", alertID: "another-alert")
        wrongAlert.retryEligible = true
        refreshedPage.deliveries = [wrongAlert]
        XCTAssertThrowsError(try ThreatDeliveryHistoryClient.actionPayload(.retry, page: refreshedPage, attempt: failed),
                             "Retry must resolve the same delivery ID and alert ID in the fresh page.")
    }

    func testSendAndTestRequireTheSelectedFindingToMatchFreshConfirmationState() throws {
        let selected = ThreatDeliveryHistory.Finding(id: "alert-1", title: "Acme", actor: "actor", matchedTerm: "acme",
            reviewState: "needs_review", deliveryState: "pending", caseID: "HA-1", organizationID: "org-1", full: ["id": "alert-1"])
        var page = ThreatDeliveryHistory(deliveries: [], organizationID: "org-1")
        page.canTest = true
        page.canSend = true

        page.findings = [selected]
        XCTAssertNoThrow(try ThreatDeliveryHistoryClient.actionPayload(.send, page: page, finding: selected))

        let changedDeliveryState = ThreatDeliveryHistory.Finding(id: selected.id, title: selected.title, actor: selected.actor,
            matchedTerm: selected.matchedTerm, reviewState: selected.reviewState, deliveryState: "muted",
            caseID: selected.caseID, organizationID: selected.organizationID, full: ["id": selected.id, "deliveryState": "muted"])
        page.findings = [changedDeliveryState]
        XCTAssertThrowsError(try ThreatDeliveryHistoryClient.actionPayload(.send, page: page, finding: selected),
                             "A confirmation must stop if the finding's delivery state changed during refresh.")
        XCTAssertThrowsError(try ThreatDeliveryHistoryClient.actionPayload(.test, page: page, finding: selected),
                             "Dry-run tests use the same fresh-finding confirmation guard.")

        let changedPayload = ThreatDeliveryHistory.Finding(id: selected.id, title: selected.title, actor: selected.actor,
            matchedTerm: selected.matchedTerm, reviewState: selected.reviewState, deliveryState: selected.deliveryState,
            caseID: selected.caseID, organizationID: selected.organizationID, full: ["id": selected.id, "evidence": ["new source"]])
        page.findings = [changedPayload]
        XCTAssertThrowsError(try ThreatDeliveryHistoryClient.actionPayload(.send, page: page, finding: selected),
                             "The refreshed API alert payload must match the payload the user selected.")
    }

    func testScopeChangeBlocksWriteAtFinalSendBoundary() async throws {
        var expectedSettings = makeSettings()
        expectedSettings.selectedOrganizationID = "org-123"
        expectedSettings.selectedOrganizationUserID = expectedSettings.userID
        var currentSettings = expectedSettings
        currentSettings.selectedOrganizationID = "org-456"
        var didSend = false
        let client = try ThreatDeliveryHistoryClient(settings: expectedSettings, proofSigner: ThreatDeliveryProofSigner()) { _ in
            didSend = true
            return (Data(), self.response(status: 200))
        }
        let request = URLRequest(url: URL(string: "https://api.example.test/api/dwm/webhook-deliveries")!)

        do {
            _ = try await client.sendWrite(request, scopeIsCurrent: {
                ThreatDeliveryHistoryClient.sameWriteScope(expectedSettings, currentSettings)
            })
            XCTFail("Expected changed organization scope to block the write.")
        } catch {
            XCTAssertEqual(error as? ThreatDeliveryHistoryError, .organizationScopeChanged)
        }
        XCTAssertFalse(didSend, "The POST transport must not run after the confirmed scope changes.")
        XCTAssertFalse(ThreatDeliveryHistoryClient.sameWriteScope(expectedSettings, currentSettings))
    }

    func testReloadIdentityChangesWithEveryDeliveryRequestScopeInput() {
        let baselineSettings = makeSettings()
        let baseline = ThreatDeliveryHistoryScopeIdentity(initialOrganizationID: nil, settings: baselineSettings)
        XCTAssertNotEqual(baseline, ThreatDeliveryHistoryScopeIdentity(initialOrganizationID: "org-deep-link", settings: baselineSettings))

        let mutations: [(String, (inout HanasandDesktopSettings) -> Void)] = [
            ("API endpoint", { $0.apiBaseURL = "https://api-next.example.test/api" }),
            ("website endpoint", { $0.websiteBaseURL = "https://next.example.test" }),
            ("organization", { $0.selectedOrganizationID = "org-next" }),
            ("organization user", { $0.selectedOrganizationUserID = "user-next" }),
            ("user", { $0.userID = "user-next" }),
            ("auth token", { $0.authToken = "next-token" }),
            ("impersonated user", { $0.impersonatingUserID = "user-next" }),
            ("impersonation token", { $0.impersonationToken = "next-token" })
        ]

        for (label, mutate) in mutations {
            var changedSettings = baselineSettings
            mutate(&changedSettings)
            XCTAssertNotEqual(baseline, ThreatDeliveryHistoryScopeIdentity(initialOrganizationID: nil, settings: changedSettings), label)
        }
    }

    func testWriteGateSerializesAndRequiresSuccessfulRefreshAfterAnyWrite() {
        var state = ThreatDeliveryReviewState()
        XCTAssertTrue(state.beginWrite())
        XCTAssertFalse(state.beginWrite())
        state.finishWrite()
        XCTAssertTrue(state.requiresRefresh)
        XCTAssertFalse(state.beginWrite())
        state.refreshSucceeded()
        XCTAssertFalse(state.requiresRefresh)
        XCTAssertTrue(state.beginWrite())
    }

    func testMalformedOrCrossScopeWriteReceiptIsUncertain() throws {
        let response = self.response(status: 502)
        let mismatched = Data(#"{"deliveries":[{"id":"delivery-1","orgId":"org-other","alertId":"alert-1","status":"failed","dryRun":false}]}"#.utf8)
        XCTAssertThrowsError(try ThreatDeliveryHistoryClient.validatedReceipts(data: mismatched, response: response,
            action: .send, organizationID: "org-1", alertID: "alert-1")) { error in
            XCTAssertEqual(error as? ThreatDeliveryHistoryError, .uncertainResult)
        }
        let missingReceipt = Data(#"{"error":"temporary failure"}"#.utf8)
        XCTAssertThrowsError(try ThreatDeliveryHistoryClient.validatedReceipts(data: missingReceipt, response: response,
            action: .send, organizationID: "org-1", alertID: "alert-1")) { error in
            XCTAssertEqual(error as? ThreatDeliveryHistoryError, .uncertainResult)
        }
    }

    func test502WithMatchedPersistedReceiptRemainsReviewable() throws {
        let data = Data(#"{"deliveries":[{"id":"delivery-1","orgId":"org-1","alertId":"alert-1","status":"failed","dryRun":false,"attemptCount":1}]}"#.utf8)
        let receipts = try ThreatDeliveryHistoryClient.validatedReceipts(data: data, response: response(status: 502),
            action: .send, organizationID: "org-1", alertID: "alert-1")
        XCTAssertEqual(receipts.count, 1)
        XCTAssertEqual(receipts[0].status, .failed)
    }

    private func attempt(id: String, status: ThreatDeliveryStatus, dryRun: Bool, organizationID: String,
                         alertID: String = "alert-1") -> ThreatDeliveryHistory.Attempt {
        let data = Data("""
        {"id":"\(id)","orgId":"\(organizationID)","alertId":"\(alertID)","status":"\(status.rawValue)","dryRun":\(dryRun)}
        """.utf8)
        return try! JSONDecoder().decode(ThreatDeliveryHistory.Attempt.self, from: data)
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

    private func assertDeviceProof(_ request: URLRequest, signer: ThreatDeliveryProofSigner,
                                   file: StaticString = #filePath, line: UInt = #line) throws {
        let expectedJWK = try JSONSerialization.data(withJSONObject: signer.publicJWK, options: [.sortedKeys])
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-device-public-jwk"), String(data: expectedJWK, encoding: .utf8), file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-device-proof-url"), DesktopDeviceProof.normalizedTarget(request.url!), file: file, line: line)
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-device-proof-method"), request.httpMethod, file: file, line: line)
        let jwt = try XCTUnwrap(request.value(forHTTPHeaderField: "dpop"), file: file, line: line)
        let parts = jwt.split(separator: ".")
        XCTAssertEqual(parts.count, 3, file: file, line: line)
        XCTAssertEqual(dpopClaims(for: request)?["htm"] as? String, request.httpMethod, file: file, line: line)
        XCTAssertNotNil(dpopClaims(for: request)?["ath"] as? String, file: file, line: line)
        XCTAssertEqual(dpopHeader(for: request)?["typ"] as? String, "dpop+jwt", file: file, line: line)
        XCTAssertEqual(dpopHeader(for: request)?["jwk"] as? [String: String], signer.publicJWK, file: file, line: line)
    }

    private func dpopClaims(for request: URLRequest) -> [String: Any]? {
        decodedJWTPart(request.value(forHTTPHeaderField: "dpop"), index: 1)
    }

    private func dpopHeader(for request: URLRequest) -> [String: Any]? {
        decodedJWTPart(request.value(forHTTPHeaderField: "dpop"), index: 0)
    }

    private func decodedJWTPart(_ jwt: String?, index: Int) -> [String: Any]? {
        guard let jwt else { return nil }
        let parts = jwt.split(separator: ".")
        guard parts.count == 3, parts.indices.contains(index) else { return nil }
        var encoded = String(parts[index]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
}
