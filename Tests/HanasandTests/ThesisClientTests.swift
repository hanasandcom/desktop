import Foundation
import XCTest
@testable import Hanasand

final class ThesisClientTests: XCTestCase {
    private let base = URL(string: "https://api.hanasand.test/api")!
    private let access = ThesisAccess(member: true, canEdit: true)
    private let document = ThesisDocument(title: "Research", body: "# Findings", revision: 4)

    private func settings(impersonating: Bool = false) -> HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.apiBaseURL = base.absoluteString
        value.userID = "owner"
        value.authToken = "token"
        if impersonating { value.impersonationToken = "impersonation" }
        return value
    }

    private func response(_ body: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!)
    }

    func testAccessAndLoadUseAuthenticatedNoStoreAPIRequests() async throws {
        var paths: [String] = []
        let client = try ThesisClient(settings: settings()) { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "owner")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertFalse(request.httpShouldHandleCookies)
            return request.url!.path.hasSuffix("/access")
                ? self.response(#"{"member":true,"canEdit":true}"#, request: request)
                : self.response(##"{"title":"Research","body":"# Findings","revision":4}"##, request: request)
        }
        let loadedAccess = try await client.loadAccess()
        let loadedDocument = try await client.load()
        XCTAssertEqual(loadedAccess, access)
        XCTAssertEqual(loadedDocument, document)
        XCTAssertEqual(paths, ["/api/thesis/access", "/api/thesis"])
    }

    func testSaveSendsExpectedRevisionAndValidatesReceipt() async throws {
        var captured: URLRequest?
        let client = try ThesisClient(settings: settings()) { request in
            captured = request
            return self.response(#"{"title":"Updated","body":"New body","revision":5}"#, request: request)
        }
        let result = try await client.save(ThesisDocument(title: "Updated", body: "New body", revision: 4), access: access)
        XCTAssertEqual(result.revision, 5)
        XCTAssertEqual(captured?.httpMethod, "PUT")
        XCTAssertEqual(captured?.url?.path, "/api/thesis")
        let payload = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(captured?.httpBody)) as? [String: Any])
        XCTAssertEqual(payload["revision"] as? Int, 4)
        XCTAssertEqual(payload["title"] as? String, "Updated")
        XCTAssertEqual(captured?.value(forHTTPHeaderField: "Content-Type"), "application/json")
    }

    func testSaveFailsClosedForReadOnlyAndInvalidDocument() async throws {
        let client = try ThesisClient(settings: settings()) { request in
            self.response("{}", request: request)
        }
        do { _ = try await client.save(document, access: ThesisAccess(member: true, canEdit: false)); XCTFail("Expected read-only guard") }
        catch ThesisClientError.readOnly {}
        do { _ = try await client.save(ThesisDocument(title: "\n", body: "", revision: 1), access: access); XCTFail("Expected invalid title guard") }
        catch ThesisClientError.invalidDocument {}
        let impersonated = try ThesisClient(settings: settings(impersonating: true)) { request in self.response("{}", request: request) }
        do { _ = try await impersonated.save(document, access: access); XCTFail("Expected impersonation guard") }
        catch ThesisClientError.readOnly {}
    }

    func testConflictReturnsCurrentDocumentAndHistoryRoutesAreScoped() async throws {
        var paths: [String] = []
        let client = try ThesisClient(settings: settings()) { request in
            paths.append(request.url!.path + (request.url!.query.map { "?\($0)" } ?? ""))
            if request.url!.path.hasSuffix("/history/3") { return self.response(#"{"title":"Old","body":"Previous","revision":3}"#, request: request) }
            if request.url!.path.hasSuffix("/history") { return self.response(#"[{"revision":3,"title":"Old","saved_at":"2026-10-23T10:00:00Z","immediate":true}]"#, request: request) }
            return self.response(#"{"title":"Other","body":"Latest","revision":5}"#, request: request, status: 409)
        }
        do { _ = try await client.save(document, access: access); XCTFail("Expected revision conflict") }
        catch ThesisClientError.conflict(let current) { XCTAssertEqual(current.revision, 5) }
        let history = try await client.history(before: 4)
        XCTAssertEqual(history.first?.revision, 3)
        let oldVersion = try await client.version(3)
        XCTAssertEqual(oldVersion.title, "Old")
        XCTAssertEqual(paths, ["/api/thesis", "/api/thesis/history?before=4", "/api/thesis/history/3"])
    }

    func testRejectsInvalidCredentialsAndInsecureAPIURL() {
        var invalid = settings()
        invalid.authToken = "bad token"
        XCTAssertThrowsError(try ThesisClient(settings: invalid)) { XCTAssertEqual($0 as? ThesisClientError, .invalidIdentity) }
        invalid = settings(); invalid.apiBaseURL = "http://api.hanasand.test/api"
        XCTAssertThrowsError(try ThesisClient(settings: invalid)) { XCTAssertEqual($0 as? ThesisClientError, .invalidBaseURL) }
    }
}
