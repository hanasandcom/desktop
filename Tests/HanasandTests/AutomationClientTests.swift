import Foundation
import XCTest
@testable import Hanasand

final class AutomationClientTests: XCTestCase {
    func testPersonalCronAndHealthUseTheAuthenticatedAutomationContract() async throws {
        var captured: URLRequest?
        let client = try AutomationClient(settings: settings()) { request in
            captured = request
            return self.response(#"{"canManageSystem":true,"automations":[]}"#, request)
        }

        let personal = try await client.list(scope: "personal")
        XCTAssertTrue(personal.automations.isEmpty)
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/automations?scope=personal")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Authorization"), "Bearer token-123")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "eirik")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Cache-Control"), "no-store")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "Cookie"))

        _ = try await client.list()
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/automations")
    }

    func testHealthDetailIncludesIssuesAndHistoryPagination() async throws {
        var captured: URLRequest?
        let client = try AutomationClient(settings: settings()) { request in
            captured = request
            return self.response(#"{"automation":{"id":"check-1","name":"Website","prompt":"available","actionType":"agent_prompt","monitoringType":"fetch","scheduleKind":"interval","intervalMinutes":5,"status":"active","uptime":99.5,"certificateStatus":"valid","history":[{"id":"run-1","status":"completed","warning":false,"started_at":"2026-10-23T10:00:00Z"}]},"runs":[{"id":"run-1","status":"completed","warning":false,"startedAt":"2026-10-23T10:00:00Z","caseNumber":"HA-1"}],"issues":[{"id":"issue-1","caseNumber":"HA-1","kind":"failure","summary":"Timed out","occurrences":2,"firstSeenAt":"2026-10-22T10:00:00Z","lastSeenAt":"2026-10-23T10:00:00Z","resolvedAt":null,"notifications":[]}],"total":51,"nextPage":2}"#, request)
        }

        let detail = try await client.detail(id: "check-1")
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/automations/check-1?page=1")
        XCTAssertEqual(detail.automation.uptime, 99.5)
        XCTAssertEqual(detail.automation.history.first?.startedAt, "2026-10-23T10:00:00Z")
        XCTAssertEqual(detail.issues.first?.caseNumber, "HA-1")
        XCTAssertEqual(detail.nextPage, 2)

        _ = try await client.detail(id: "check-1", page: 2)
        XCTAssertEqual(captured?.url?.absoluteString, "https://api.hanasand.test/api/automations/check-1?page=2")
    }

    func testMutationUsesExactRoutesAndRejectsImpersonationAndUnsafeIdentifiers() async throws {
        var requests: [URLRequest] = []
        let client = try AutomationClient(settings: settings()) { request in
            requests.append(request)
            let body = request.httpMethod == "POST" && request.url?.path.hasSuffix("/run") == true
                ? #"{"message":"queued"}"#
                : #"{"automation":{"id":"check-1","name":"Website","prompt":"available","actionType":"agent_prompt","monitoringType":"fetch","scheduleKind":"interval","status":"active"}}"#
            return self.response(body, request)
        }
        _ = try await client.setStatus("check-1", status: "paused")
        _ = try await client.delete("check-1")
        XCTAssertEqual(requests.map(\.httpMethod), ["PUT", "DELETE"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/automations/check-1", "/api/automations/check-1"])

        do { _ = try await client.delete("../check-1"); XCTFail("Unsafe path ids must be rejected") }
        catch AutomationClientError.invalidInput {}

        var impersonated = settings()
        impersonated.impersonationToken = "view-token"
        var sends = 0
        let readOnly = try AutomationClient(settings: impersonated) { request in
            sends += 1
            return self.response("{}", request)
        }
        do { _ = try await readOnly.run("check-1"); XCTFail("Impersonated accounts cannot start checks") }
        catch AutomationClientError.impersonationReadOnly {}
        XCTAssertEqual(sends, 0)
    }

    private func settings() -> HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.userID = "eirik"
        value.authToken = "token-123"
        value.apiBaseURL = "https://api.hanasand.test/api"
        return value
    }

    private func response(_ body: String, _ request: URLRequest) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }
}
