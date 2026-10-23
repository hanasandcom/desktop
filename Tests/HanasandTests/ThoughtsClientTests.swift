import Foundation
import XCTest

@testable import Hanasand

final class ThoughtsClientTests: XCTestCase {
    private let apiBase = URL(string: "https://api.example.test/api")!

    func testLoadScopesOrganizationAndPersonalWorkspaceAndDecodesMarkdown() async throws {
        let payload = ##"[{"id":"42","title":"# First line\n\n- item","created_at":"2026-10-20"}]"##.data(using: .utf8)!
        var captured: URLRequest?
        let orgClient = try client(organizationID: "org-7") { request in
            captured = request
            return (payload, Self.response(request.url!, status: 200))
        }
        let thoughts = try await orgClient.load()
        XCTAssertEqual(captured?.url?.path, "/api/thoughts")
        XCTAssertEqual(captured?.url?.query, "organizationId=org-7")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "x-organization-id"), "org-7")
        XCTAssertEqual(thoughts.first?.markdownBody, "# First line\n\n- item")
        XCTAssertEqual(thoughts.first?.displayTitle, "# First line")

        let personalClient = try client { request in
            captured = request
            return (#"[]"#.data(using: .utf8)!, Self.response(request.url!, status: 200))
        }
        let personalThoughts = try await personalClient.load()
        XCTAssertTrue(personalThoughts.isEmpty)
        XCTAssertEqual(captured?.url?.query, "workspace=true")
        XCTAssertNil(captured?.value(forHTTPHeaderField: "x-organization-id"))
    }

    func testCreateAndUpdateSendMarkdownOnlyAsTitleAndRequireMatchingReceipts() async throws {
        let markdown = "## Thought\n\n**important**"
        var requests: [URLRequest] = []
        let createClient = try client { request in
            requests.append(request)
            return (Self.row(id: "42", title: markdown), Self.response(request.url!, status: 201))
        }
        let created = try await createClient.create(markdown: markdown)
        XCTAssertEqual(created.id, "42")
        XCTAssertEqual(requests[0].httpMethod, "POST")
        XCTAssertEqual(requests[0].url?.path, "/api/thoughts")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "id"), "user-1")
        XCTAssertNil(requests[0].httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }?["id"])
        XCTAssertEqual(try payload(requests[0]), ["title": markdown])

        let updateClient = try client { request in
            requests.append(request)
            let row = try JSONSerialization.jsonObject(with: Self.row(id: "42", title: markdown))
            let receipt = try JSONSerialization.data(withJSONObject: ["result": ["rows": [row]], "message": "Updated thought 42"])
            return (receipt, Self.response(request.url!, status: 201))
        }
        let updated = try await updateClient.update(id: "42", markdown: markdown)
        XCTAssertEqual(updated.title, markdown)
        XCTAssertEqual(requests[1].httpMethod, "PUT")
        XCTAssertEqual(requests[1].url?.path, "/api/thought/42")
        XCTAssertEqual(try payload(requests[1]), ["title": markdown])
    }

    func testMutationTransportFailureAndUnconfirmedReceiptAreMarkedUncertain() async throws {
        let transportFailure = try client { _ in throw URLError(.timedOut) }
        do {
            _ = try await transportFailure.create(markdown: "keep this draft")
            XCTFail("Expected uncertain mutation")
        } catch let error as ThoughtsClientError {
            XCTAssertTrue(error.isUncertain)
        }

        let badReceipt = try client { request in
            (Self.row(id: "42", title: "different text"), Self.response(request.url!, status: 201))
        }
        do {
            _ = try await badReceipt.create(markdown: "keep this draft")
            XCTFail("Expected unconfirmed receipt")
        } catch let error as ThoughtsClientError {
            XCTAssertEqual(error, .unconfirmedMutation)
            XCTAssertTrue(error.isUncertain)
        }
    }

    func testMutationSafetyBlocksRetryUntilRefreshAfterUncertainOutcome() {
        var state = ThoughtMutationSafety()
        XCTAssertTrue(state.mayRetry)
        state.recordFailure(ThoughtsClientError.requestFailed(409))
        XCTAssertTrue(state.mayRetry)
        state.recordFailure(ThoughtsClientError.requestFailed(503))
        XCTAssertFalse(state.mayRetry)
    }

    func testOnlyCurrentPostFailureRefreshForSameScopeClearsMutationGate() {
        var state = ThoughtMutationSafety()
        let originalLoadID = UUID()
        let inFlightBeforeFailure = state.beginRefresh(userID: "user-1", organizationID: "org-1", loadID: originalLoadID)
        state.recordFailure(ThoughtsClientError.uncertainMutation)
        XCTAssertEqual(state.generation, 1)

        state.recordSuccessfulRefresh(inFlightBeforeFailure, userID: "user-1", organizationID: "org-1", loadID: originalLoadID, isThoughtsPath: true)
        XCTAssertFalse(state.mayRetry, "A GET that began before the uncertain write must not clear the gate.")

        let freshLoadID = UUID()
        let postFailureRefresh = state.beginRefresh(userID: "user-1", organizationID: "org-1", loadID: freshLoadID)
        state.recordSuccessfulRefresh(postFailureRefresh, userID: "user-1", organizationID: "org-2", loadID: freshLoadID, isThoughtsPath: true)
        XCTAssertFalse(state.mayRetry, "A refresh for a different organization must not clear the gate.")
        state.recordSuccessfulRefresh(postFailureRefresh, userID: "user-1", organizationID: "org-1", loadID: UUID(), isThoughtsPath: true)
        XCTAssertFalse(state.mayRetry, "A superseded GET must not clear the gate.")
        state.recordSuccessfulRefresh(postFailureRefresh, userID: "user-1", organizationID: "org-1", loadID: freshLoadID, isThoughtsPath: false)
        XCTAssertFalse(state.mayRetry, "A response from a different route must not clear the gate.")

        state.recordSuccessfulRefresh(postFailureRefresh, userID: "user-1", organizationID: "org-1", loadID: freshLoadID, isThoughtsPath: true)
        XCTAssertTrue(state.mayRetry)
    }

    func testAccountSwitchWithPersonalScopeCannotSendOrAcceptOldRefresh() {
        var state = ThoughtMutationSafety()
        state.recordFailure(ThoughtsClientError.uncertainMutation)
        let loadID = UUID()
        let oldAccountRefresh = state.beginRefresh(userID: "user-1", organizationID: "", loadID: loadID)

        XCTAssertTrue(state.matchesCurrentRefresh(oldAccountRefresh, userID: "user-1", organizationID: "", loadID: loadID, isThoughtsPath: true))
        XCTAssertFalse(state.matchesCurrentRefresh(oldAccountRefresh, userID: "user-2", organizationID: "", loadID: loadID, isThoughtsPath: true),
                       "The load should be discarded before dispatch if the signed-in account changed.")
        state.recordSuccessfulRefresh(oldAccountRefresh, userID: "user-2", organizationID: "", loadID: loadID, isThoughtsPath: true)
        XCTAssertFalse(state.mayRetry, "A personal workspace response from the previous account must not clear the gate.")

        let newAccountRefresh = state.beginRefresh(userID: "user-2", organizationID: "", loadID: UUID())
        state.recordSuccessfulRefresh(newAccountRefresh, userID: "user-2", organizationID: "", loadID: newAccountRefresh.loadID, isThoughtsPath: true)
        XCTAssertTrue(state.mayRetry)
    }

    func testRejectsImpersonationAndEmptyMarkdownAndReportsDefiniteConflict() async throws {
        XCTAssertThrowsError(try ThoughtsClient(apiBaseURL: apiBase, userID: "user-1", token: "token", impersonationToken: "delegated")) {
            XCTAssertEqual($0 as? ThoughtsClientError, .impersonationUnsupported)
        }
        let client = try client { request in
            (Data(#"{"error":"Thought already exists"}"#.utf8), Self.response(request.url!, status: 409))
        }
        do {
            _ = try await client.create(markdown: " \n ")
            XCTFail("Expected empty Markdown rejection")
        } catch let error as ThoughtsClientError {
            XCTAssertEqual(error, .invalidMarkdown)
        }
        do {
            _ = try await client.create(markdown: "duplicate")
            XCTFail("Expected conflict")
        } catch let error as ThoughtsClientError {
            XCTAssertEqual(error, .requestFailed(409))
            XCTAssertFalse(error.isUncertain)
        }
    }

    private func client(organizationID: String = "", send: @escaping ThoughtsClient.Sender) throws -> ThoughtsClient {
        try ThoughtsClient(apiBaseURL: apiBase, userID: "user-1", token: "token-1", organizationID: organizationID, send: send)
    }

    private func payload(_ request: URLRequest) throws -> [String: String] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: String])
    }

    private static func row(id: String, title: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["id": id, "title": title, "created_at": "2026-10-20"])
    }

    private static func response(_ url: URL, status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
}
