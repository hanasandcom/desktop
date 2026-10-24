import Foundation
import XCTest

@testable import Hanasand

final class NativeShareWorkspaceClientTests: XCTestCase {
    func testUnresolvedSaveConflictBlocksWorkspaceNavigationAndTreeMutations() {
        XCTAssertFalse(NativeShareWorkspaceInteractionPolicy.make(hasUnresolvedSaveConflict: true).allowsNavigationAndTreeMutations)
        XCTAssertTrue(NativeShareWorkspaceInteractionPolicy.make(hasUnresolvedSaveConflict: false).allowsNavigationAndTreeMutations)
    }

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
            if request.httpMethod == "GET" && request.url?.path == "/api/share/file-1" {
                body = #"{"id":"file-1","name":"README.md","path":"Root/README.md","content":"Original","type":"file","parent":"root-1"}"#
            } else if request.url?.path == "/api/share/root-1" {
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
        let saved = try await client.saveFile(id: "file-1", name: "README.md", path: "Root/README.md",
                                              content: "# Updated", baselineContent: "Original")

        XCTAssertEqual(requests.prefix(2).map { $0.url?.path }, ["/api/share/root-1", "/api/share/tree/root-1"])
        XCTAssertEqual(workspace.tree.first?.id, "file-1")
        XCTAssertEqual(saved.content, "# Updated")
        let saveRequest = try XCTUnwrap(requests.last)
        XCTAssertEqual(saveRequest.httpMethod, "PUT")
        XCTAssertEqual(saveRequest.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(saveRequest.value(forHTTPHeaderField: "id"), "user-7")
        XCTAssertFalse(saveRequest.httpShouldHandleCookies)
        XCTAssertEqual(requests.suffix(2).map { $0.httpMethod }, ["GET", "PUT"])
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
            _ = try await client.saveFile(id: "file-1", name: "a", path: "a", content: "b", baselineContent: "a")
            XCTFail("Anonymous sessions must not mutate shares.")
        } catch { XCTAssertEqual(error as? NativeShareWorkspaceError, .signInRequired) }

        do {
            _ = try await client.load(context: NativeShareWorkspaceContext(
                alias: "../private", fileID: nil, isProject: false, initialChatOpen: false, createIfMissing: false
            ))
            XCTFail("Invalid route aliases must be rejected before a request.")
        } catch { XCTAssertEqual(error as? NativeShareWorkspaceError, .invalidRoute) }
    }

    func testSaveConflictDoesNotSendPUTWhenFreshContentDiffersFromBaseline() async throws {
        var methods: [String] = []
        let remote = #"{"id":"file-1","name":"README.md","path":"Root/README.md","content":"remote edit","type":"file"}"#
        let client = try makeClient(userID: "user-7", token: "session-token") { request in
            methods.append(request.httpMethod ?? "")
            return (Data(remote.utf8), self.response(for: request.url!))
        }

        do {
            _ = try await client.saveFile(id: "file-1", name: "README.md", path: "Root/README.md",
                                          content: "local edit", baselineContent: "original")
            XCTFail("A changed remote baseline must stop the save before PUT.")
        } catch let NativeShareWorkspaceError.saveConflict(file) {
            XCTAssertEqual(file.content, "remote edit")
        }
        XCTAssertEqual(methods, ["GET"])
    }

    func testExplicitKeepMineBaselineIsRecheckedBeforePUT() async throws {
        var remoteContent = "reviewed server version"
        var putCount = 0
        let client = try makeClient(userID: "user-7", token: "session-token") { request in
            if request.httpMethod == "GET" {
                let body = #"{"id":"file-1","name":"README.md","path":"Root/README.md","content":"\#(remoteContent)","type":"file"}"#
                return (Data(body.utf8), self.response(for: request.url!))
            }
            putCount += 1
            remoteContent = "local draft"
            let body = #"{"id":"file-1","name":"README.md","path":"Root/README.md","content":"local draft","type":"file"}"#
            return (Data(body.utf8), self.response(for: request.url!))
        }

        let saved = try await client.saveFile(id: "file-1", name: "README.md", path: "Root/README.md",
                                              content: "local draft", baselineContent: "reviewed server version")
        XCTAssertEqual(saved.content, "local draft")
        XCTAssertEqual(putCount, 1)
    }

    func testKeepMineFreshCheckCatchesChangeAfterConflictWasDisplayed() async throws {
        var remoteContent = "first remote edit"
        var putCount = 0
        let client = try makeClient(userID: "user-7", token: "session-token") { request in
            if request.httpMethod == "GET" {
                let body = #"{"id":"file-1","name":"README.md","path":"Root/README.md","content":"\#(remoteContent)","type":"file"}"#
                return (Data(body.utf8), self.response(for: request.url!))
            }
            putCount += 1
            return (Data(#"{"id":"file-1","name":"README.md","path":"Root/README.md","content":"local draft","type":"file"}"#.utf8), self.response(for: request.url!))
        }

        do {
            _ = try await client.saveFile(id: "file-1", name: "README.md", path: "Root/README.md",
                                          content: "local draft", baselineContent: "original")
            XCTFail("The first fresh check should surface a conflict.")
        } catch let NativeShareWorkspaceError.saveConflict(file) {
            XCTAssertEqual(file.content, "first remote edit")
        }

        remoteContent = "newer remote edit"
        do {
            _ = try await client.saveFile(id: "file-1", name: "README.md", path: "Root/README.md",
                                          content: "local draft", baselineContent: "first remote edit")
            XCTFail("Keep mine must recheck the reviewed snapshot before writing.")
        } catch let NativeShareWorkspaceError.saveConflict(file) {
            XCTAssertEqual(file.content, "newer remote edit")
        }
        XCTAssertEqual(putCount, 0)
    }

    func testAmbiguousSaveRecoveryRechecksFreshContentAndStopsOnNewConflict() async throws {
        var remoteContent = "original"
        var putCount = 0
        let client = try makeClient(userID: "user-7", token: "session-token") { request in
            if request.httpMethod == "GET" {
                let body = #"{"id":"file-1","name":"README.md","path":"Root/README.md","content":"\#(remoteContent)","type":"file"}"#
                return (Data(body.utf8), self.response(for: request.url!))
            }
            putCount += 1
            remoteContent = "other editor's version"
            throw URLError(.timedOut)
        }

        do {
            _ = try await client.saveFile(id: "file-1", name: "README.md", path: "Root/README.md",
                                          content: "my version", baselineContent: "original")
            XCTFail("The simulated lost response should leave the save unresolved.")
        } catch { XCTAssertEqual(error as? NativeShareWorkspaceError, .mutationUncertain("save")) }

        do {
            _ = try await client.saveFile(id: "file-1", name: "README.md", path: "Root/README.md",
                                          content: "my version", baselineContent: "original")
            XCTFail("Recovery must stop if remote content changed after the ambiguous write.")
        } catch let NativeShareWorkspaceError.saveConflict(file) {
            XCTAssertEqual(file.content, "other editor's version")
        }
        XCTAssertEqual(putCount, 1, "Recovery must retain the draft for explicit conflict review instead of issuing a second PUT.")
    }

    func testRejectsInsecureBaseAndImpersonation() {
        XCTAssertThrowsError(try NativeShareWorkspaceClient(apiBaseURL: URL(string: "http://cdn.hanasand.com/api")!)) {
            XCTAssertEqual($0 as? NativeShareWorkspaceError, .invalidBaseURL)
        }
        XCTAssertThrowsError(try NativeShareWorkspaceClient(apiBaseURL: URL(string: "https://cdn.hanasand.com/api")!, impersonationToken: "other")) {
            XCTAssertEqual($0 as? NativeShareWorkspaceError, .impersonationUnsupported)
        }
    }

    func testRenameAndPathMoveUseWebsitePUTContractAndRequireMatchingReceipt() async throws {
        var requests: [URLRequest] = []
        let client = try makeClient(userID: "user-7", token: "session-token") { request in
            requests.append(request)
            let body = #"{"id":"file-1","name":"renamed.md","path":"Root/archive/renamed.md","content":"body","type":"file","parent":"folder-1"}"#
            return (Data(body.utf8), self.response(for: request.url!))
        }

        _ = try await client.updateMetadata(id: "file-1", name: "renamed.md", path: "Root/archive/renamed.md")

        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.url?.path, "/api/share/file-1")
        XCTAssertEqual(request.httpMethod, "PUT")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-7")
        let body = try XCTUnwrap(request.httpBody)
        let fields = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: String])
        XCTAssertEqual(fields, ["name": "renamed.md", "path": "Root/archive/renamed.md"])
        XCTAssertFalse(fields.keys.contains("parent"), "The CDN has no update-parent contract; path metadata must not pretend to reparent a tree item.")
    }

    func testMetadataMalformedReceiptIsMarkedUncertainAndDeleteValidatesCount() async throws {
        let invalidRename = try makeClient(userID: "user-7", token: "session-token") { request in
            (Data(#"{"id":"other-file","name":"renamed.md","path":"Root/renamed.md"}"#.utf8), self.response(for: request.url!))
        }
        do {
            _ = try await invalidRename.updateMetadata(id: "file-1", name: "renamed.md")
            XCTFail("A mismatched mutation receipt must remain unresolved.")
        } catch { XCTAssertEqual(error as? NativeShareWorkspaceError, .mutationUncertain("rename or move")) }

        let delete = try makeClient(userID: "user-7", token: "session-token") { request in
            XCTAssertEqual(request.url?.path, "/api/share/folder-1")
            XCTAssertEqual(request.httpMethod, "DELETE")
            return (Data(#"{"deleted":3}"#.utf8), self.response(for: request.url!))
        }
        let deletedCount = try await delete.deleteItem(id: "folder-1")
        XCTAssertEqual(deletedCount, 3)

        let malformedDelete = try makeClient(userID: "user-7", token: "session-token") { request in
            (Data(#"{"deleted":0}"#.utf8), self.response(for: request.url!))
        }
        do {
            _ = try await malformedDelete.deleteItem(id: "folder-1")
            XCTFail("A zero deletion count must not be reported as success.")
        } catch { XCTAssertEqual(error as? NativeShareWorkspaceError, .mutationUncertain("delete")) }
    }

    func testDuplicatePlanCopiesWholeSubtreeAndMakesUniqueRootName() throws {
        let tree = try JSONDecoder().decode([NativeShareWorkspaceTreeItem].self, from: Data(#"[{"id":"folder-1","name":"docs","type":"folder","parent":"root-1","children":[{"id":"file-1","name":"guide.md","type":"file","parent":"folder-1"}]},{"id":"folder-2","name":"docs copy","type":"folder","parent":"root-1"}]"#.utf8))
        var generated = ["00000000-0000-4000-8000-000000000001", "00000000-0000-4000-8000-000000000002"]
        let plan = try NativeShareWorkspaceDuplicatePlan.make(sourceID: "folder-1", rootID: "root-1", tree: tree) {
            generated.removeFirst()
        }

        XCTAssertEqual(plan.rootID, "00000000-0000-4000-8000-000000000001")
        XCTAssertEqual(plan.entries, [
            NativeShareWorkspaceDuplicateEntry(sourceID: "folder-1", id: "00000000-0000-4000-8000-000000000001", name: "docs copy 2", parentID: "root-1", type: "folder"),
            NativeShareWorkspaceDuplicateEntry(sourceID: "file-1", id: "00000000-0000-4000-8000-000000000002", name: "guide.md", parentID: "00000000-0000-4000-8000-000000000001", type: "file"),
        ])
    }

    func testDuplicateResumesAfterPartialSubtreeWriteWithoutRepeatingCompletedItem() async throws {
        let context = NativeShareWorkspaceContext(alias: "root-1", fileID: nil, isProject: false, initialChatOpen: false, createIfMissing: false)
        let originalTree = #"[{"id":"folder-1","name":"docs","type":"folder","parent":"root-1","children":[{"id":"file-1","name":"guide.md","type":"file","parent":"folder-1"}]}]"#
        let plan = NativeShareWorkspaceDuplicatePlan(sourceID: "folder-1", rootID: "copy-folder", entries: [
            NativeShareWorkspaceDuplicateEntry(sourceID: "folder-1", id: "copy-folder", name: "docs copy", parentID: "root-1", type: "folder"),
            NativeShareWorkspaceDuplicateEntry(sourceID: "file-1", id: "copy-file", name: "guide.md", parentID: "copy-folder", type: "file"),
        ])
        var created: [String: (name: String, parent: String, type: String)] = [:]
        var posts: [String] = []
        var shouldLoseChildResponse = true
        let client = try makeClient(userID: "user-7", token: "session-token") { request in
            let path = request.url?.path ?? ""
            if path == "/api/share/root-1" {
                return (Data(#"{"id":"root-1","name":"Root","path":"Root","type":"folder"}"#.utf8), self.response(for: request.url!))
            }
            if path == "/api/share/tree/root-1" {
                let copiedChild = created["copy-file"].map { #"{"id":"copy-file","name":"\#($0.name)","type":"\#($0.type)","parent":"\#($0.parent)"}"# }
                let copiedFolder = created["copy-folder"].map { value in
                    #"{"id":"copy-folder","name":"\#(value.name)","type":"\#(value.type)","parent":"\#(value.parent)","children":[\#(copiedChild ?? "")]}"#
                }
                let suffix = copiedFolder.map { ",\($0)" } ?? ""
                let tree = "\(originalTree.dropLast())\(suffix)]"
                return (Data(tree.utf8), self.response(for: request.url!))
            }
            if path == "/api/share/file-1" {
                return (Data(#"{"id":"file-1","name":"guide.md","content":"source body","type":"file","parent":"folder-1"}"#.utf8), self.response(for: request.url!))
            }
            if request.httpMethod == "POST", path == "/api/share" {
                let payload = try XCTUnwrap(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
                let id = try XCTUnwrap(payload["id"] as? String)
                let name = try XCTUnwrap(payload["name"] as? String)
                let parent = try XCTUnwrap(payload["parent"] as? String)
                let type = try XCTUnwrap(payload["type"] as? String)
                posts.append(id)
                created[id] = (name, parent, type)
                if id == "copy-file" && shouldLoseChildResponse {
                    shouldLoseChildResponse = false
                    throw URLError(.timedOut)
                }
                let response = #"{"id":"\#(id)","name":"\#(name)","content":"\#(payload["content"] as? String ?? "")","type":"\#(type)","parent":"\#(parent)"}"#
                return (Data(response.utf8), self.response(for: request.url!, status: 201))
            }
            XCTFail("Unexpected fixture request: \(request.httpMethod ?? "GET") \(path)")
            return (Data(), self.response(for: request.url!))
        }

        do {
            _ = try await client.resumeDuplicate(plan, context: context)
            XCTFail("The simulated lost child response should be unresolved.")
        } catch { XCTAssertEqual(error as? NativeShareWorkspaceError, .mutationUncertain("duplicate")) }

        let completed = try await client.resumeDuplicate(plan, context: context)
        XCTAssertEqual(posts, ["copy-folder", "copy-file"])
        XCTAssertEqual(completed.tree.last?.id, "copy-folder")
        XCTAssertEqual(completed.tree.last?.children?.first?.id, "copy-file")
    }

    private func makeClient(userID: String = "", token: String = "", sender: @escaping NativeShareWorkspaceClient.Sender) throws -> NativeShareWorkspaceClient {
        try NativeShareWorkspaceClient(apiBaseURL: URL(string: "https://cdn.hanasand.com/api")!, userID: userID, token: token, sender: sender)
    }

    private func response(for url: URL, status: Int = 200) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
    }
}
