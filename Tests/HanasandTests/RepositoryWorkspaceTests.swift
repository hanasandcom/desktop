import XCTest

@testable import Hanasand

final class RepositoryWorkspaceTests: XCTestCase {
    private let base = URL(string: "https://api.example.test/api")!

    private final class RequestRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [URLRequest] = []

        func append(_ request: URLRequest) {
            lock.lock()
            stored.append(request)
            lock.unlock()
        }

        var requests: [URLRequest] {
            lock.lock()
            defer { lock.unlock() }
            return stored
        }
    }

    func testLoadsBoundedAuthenticatedRepositoryAndFileLists() async throws {
        let recorder = RequestRecorder()
        let client = try RepositoryWorkspaceClient(
            apiBaseURL: base, userID: "user-1", token: "opaque-token", organizationID: "org-1"
        ) { request in
            recorder.append(request)
            let body: String
            if request.url?.path == "/api/projects/user/user-1" {
                body = #"[{"alias":"repo-a","owner":"user-1","editors":["user-1"],"file_count":2,"total_size":42,"last_updated":"2026-10-22T10:00:00Z"}]"#
            } else {
                body = ##"[{"id":"file-1","alias":"README.md","path":"README.md","content":"# Workspace","locked":false,"timestamp":"2026-10-22T09:00:00Z"}]"##
            }
            return (Data(body.utf8), self.response(for: request))
        }

        let workspace = try await client.loadWorkspace()

        XCTAssertEqual(workspace.projects.map(\.alias), ["repo-a"])
        XCTAssertEqual(workspace.files.map(\.displayName), ["README.md"])
        XCTAssertEqual(recorder.requests.count, 2)
        for request in recorder.requests {
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer opaque-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-organization-id"), "org-1")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Cache-Control"), "no-store")
            XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
            XCTAssertNil(request.httpBody)
        }
    }

    func testOpensRepositoryAndValidatesItsTree() async throws {
        let client = try RepositoryWorkspaceClient(apiBaseURL: base, userID: "user-1", token: "opaque-token") { request in
            XCTAssertEqual(request.url?.path, "/api/project/my-repo")
            let body = #"{"share":{"id":"root-1","alias":"my-repo","path":"my-repo","content":"","locked":false},"tree":[{"id":"folder-1","name":"Sources","type":"folder","children":[{"id":"file-1","name":"main.swift","type":"file"}]}]}"#
            return (Data(body.utf8), self.response(for: request))
        }

        let detail = try await client.loadProject(alias: "my-repo")
        XCTAssertEqual(detail.share.alias, "my-repo")
        XCTAssertEqual(detail.tree.first?.children?.first?.name, "main.swift")
    }

    func testRejectsInsecureAndImpersonatedContexts() {
        XCTAssertThrowsError(try RepositoryWorkspaceClient(apiBaseURL: URL(string: "http://api.example.test/api")!, userID: "user-1", token: "token")) {
            XCTAssertEqual($0 as? RepositoryWorkspaceError, .invalidBaseURL)
        }
        XCTAssertThrowsError(try RepositoryWorkspaceClient(apiBaseURL: base, userID: "user-1", token: "token", impersonationToken: "delegated")) {
            XCTAssertEqual($0 as? RepositoryWorkspaceError, .impersonationUnsupported)
        }
    }

    func testRejectsOversizedResponsesAndDuplicateRows() async throws {
        let oversized = try RepositoryWorkspaceClient(apiBaseURL: base, userID: "user-1", token: "token") { request in
            (Data(repeating: 0x20, count: RepositoryWorkspaceLimits.responseBytes + 1), self.response(for: request))
        }
        do {
            _ = try await oversized.loadWorkspace()
            XCTFail("Expected oversized response to be rejected")
        } catch { XCTAssertEqual(error as? RepositoryWorkspaceError, .invalidResponse) }

        let duplicate = try RepositoryWorkspaceClient(apiBaseURL: base, userID: "user-1", token: "token") { request in
            let body = #"[{"alias":"repo-a","owner":"u","editors":[],"file_count":0,"total_size":0,"last_updated":""},{"alias":"repo-a","owner":"u","editors":[],"file_count":0,"total_size":0,"last_updated":""}]"#
            return (Data(body.utf8), self.response(for: request))
        }
        do {
            _ = try await duplicate.loadWorkspace()
            XCTFail("Expected duplicate repository aliases to be rejected")
        } catch { XCTAssertEqual(error as? RepositoryWorkspaceError, .invalidResponse) }
    }

    func testRejectsOverdeepTree() throws {
        var child = #"{"id":"leaf","name":"leaf","type":"file"}"#
        for depth in 0...RepositoryWorkspaceLimits.treeDepth {
            child = #"{"id":"node-\#(depth)","name":"node","type":"folder","children":[\#(child)]}"#
        }
        let payload = #"{"share":{"id":"root","content":""},"tree":[\#(child)]}"#
        let detail = try JSONDecoder().decode(RepositoryWorkspaceProjectDetail.self, from: Data(payload.utf8))
        XCTAssertThrowsError(try detail.validate()) { XCTAssertEqual($0 as? RepositoryWorkspaceError, .invalidResponse) }
    }

    private func response(for request: URLRequest) -> URLResponse {
        HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}
