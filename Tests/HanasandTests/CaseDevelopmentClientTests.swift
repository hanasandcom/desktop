import Foundation
import XCTest

@testable import Hanasand

final class CaseDevelopmentClientTests: XCTestCase {
    func testLoadsCaseChangesAndRepositoriesUsingCurrentIdentityAndOrganization() async throws {
        let settings = makeSettings(organization: "org-7")
        var requests: [URLRequest] = []
        let client = try CaseDevelopmentClient(settings: settings) { request in
            requests.append(request)
            if request.url?.path == "/api/cases/development" {
                let body = #"{"items":[{"repository_id":"123e4567-e89b-12d3-a456-426614174000","kind":"commit","external_id":"0123456789abcdef0123456789abcdef01234567","title":"Repair case HA-12","url":"https://git.example.test/team/repo/commit/0123456789abcdef0123456789abcdef01234567","author":"Dev","state":"committed","branch":"main","updated_at":"2026-10-20T10:00:00Z","repository_url":"https://git.example.test/team/repo","provider":"forgejo"}],"hasMore":false}"#
                return (Data(body.utf8), self.response(for: request.url!))
            }
            let body = #"{"items":[{"id":"123e4567-e89b-12d3-a456-426614174000","provider":"forgejo","repository_url":"https://git.example.test/team/repo","organization_id":"org-7","can_manage":true,"last_received_at":null,"last_warning":null}]}"#
            return (Data(body.utf8), self.response(for: request.url!))
        }

        let page = try await client.load(caseID: "HA-12", organizationID: "org-7")
        let repositories = try await client.loadRepositories(organizationID: "org-7")

        XCTAssertEqual(page.items.first?.title, "Repair case HA-12")
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(repositories.first?.repositoryURL, "https://git.example.test/team/repo")
        XCTAssertEqual(requests.map(\.url?.path), ["/api/cases/development", "/api/cases/repositories"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer test-token" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "id") == "user-1" })
        XCTAssertTrue(requests.allSatisfy { $0.httpShouldHandleCookies == false })
        XCTAssertTrue(requests.allSatisfy { URLComponents(url: $0.url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(where: { $0.name == "organizationId" && $0.value == "org-7" }) == true })
    }

    func testCommitSearchAndLinkUseCursorAndReceiptContract() async throws {
        let settings = makeSettings()
        var requests: [URLRequest] = []
        let client = try CaseDevelopmentClient(settings: settings) { request in
            requests.append(request)
            let responseBody = request.httpMethod == "POST" ? #"{"ok":true}"# : #"{"items":[{"external_id":"0123456789abcdef0123456789abcdef01234567","title":"Repair","author":"Dev","updated_at":"2026-10-20T10:00:00Z"}],"nextCursor":null}"#
            return (Data(responseBody.utf8), self.response(for: request.url!))
        }

        let page = try await client.loadCommits(repositoryID: "123e4567-e89b-12d3-a456-426614174000", search: "Repair", cursor: "abcdefabcdefabcdefabcdefabcdefabcdefabcd")
        try await client.link(commit: "0123456789abcdef0123456789abcdef01234567", repositoryID: "123e4567-e89b-12d3-a456-426614174000", caseID: "HA-12")

        XCTAssertEqual(page.items.first?.author, "Dev")
        XCTAssertEqual(requests[0].url?.path, "/api/cases/development/commits")
        let query = URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        XCTAssertTrue(query.contains(where: { $0.name == "search" && $0.value == "Repair" }))
        XCTAssertTrue(query.contains(where: { $0.name == "cursor" && $0.value == "abcdefabcdefabcdefabcdefabcdefabcdefabcd" }))
        XCTAssertEqual(requests[1].httpMethod, "POST")
        let body = try XCTUnwrap(requests[1].httpBody)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(object["caseId"], "HA-12")
        XCTAssertEqual(object["repositoryId"], "123e4567-e89b-12d3-a456-426614174000")
    }

    func testConnectShowsOnlyValidatedOneTimeWebhookReceiptAndDisconnectRequiresReceipt() async throws {
        var captured: URLRequest?
        let client = try CaseDevelopmentClient(settings: makeSettings()) { request in
            captured = request
            let body = request.httpMethod == "POST" ? #"{"id":"123e4567-e89b-12d3-a456-426614174000","secret":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","webhookPath":"/api/cases/repository-events/123e4567-e89b-12d3-a456-426614174000"}"# : #"{"ok":true}"#
            return (Data(body.utf8), self.response(for: request.url!))
        }

        let setup = try await client.connect(provider: "forgejo", repositoryURL: "https://git.example.test/team/repo")
        XCTAssertEqual(setup.secret.count, 64)
        XCTAssertEqual(captured?.httpMethod, "POST")
        XCTAssertEqual(captured?.url?.path, "/api/cases/repositories")
        try await client.disconnect(repositoryID: setup.id)
        XCTAssertEqual(captured?.httpMethod, "DELETE")
    }

    func testRejectsUnsafeInputsAndUncertainMutationsAreLockedForReview() async throws {
        let client = try CaseDevelopmentClient(settings: makeSettings()) { _ in
            XCTFail("Unsafe repository URLs must not be sent")
            throw CaseDevelopmentClientError.invalidInput
        }
        do {
            _ = try await client.connect(provider: "github", repositoryURL: "http://git.example.test/team/repo")
            XCTFail("Expected insecure URL rejection")
        } catch let error as CaseDevelopmentClientError { XCTAssertEqual(error, .invalidInput) }

        XCTAssertTrue(CaseDevelopmentMutationOutcome.needsReview(afterDispatch: true, error: .transport))
        XCTAssertTrue(CaseDevelopmentMutationOutcome.needsReview(afterDispatch: true, error: .invalidResponse))
        XCTAssertTrue(CaseDevelopmentMutationOutcome.needsReview(afterDispatch: true, error: .requestFailed(503)))
        XCTAssertFalse(CaseDevelopmentMutationOutcome.needsReview(afterDispatch: true, error: .requestFailed(409)))
        XCTAssertFalse(CaseDevelopmentMutationOutcome.needsReview(afterDispatch: false, error: .transport))
    }

    private func makeSettings(organization: String = "") -> HanasandDesktopSettings {
        var settings = HanasandDesktopSettings()
        settings.apiBaseURL = "https://api.hanasand.com/api"
        settings.userID = "user-1"
        settings.authToken = "test-token"
        settings.selectedOrganizationID = organization
        return settings
    }

    private func response(for url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}
