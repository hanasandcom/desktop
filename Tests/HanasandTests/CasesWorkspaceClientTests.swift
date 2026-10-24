import Foundation
import XCTest

@testable import Hanasand

final class CasesWorkspaceClientTests: XCTestCase {
    func testManualCaseCreationUsesAuthenticatedTIContractAndOrganizationScope() async throws {
        var captured: URLRequest?
        let client = try CasesWorkspaceClient(settings: makeSettings(organization: "org-7")) { request in
            captured = request
            return (Data(#"{"case":{"id":"case-71"}}"#.utf8), self.response(for: request.url!))
        }

        let caseID = try await client.create(title: "  Review alert  ", summary: "Context", severity: "high",
                                             idempotencyKey: "123e4567-e89b-12d3-a456-426614174000")

        XCTAssertEqual(caseID, "case-71")
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.host, "ti.hanasand.com")
        XCTAssertEqual(captured?.url?.path, "/v1/cases")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.name, "organizationId")
        let body = try XCTUnwrap(captured?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["sourceType"] as? String, "manual")
        XCTAssertEqual(object["title"] as? String, "Review alert")
        XCTAssertEqual(object["organizationId"] as? String, "org-7")
        XCTAssertEqual(object["idempotencyKey"] as? String, "123e4567-e89b-12d3-a456-426614174000")
    }

    func testMonitoringMergeUsesAuthenticatedBackendRouteAndSelectedOrganization() async throws {
        var captured: URLRequest?
        let client = try CasesWorkspaceClient(settings: makeSettings(organization: "org-9")) { request in
            if request.httpMethod == "GET" {
                let id = request.url!.lastPathComponent
                return (self.monitoringCaseDetail(id: id), self.response(for: request.url!))
            }
            captured = request
            return (Data(#"{"ok":true,"targetId":"HA-1","mergedIds":["HA-2","MON-3"]}"#.utf8), self.response(for: request.url!))
        }

        try await client.merge(targetID: "HA-1", sourceIDs: ["HA-2", "MON-3"])

        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.host, "api.hanasand.com")
        XCTAssertEqual(captured?.url?.path, "/api/cases/monitoring/merge")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
        XCTAssertEqual(URLComponents(url: captured!.url!, resolvingAgainstBaseURL: false)?.queryItems?.first?.value, "org-9")
        let body = try XCTUnwrap(captured?.httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["targetId"] as? String, "HA-1")
        XCTAssertEqual(Set(object["sourceIds"] as? [String] ?? []), ["HA-2", "MON-3"])
    }

    func testMergeRejectsNonMonitoringIDsBeforeRequest() async throws {
        let client = try CasesWorkspaceClient(settings: makeSettings()) { _ in
            XCTFail("Invalid case IDs must not reach the API")
            throw CasesWorkspaceError.invalidInput
        }
        do {
            try await client.merge(targetID: "case-1", sourceIDs: ["HA-2"])
            XCTFail("Expected invalid monitoring case IDs to be rejected")
        } catch let error as CasesWorkspaceError {
            XCTAssertEqual(error, .invalidInput)
        }
    }

    func testMergeRejectsUnverifiedReceipt() async throws {
        let client = try CasesWorkspaceClient(settings: makeSettings()) { request in
            let body = request.httpMethod == "GET" ? self.monitoringCaseDetail(id: request.url!.lastPathComponent) : Data("{}".utf8)
            return (body, self.response(for: request.url!))
        }
        do {
            try await client.merge(targetID: "HA-1", sourceIDs: ["HA-2"])
            XCTFail("Expected the unverified merge receipt to be rejected")
        } catch let error as CasesWorkspaceError {
            XCTAssertEqual(error, .invalidResponse)
            XCTAssertTrue(CasesWorkspaceMutationOutcome.needsReview(for: error))
        }
    }

    func testMergeRechecksCurrentCaseOwnershipBeforeWriting() async throws {
        var mergeWasSent = false
        let client = try CasesWorkspaceClient(settings: makeSettings()) { request in
            if request.httpMethod == "POST" { mergeWasSent = true }
            let data = request.httpMethod == "GET"
                ? self.monitoringCaseDetail(id: request.url!.lastPathComponent, canManage: false)
                : Data(#"{"ok":true,"targetId":"HA-1","mergedIds":["HA-2"]}"#.utf8)
            return (data, self.response(for: request.url!))
        }
        do {
            try await client.merge(targetID: "HA-1", sourceIDs: ["HA-2"])
            XCTFail("Expected stale or unmanageable cases to be rejected")
        } catch let error as CasesWorkspaceError {
            XCTAssertEqual(error, .preflightFailed("Refresh and select current manageable cases from the same health check and workspace."))
        }
        XCTAssertFalse(mergeWasSent)
    }

    func testRepeatedCreateUsesSameIdempotencyKeyForRetry() async throws {
        var keys: [String] = []
        let client = try CasesWorkspaceClient(settings: makeSettings()) { request in
            let object = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            keys.append(object["idempotencyKey"] as! String)
            return (Data(#"{"case":{"id":"case-71"}}"#.utf8), self.response(for: request.url!))
        }
        let idempotencyKey = "123e4567-e89b-12d3-a456-426614174000"

        _ = try await client.create(title: "Review alert", summary: "Context", severity: "high", idempotencyKey: idempotencyKey)
        _ = try await client.create(title: "Review alert", summary: "Context", severity: "high", idempotencyKey: idempotencyKey)

        XCTAssertEqual(keys, [idempotencyKey, idempotencyKey])
    }

    func testMutationOutcomeRequiresReviewForPotentiallyDispatchedUnknownResults() {
        XCTAssertTrue(CasesWorkspaceMutationOutcome.needsReview(for: CasesWorkspaceError.transport))
        XCTAssertTrue(CasesWorkspaceMutationOutcome.needsReview(for: CasesWorkspaceError.invalidResponse))
        XCTAssertTrue(CasesWorkspaceMutationOutcome.needsReview(for: CasesWorkspaceError.requestFailed(408)))
        XCTAssertTrue(CasesWorkspaceMutationOutcome.needsReview(for: CasesWorkspaceError.requestFailed(503)))
        XCTAssertFalse(CasesWorkspaceMutationOutcome.needsReview(for: CasesWorkspaceError.requestFailed(403)))
        XCTAssertFalse(CasesWorkspaceMutationOutcome.needsReview(for: CasesWorkspaceError.invalidInput))
    }

    func testUncertainWriteRemainsLockedUntilBothSourcesRefreshAndUserAcknowledges() {
        var review = CasesWorkspaceMutationReview()
        review.requireReview(for: "Merge monitoring cases")
        XCTAssertTrue(review.isLocked)
        XCTAssertFalse(review.canAcknowledge)
        XCTAssertFalse(review.acknowledge())

        review.recordRefresh(monitoringLoaded: true, intelligenceLoaded: false)
        XCTAssertFalse(review.canAcknowledge)
        review.recordRefresh(monitoringLoaded: true, intelligenceLoaded: true)
        XCTAssertTrue(review.canAcknowledge)
        XCTAssertTrue(review.acknowledge())
        XCTAssertFalse(review.isLocked)
    }

    func testMonitoringListRequestCarriesSelectedOrganization() async throws {
        var captured: URLRequest?
        let client = try CasesWorkspaceClient(settings: makeSettings(organization: "org-7")) { request in
            captured = request
            return (Data(#"{"items":[]}"#.utf8), self.response(for: request.url!))
        }
        _ = try await client.loadMonitoringCases()
        let query = URLComponents(url: try XCTUnwrap(captured?.url), resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertEqual(query.first(where: { $0.name == "organizationId" })?.value, "org-7")
    }

    private func makeSettings(organization: String = "") -> HanasandDesktopSettings {
        var settings = HanasandDesktopSettings()
        settings.websiteBaseURL = "https://hanasand.com"
        settings.userID = "user-1"
        settings.authToken = "test-token"
        settings.selectedOrganizationID = organization
        return settings
    }

    private func response(for url: URL) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }

    private func monitoringCaseDetail(id: String, canManage: Bool = true) -> Data {
        let canonicalID = id.replacingOccurrences(of: "MON-", with: "HA-")
        return Data("""
        {"case":{"id":"\(canonicalID)","source":"monitoring","organizationId":null,"status":"open","severity":"high","canManage":\(canManage),"automationId":"automation-1","occurrences":1,"notificationsEnabled":true}}
        """.utf8)
    }
}
