import Foundation
import XCTest

@testable import Hanasand

final class NativeShareWorkspaceClientTests: XCTestCase {
    func testProjectAliasLoadsTreeAndSelectedFileWithoutLosingRouteContext() async throws {
        var requests: [URLRequest] = []
        let client = try makeClient { request in
            requests.append(request)
            let body: String
            if request.url?.path == "/api/project/alpha-project" {
                body = #"{"share":{"id":"root-1","name":"Project","path":"Project","alias":"alpha-project","content":"","type":"folder"},"tree":[{"id":"folder-1","name":"src","type":"folder","children":[{"id":"file-1","name":"main.swift","path":"Project/src/main.swift","type":"file","parent":"folder-1"}]}]}"#
            } else {
                body = #"{"id":"file-1","name":"main.swift","path":"Project/src/main.swift","alias":"main.swift","content":"print(1)","type":"file","parent":"folder-1"}"#
            }
            return (Data(body.utf8), self.response(for: request.url!))
        }

        let workspace = try await client.load(context: NativeShareWorkspaceContext(
            alias: "alpha-project", fileID: "file-1", isProject: true,
            initialChatOpen: true, createIfMissing: false
        ))

        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/project/alpha-project", "/api/share/file-1"])
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil })
        XCTAssertEqual(workspace.root.alias, "alpha-project")
        XCTAssertEqual(workspace.tree.first?.children?.first?.id, "file-1")
        XCTAssertEqual(workspace.selectedFile?.content, "print(1)")
    }

    func testShareRouteLoadsTreeAndAllowsAccountAuthenticatedFileSave() async throws {
        var requests: [URLRequest] = []
        let client = try makeClient(userID: "user-7", token: "session-token") { request in
            requests.append(request)
            let body: String
            if request.url?.path == "/api/share/root-1" {
                body = #"{"id":"root-1","name":"Root","path":"Root","alias":"root-1","content":"","type":"folder"}"#
            } else if request.url?.path == "/api/share/tree/root-1" {
                body = #"[{"id":"file-1","name":"README.md","path":"Root/README.md","type":"file","parent":"root-1"}]"#
            } else {
                body = ##"{"id":"file-1","name":"README.md","path":"Root/README.md","alias":"README.md","content":"# Updated","type":"file","parent":"root-1"}"##
            }
            return (Data(body.utf8), self.response(for: request.url!))
        }

        let workspace = try await client.load(context: NativeShareWorkspaceContext(
            alias: "root-1", fileID: nil, isProject: false, initialChatOpen: false, createIfMissing: false
        ))
        let saved = try await client.saveFile(id: "file-1", name: "README.md", path: "Root/README.md", content: "# Updated")

        XCTAssertEqual(requests.prefix(2).map { $0.url?.path }, ["/api/share/root-1", "/api/share/tree/root-1"])
        XCTAssertEqual(workspace.tree.first?.id, "file-1")
        XCTAssertEqual(saved.content, "# Updated")
        let saveRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(saveRequest.httpMethod, "PUT")
        XCTAssertEqual(saveRequest.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(saveRequest.value(forHTTPHeaderField: "id"), "user-7")
        XCTAssertFalse(saveRequest.httpShouldHandleCookies)
        let body = try XCTUnwrap(saveRequest.httpBody).withUnsafeBytes { Data($0) }
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(fields["content"], "# Updated")
    }

    func testNewWorkspaceUsesFolderCreationContractAndPreservesAlias() async throws {
        var captured: URLRequest?
        let client = try makeClient(userID: "user-7", token: "session-token") { request in
            captured = request
            return (Data(#"{"id":"new-space","name":"new-space","path":"new-space","alias":"new-space","content":"","type":"folder","tree":[{"id":"new-space","name":"new-space","type":"folder","children":[]}]}"#.utf8), self.response(for: request.url!, status: 201))
        }

        let workspace = try await client.load(context: NativeShareWorkspaceContext(
            alias: "new-space", fileID: nil, isProject: false, initialChatOpen: true, createIfMissing: true
        ))

        XCTAssertEqual(captured?.url?.path, "/api/share")
        XCTAssertEqual(captured?.httpMethod, "POST")
        let body = try XCTUnwrap(captured?.httpBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(fields["id"] as? String, "new-space")
        XCTAssertEqual(fields["type"] as? String, "folder")
        XCTAssertEqual(fields["includeTree"] as? Bool, true)
        XCTAssertEqual(workspace.root.id, "new-space")
        XCTAssertEqual(workspace.tree.first?.id, "new-space")
    }

    func testAnonymousReadOnlyAndMalformedRoutesFailClosed() async throws {
        let client = try makeClient { request in
            (Data(#"{"id":"file-1","content":"text"}"#.utf8), self.response(for: request.url!))
        }
        do {
            _ = try await client.saveFile(id: "file-1", name: "a", path: "a", content: "b")
            XCTFail("Anonymous sessions must not mutate shares.")
        } catch { XCTAssertEqual(error as? NativeShareWorkspaceError, .signInRequired) }

        do {
            _ = try await client.load(context: NativeShareWorkspaceContext(
                alias: "../private", fileID: nil, isProject: false, initialChatOpen: false, createIfMissing: false
            ))
            XCTFail("Invalid route aliases must be rejected before a request.")
        } catch { XCTAssertEqual(error as? NativeShareWorkspaceError, .invalidRoute) }
    }

    func testRejectsInsecureBaseAndImpersonation() {
        XCTAssertThrowsError(try NativeShareWorkspaceClient(apiBaseURL: URL(string: "http://cdn.hanasand.com/api")!)) {
            XCTAssertEqual($0 as? NativeShareWorkspaceError, .invalidBaseURL)
        }
        XCTAssertThrowsError(try NativeShareWorkspaceClient(apiBaseURL: URL(string: "https://cdn.hanasand.com/api")!, impersonationToken: "other")) {
            XCTAssertEqual($0 as? NativeShareWorkspaceError, .impersonationUnsupported)
        }
    }

    private func makeClient(userID: String = "", token: String = "", sender: @escaping NativeShareWorkspaceClient.Sender) throws -> NativeShareWorkspaceClient {
        try NativeShareWorkspaceClient(apiBaseURL: URL(string: "https://cdn.hanasand.com/api")!, userID: userID, token: token, sender: sender)
    }

    private func response(for url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}
