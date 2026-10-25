import Foundation
import XCTest

@testable import Hanasand

final class NativeShareGitWorkspaceSyncTests: XCTestCase {
    func testImportCreatesNestedTreeAndReportsFileProgress() async throws {
        let store = ShareSyncStore()
        let client = try store.client()
        var progress: [NativeShareGitWorkspaceProgress] = []
        let repository = makeRepository(files: [
            .init(path: "README.md", name: "README.md", content: "welcome"),
            .init(path: "src/main.swift", name: "main.swift", content: "print(1)"),
        ])

        let workspace = try await NativeShareGitWorkspaceSync(workspaceClient: client).sync(
            repository: repository, alias: repository.id, createIfMissing: true, progress: { progress.append($0) }
        )

        XCTAssertEqual(workspace.root.id, "repo-1")
        XCTAssertEqual(workspace.root.name, "repo")
        XCTAssertEqual(ShareSyncStore.flatten(workspace.tree).mapValues(\.name), [
            "README.md": "README.md", "src": "src", "src/main.swift": "main.swift",
        ])
        XCTAssertEqual(progress.map(\.completedFiles), [0, 1, 2])
        XCTAssertEqual(progress.last?.currentPath, "src/main.swift")
        XCTAssertTrue(store.requests.contains { $0.httpMethod == "POST" && $0.url?.path == "/api/share" })
    }

    func testPullUpdatesFilesAndPrunesObsoleteFilesAndFolders() async throws {
        let store = ShareSyncStore(existingTree: [
            .init(id: "keep", name: "README.md", parent: "repo-1", type: "file", content: "old"),
            .init(id: "obsolete", name: "old.txt", parent: "stale-folder", type: "file", content: "remove"),
            .init(id: "stale-folder", name: "old", parent: "repo-1", type: "folder", content: ""),
        ])
        let client = try store.client()
        let repository = makeRepository(files: [
            .init(path: "README.md", name: "README.md", content: "new"),
        ])

        let workspace = try await NativeShareGitWorkspaceSync(workspaceClient: client).sync(
            repository: repository, alias: repository.id
        )

        XCTAssertEqual(ShareSyncStore.flatten(workspace.tree).mapValues(\.name), ["README.md": "README.md"])
        XCTAssertEqual(store.content(for: "keep"), "new")
        XCTAssertTrue(store.requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/api/share/obsolete" })
        XCTAssertTrue(store.requests.contains { $0.httpMethod == "DELETE" && $0.url?.path == "/api/share/stale-folder" })
    }

    func testLostCreateResponseReloadsTreeAndDoesNotDuplicateFile() async throws {
        let store = ShareSyncStore(loseFirstCreateResponse: true)
        let client = try store.client()
        let repository = makeRepository(files: [
            .init(path: "src/main.swift", name: "main.swift", content: "print(1)"),
        ])

        let workspace = try await NativeShareGitWorkspaceSync(workspaceClient: client).sync(
            repository: repository, alias: repository.id, createIfMissing: true
        )

        let items = ShareSyncStore.flatten(workspace.tree)
        XCTAssertEqual(items.keys.sorted(), ["src", "src/main.swift"])
        XCTAssertEqual(store.count(type: "file", name: "main.swift"), 1)
        XCTAssertEqual(store.count(type: "folder", name: "src"), 1)
    }

    func testLostWorkspaceCreateResponseResumesFromTheExistingRoot() async throws {
        let store = ShareSyncStore(loseWorkspaceCreateResponse: true)
        let client = try store.client()
        let repository = makeRepository(files: [])

        let workspace = try await NativeShareGitWorkspaceSync(workspaceClient: client).sync(
            repository: repository, alias: repository.id, createIfMissing: true
        )

        XCTAssertEqual(workspace.root.id, "repo-1")
        XCTAssertEqual(store.count(type: "folder", name: "repo"), 0)
        XCTAssertEqual(store.requests.filter { $0.httpMethod == "POST" && $0.url?.path == "/api/share" }.count, 1)
    }

    func testLostUpdateAndDeleteResponsesAreConfirmedFromFreshTreeAndFileReads() async throws {
        let store = ShareSyncStore(existingTree: [
            .init(id: "keep", name: "README.md", parent: "repo-1", type: "file", content: "old"),
            .init(id: "obsolete", name: "old.txt", parent: "repo-1", type: "file", content: "remove"),
        ], loseFirstUpdateResponse: true, loseFirstDeleteResponse: true)
        let client = try store.client()
        let repository = makeRepository(files: [
            .init(path: "README.md", name: "README.md", content: "new"),
        ])

        let workspace = try await NativeShareGitWorkspaceSync(workspaceClient: client).sync(
            repository: repository, alias: repository.id
        )

        XCTAssertEqual(store.content(for: "keep"), "new")
        XCTAssertNil(ShareSyncStore.flatten(workspace.tree)["old.txt"])
    }

    func testRejectsUnsafeOrDuplicateRepositoryPathsBeforeAnyMutation() async throws {
        let store = ShareSyncStore()
        let client = try store.client()
        let unsafe = makeRepository(files: [.init(path: "../secret", name: "secret", content: "x")])
        do {
            _ = try await NativeShareGitWorkspaceSync(workspaceClient: client).sync(
                repository: unsafe, alias: unsafe.id, createIfMissing: true
            )
            XCTFail("Unsafe repository paths must be rejected before creating a share.")
        } catch { XCTAssertEqual(error as? NativeShareGitError, .invalidResponse) }
        XCTAssertTrue(store.requests.isEmpty)

        let duplicate = makeRepository(files: [
            .init(path: "README.md", name: "README.md", content: "one"),
            .init(path: "README.md", name: "README.md", content: "two"),
        ])
        do {
            _ = try await NativeShareGitWorkspaceSync(workspaceClient: client).sync(
                repository: duplicate, alias: duplicate.id, createIfMissing: true
            )
            XCTFail("Duplicate repository paths must be rejected before creating a share.")
        } catch { XCTAssertEqual(error as? NativeShareGitError, .invalidResponse) }
        XCTAssertTrue(store.requests.isEmpty)

        let collision = makeRepository(files: [
            .init(path: "src", name: "src", content: "file"),
            .init(path: "src/main.swift", name: "main.swift", content: "print(1)"),
        ])
        do {
            _ = try await NativeShareGitWorkspaceSync(workspaceClient: client).sync(
                repository: collision, alias: collision.id, createIfMissing: true
            )
            XCTFail("A file path cannot also be a parent folder.")
        } catch { XCTAssertEqual(error as? NativeShareGitError, .invalidResponse) }
        XCTAssertTrue(store.requests.isEmpty)
    }

    private func makeRepository(files: [NativeShareGitRepositoryFile]) -> NativeShareGitRepository {
        NativeShareGitRepository(id: "repo-1", ownerId: "user-7", accessScope: "owned", name: "repo",
            fullName: "owner/repo", branch: "main", defaultBranch: "main", sourcePath: "",
            sourceUrl: "https://github.com/owner/repo/tree/main", authMode: "public", authHint: nil,
            syncStatus: "ready", lastSyncedAt: nil, lastSyncError: nil, syncHistory: [], stackType: "unknown",
            stackReason: nil, stackSupported: false, files: files, truncated: false, importedAt: "2026-01-01T00:00:00Z",
            credential: .init(provider: "github_pat", hasCredential: false, tokenHint: nil,
                              attachedAt: nil, lastUsedAt: nil, lastValidatedAt: nil))
    }
}

private final class ShareSyncStore: @unchecked Sendable {
    fileprivate struct Record {
        var id: String
        var name: String
        var path: String = ""
        var parent: String?
        var type: String
        var content: String
    }

    private let lock = NSRecursiveLock()
    private var root = Record(id: "repo-1", name: "repo", path: "repo-1", parent: nil, type: "folder", content: "")
    private var records: [String: Record] = [:]
    private var loseFirstCreateResponse: Bool
    private var loseWorkspaceCreateResponse: Bool
    private var loseFirstUpdateResponse: Bool
    private var loseFirstDeleteResponse: Bool
    private var didLoseCreateResponse = false
    private var didLoseWorkspaceCreateResponse = false
    private var didLoseUpdateResponse = false
    private var didLoseDeleteResponse = false
    private var sentRequests: [URLRequest] = []

    fileprivate init(existingTree: [Record] = [], loseFirstCreateResponse: Bool = false,
                     loseWorkspaceCreateResponse: Bool = false, loseFirstUpdateResponse: Bool = false,
                     loseFirstDeleteResponse: Bool = false) {
        self.loseFirstCreateResponse = loseFirstCreateResponse
        self.loseWorkspaceCreateResponse = loseWorkspaceCreateResponse
        self.loseFirstUpdateResponse = loseFirstUpdateResponse
        self.loseFirstDeleteResponse = loseFirstDeleteResponse
        for record in existingTree { records[record.id] = record }
    }

    var requests: [URLRequest] {
        lock.lock(); defer { lock.unlock() }
        return sentRequests
    }

    func client() throws -> NativeShareWorkspaceClient {
        try NativeShareWorkspaceClient(apiBaseURL: URL(string: "https://cdn.hanasand.com/api")!,
            userID: "user-7", token: "session-token") { [weak self] request in
                guard let self else { throw URLError(.cancelled) }
                return try self.send(request)
            }
    }

    func content(for id: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return records[id]?.content
    }

    func count(type: String, name: String) -> Int {
        lock.lock(); defer { lock.unlock() }
        return records.values.filter { $0.type == type && $0.name == name }.count
    }

    static func flatten(_ tree: [NativeShareWorkspaceTreeItem], prefix: String = "") -> [String: NativeShareWorkspaceTreeItem] {
        var result: [String: NativeShareWorkspaceTreeItem] = [:]
        for item in tree {
            let path = prefix.isEmpty ? item.name : "\(prefix)/\(item.name)"
            result[path] = item
            result.merge(flatten(item.children ?? [], prefix: path)) { current, _ in current }
        }
        return result
    }

    private func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        lock.lock(); defer { lock.unlock() }
        sentRequests.append(request)
        let path = request.url?.path ?? ""
        let method = request.httpMethod ?? "GET"
        if method == "GET", path == "/api/share/repo-1" {
            return response(recordJSON(root), request: request)
        }
        if method == "GET", path == "/api/share/tree/repo-1" {
            return response(treeJSON(parent: "repo-1"), request: request)
        }
        if method == "GET", path.hasPrefix("/api/share/") {
            let id = String(path.dropFirst("/api/share/".count))
            guard let record = records[id] else { return response("{}", request: request, status: 404) }
            return response(recordJSON(record), request: request)
        }
        if method == "POST", path == "/api/share" {
            let body = try XCTUnwrap(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] })
            let id = try XCTUnwrap(body["id"] as? String)
            let record = Record(id: id, name: try XCTUnwrap(body["name"] as? String),
                path: body["path"] as? String ?? "", parent: body["parent"] as? String,
                type: try XCTUnwrap(body["type"] as? String), content: body["content"] as? String ?? "")
            if id == "repo-1" {
                root.name = record.name; root.path = record.path
                if loseWorkspaceCreateResponse && !didLoseWorkspaceCreateResponse {
                    didLoseWorkspaceCreateResponse = true
                    throw URLError(.timedOut)
                }
                return response(recordJSON(root, includeTree: true), request: request, status: 201)
            }
            records[id] = record
            if loseFirstCreateResponse && !didLoseCreateResponse {
                didLoseCreateResponse = true
                throw URLError(.timedOut)
            }
            return response(recordJSON(record), request: request, status: 201)
        }
        if method == "PUT", path.hasPrefix("/api/share/") {
            let id = String(path.dropFirst("/api/share/".count))
            let body = try XCTUnwrap(request.httpBody.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] })
            if id == root.id {
                if let name = body["name"] { root.name = name }
                if let path = body["path"] { root.path = path }
                return response(recordJSON(root), request: request)
            }
            guard var record = records[id] else { return response("{}", request: request, status: 404) }
            if let name = body["name"] { record.name = name }
            if let path = body["path"] { record.path = path }
            if let content = body["content"] { record.content = content }
            records[id] = record
            if loseFirstUpdateResponse && !didLoseUpdateResponse {
                didLoseUpdateResponse = true
                throw URLError(.timedOut)
            }
            return response(recordJSON(record), request: request)
        }
        if method == "DELETE", path.hasPrefix("/api/share/") {
            let id = String(path.dropFirst("/api/share/".count))
            let descendants = descendantIDs(of: id)
            for child in descendants { records.removeValue(forKey: child) }
            records.removeValue(forKey: id)
            if loseFirstDeleteResponse && !didLoseDeleteResponse {
                didLoseDeleteResponse = true
                throw URLError(.timedOut)
            }
            return response(#"{"deleted":1}"#, request: request)
        }
        XCTFail("Unexpected sync request: \(method) \(path)")
        return response("{}", request: request, status: 500)
    }

    private func treeJSON(parent: String) -> String {
        let children = records.values.filter { $0.parent == parent }.sorted { $0.name < $1.name }
        let payload: [[String: Any]] = children.map { record in
            ["id": record.id, "name": record.name, "path": record.path, "type": record.type,
             "parent": record.parent ?? "", "children": record.type == "folder" ? (try? JSONSerialization.jsonObject(with: Data(treeJSON(parent: record.id).utf8))) ?? [] : []]
        }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func recordJSON(_ record: Record, includeTree: Bool = false) -> String {
        var payload: [String: Any] = ["id": record.id, "name": record.name, "path": record.path,
            "type": record.type, "content": record.content]
        if let parent = record.parent { payload["parent"] = parent }
        if includeTree { payload["tree"] = (try? JSONSerialization.jsonObject(with: Data(treeJSON(parent: record.id).utf8))) ?? [] }
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    private func descendantIDs(of id: String) -> [String] {
        let children = records.values.filter { $0.parent == id }.map(\.id)
        return children.flatMap { descendantIDs(of: $0) } + children
    }

    private func response(_ body: String, request: URLRequest, status: Int = 200) -> (Data, URLResponse) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"])!
        return (Data(body.utf8), response)
    }
}
