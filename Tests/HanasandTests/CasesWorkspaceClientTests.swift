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
    }

    func testMonitoringMergeUsesAuthenticatedBackendRouteAndSelectedOrganization() async throws {
        var captured: URLRequest?
        let client = try CasesWorkspaceClient(settings: makeSettings(organization: "org-9")) { request in
            captured = request
            return (Data("{}".utf8), self.response(for: request.url!))
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
}
