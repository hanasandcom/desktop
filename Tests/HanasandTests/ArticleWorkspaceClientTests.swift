import Foundation
import XCTest
@testable import Hanasand

final class ArticleWorkspaceClientTests: XCTestCase {
    private func settings(organizationID: String = "") -> HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.apiBaseURL = "https://api.example.test/api"
        value.userID = "member-1"
        value.authToken = "token_abc-123"
        value.selectedOrganizationID = organizationID
        value.selectedOrganizationUserID = organizationID.isEmpty ? "" : "member-1"
        return value
    }

    private func client(organizationID: String = "", send: @escaping (URLRequest) async throws -> (Data, URLResponse)) throws -> ArticleWorkspaceClient {
        try ArticleWorkspaceClient(settings: settings(organizationID: organizationID), userID: "member-1", authToken: "token_abc-123", organizationID: organizationID, send: send)
    }

    private func response(_ json: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        (Data(json.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    func testArticleFilenameNormalizationPreservesDottedIDsAndRejectsPaths() throws {
        XCTAssertEqual(try ArticleWorkspacePolicy.articleID("notes.md"), "notes.md")
        XCTAssertEqual(try ArticleWorkspacePolicy.articleID("report.v2.md"), "report.v2.md")
        XCTAssertEqual(try ArticleWorkspacePolicy.articleID("release.notes"), "release.notes.md")
        for invalid in [".hidden.md", "../notes.md", "folder/notes.md", "a%2fb.md", String(repeating: "a", count: 198) + ".md"] {
            XCTAssertThrowsError(try ArticleWorkspacePolicy.articleID(invalid), "Expected \(invalid) to be rejected")
        }
    }

    func testRequestContextDetectsAccountAPIWorkspaceAndImpersonationChanges() {
        let original = settings(organizationID: "org-1")
        let context = ArticleWorkspaceRequestContext(
            settings: original,
            userID: "member-1",
            authToken: "token_abc-123",
            organizationID: "org-1"
        )
        XCTAssertTrue(context.matches(settings: original, userID: "member-1", authToken: "token_abc-123", organizationID: "org-1"))
        XCTAssertFalse(context.matches(settings: original, userID: "member-2", authToken: "token_abc-123", organizationID: "org-1"))
        XCTAssertFalse(context.matches(settings: original, userID: "member-1", authToken: "replacement", organizationID: "org-1"))

        var apiChanged = original
        apiChanged.apiBaseURL = "https://other.example.test/api"
        XCTAssertFalse(context.matches(settings: apiChanged, userID: "member-1", authToken: "token_abc-123", organizationID: "org-1"))

        var organizationChanged = original
        organizationChanged.selectedOrganizationID = "org-2"
        XCTAssertFalse(context.matches(settings: organizationChanged, userID: "member-1", authToken: "token_abc-123", organizationID: "org-1"))

        var impersonationChanged = original
        impersonationChanged.impersonationToken = "impersonation-token"
        impersonationChanged.impersonatingUserID = "target-user"
        XCTAssertFalse(context.matches(settings: impersonationChanged, userID: "member-1", authToken: "token_abc-123", organizationID: "org-1"))
    }

    func testListUsesWorkspaceQueryOptionalOrganizationHeaderAndValidatesRows() async throws {
        var organizationRequests: [URLRequest] = []
        let organizationClient = try client(organizationID: "org-1") { request in
            organizationRequests.append(request)
            return self.response(##"[{"id":"report.v2.md","organization_id":"org-1","title":"Workspace report","content":"# Report"}]"##, request: request)
        }
        let organizationRows = try await organizationClient.list()
        XCTAssertEqual(organizationRows.map(\.id), ["report.v2.md"])
        XCTAssertEqual(organizationRequests[0].url?.path, "/api/articles")
        XCTAssertEqual(organizationRequests[0].url?.query, "workspace=true")
        XCTAssertEqual(organizationRequests[0].value(forHTTPHeaderField: "x-organization-id"), "org-1")
        XCTAssertEqual(organizationRequests[0].value(forHTTPHeaderField: "Authorization"), "Bearer token_abc-123")

        var personalRequest: URLRequest?
        let personalClient = try client { request in
            personalRequest = request
            return self.response(#"[{"id":"notes.md","organization_id":null,"title":"Personal note"}]"#, request: request)
        }
        _ = try await personalClient.list()
        XCTAssertEqual(personalRequest?.url?.query, "workspace=true")
        XCTAssertNil(personalRequest?.value(forHTTPHeaderField: "x-organization-id"))

        let mixed = try client(organizationID: "org-1") { request in
            self.response(#"[{"id":"leaked.md","organization_id":null,"title":"Wrong workspace"}]"#, request: request)
        }
        do { _ = try await mixed.list(); XCTFail("Expected cross-workspace row rejection") }
        catch ArticleWorkspaceError.scopeChanged {}
    }

    func testCurrentOrganizationAccessRequiresActiveEditorialRoleAndPersonalUsesInternalAccess() async throws {
        var configured = settings(organizationID: "org-1")
        configured.apiBaseURL = "https://api.hanasand.com/api"
        var captured: URLRequest?
        let orgClient = try ArticleWorkspaceClient(settings: configured, userID: "member-1", authToken: "token_abc-123", organizationID: "org-1") { request in
            captured = request
            return self.response(#"{"organizations":[{"id":"org-1","name":"Workspace","lifecycleStatus":"active","role":"editor"}]}"#, request: request)
        }
        let organizationAccess = try await orgClient.loadAccess()
        XCTAssertTrue(organizationAccess.canWrite)
        XCTAssertEqual(captured?.url?.absoluteString, "https://identity.hanasand.com/api/organizations")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "id"), "member-1")
        XCTAssertFalse(ArticleWorkspacePolicy.canWriteOrganization(role: "reader", status: "active"))
        XCTAssertFalse(ArticleWorkspacePolicy.canWriteOrganization(role: "editor", status: "archived"))

        let personalClient = try client { request in
            XCTAssertEqual(request.url?.path, "/api/management/organizations")
            XCTAssertEqual(request.url?.query, "internalPages=1")
            return self.response(#"{"allowed":true,"canEdit":false}"#, request: request)
        }
        let personalAccess = try await personalClient.loadAccess()
        XCTAssertFalse(personalAccess.canWrite)
    }

    func testCreatePreflightAllowsOnly404AndNeverPostsOnExistingOrUnavailableID() async throws {
        var requests: [URLRequest] = []
        let absent = try client(organizationID: "org-1") { request in
            requests.append(request)
            return self.response(#"{"error":{"message":"Article does not exist"}}"#, request: request, status: 404)
        }
        try await absent.prepareCreate("notes.md")
        XCTAssertEqual(requests.map(\.httpMethod), ["GET"])
        XCTAssertEqual(requests[0].url?.path, "/api/article/notes.md")
        XCTAssertEqual(requests[0].value(forHTTPHeaderField: "x-organization-id"), "org-1")

        var existingRequests: [URLRequest] = []
        let exists = try client(organizationID: "org-1") { request in
            existingRequests.append(request)
            return self.response(##"{"id":"notes.md","organization_id":"org-1","title":"Existing","content":"# Existing"}"##, request: request)
        }
        do { try await exists.prepareCreate("notes.md"); XCTFail("Expected ID collision") }
        catch ArticleWorkspaceError.requestFailed(let status, _) { XCTAssertEqual(status, 409) }
        XCTAssertEqual(existingRequests.map(\.httpMethod), ["GET"])

        let unavailable = try client(organizationID: "org-1") { request in
            self.response(#"{"error":{"message":"Unavailable"}}"#, request: request, status: 503)
        }
        do { try await unavailable.prepareCreate("notes.md"); XCTFail("Expected uncertain preflight failure") }
        catch ArticleWorkspaceError.requestFailed(let status, _) { XCTAssertEqual(status, 503) }
    }

    func testCreateUsesScopedHeaderAndVerifiesExactReceipt() async throws {
        var requests: [URLRequest] = []
        let scoped = try client(organizationID: "org-1") { request in
            requests.append(request)
            if request.httpMethod == "GET" {
                return self.response(#"{"error":{"message":"Missing"}}"#, request: request, status: 404)
            }
            return self.response(#"{"created":true,"name":"report.v2.md"}"#, request: request, status: 201)
        }
        try await scoped.prepareCreate("report.v2.md")
        let access = ArticleWorkspaceAccess(organizationID: "org-1", canRead: true, canWrite: true)
        _ = try await scoped.mutate(.create, articleID: "report.v2.md", content: "# Report", original: nil, access: access)
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-organization-id") == "org-1" })
        XCTAssertEqual(requests[1].url?.path, "/api/article/report.v2.md")
        XCTAssertEqual(try XCTUnwrap(requests[1].httpBody).jsonObject["content"] as? String, "# Report")
    }

    func testUpdateAndDeleteStayInOriginalWorkspaceAndVerifyReceipts() async throws {
        var requests: [URLRequest] = []
        let scoped = try client(organizationID: "org-1") { request in
            requests.append(request)
            if request.httpMethod == "GET" {
                return self.response(##"{"id":"report.md","organization_id":"org-1","title":"Report","content":"# Current"}"##, request: request)
            }
            if request.httpMethod == "PUT" {
                return self.response(#"{"updated":true,"id":"report.md"}"#, request: request)
            }
            return self.response(#"{"deleted":true,"id":"report.md"}"#, request: request)
        }
        let original = DashboardArticle(
            id: "report.md", size: nil, created: nil, modified: nil, metadata: nil,
            title: "Report", content: "# Previous", organizationID: "org-1"
        )
        let access = ArticleWorkspaceAccess(organizationID: "org-1", canRead: true, canWrite: true)

        try await scoped.prepareExisting(original)
        _ = try await scoped.mutate(.update, articleID: original.id, content: "# Revised", original: original, access: access)
        try await scoped.prepareExisting(original)
        _ = try await scoped.mutate(.delete, articleID: original.id, content: nil, original: original, access: access)

        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "PUT", "GET", "DELETE"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "x-organization-id") == "org-1" })
        XCTAssertEqual(try XCTUnwrap(requests[1].httpBody).jsonObject["content"] as? String, "# Revised")

        let wrongWorkspace = try client(organizationID: "org-1") { request in
            self.response(##"{"id":"report.md","organization_id":"org-2","title":"Other workspace","content":"# Private"}"##, request: request)
        }
        do { _ = try await wrongWorkspace.detail("report.md"); XCTFail("Expected cross-workspace detail rejection") }
        catch ArticleWorkspaceError.scopeChanged {}
    }
}

private extension Data {
    var jsonObject: [String: Any] { (try! JSONSerialization.jsonObject(with: self)) as! [String: Any] }
}
