import Foundation
import XCTest

@testable import Hanasand

final class NativeShareGitClientTests: XCTestCase {
    func testClientRequiresOwnAuthenticatedHTTPSAccount() throws {
        var settings = makeSettings()
        settings.userID = ""
        XCTAssertThrowsError(try NativeShareGitClient(settings: settings)) {
            XCTAssertEqual($0 as? NativeShareGitError, .signInRequired)
        }

        settings = makeSettings()
        settings.impersonatingUserID = "other-user"
        XCTAssertThrowsError(try NativeShareGitClient(settings: settings)) {
            XCTAssertEqual($0 as? NativeShareGitError, .impersonationUnsupported)
        }

        settings = makeSettings()
        settings.apiBaseURL = "http://api.hanasand.com/api"
        XCTAssertThrowsError(try NativeShareGitClient(settings: settings)) {
            XCTAssertEqual($0 as? NativeShareGitError, .invalidEndpoint)
        }
    }

    func testGitStatusAndCommitRequestsUseAuthenticatedCookieFreeContract() async throws {
        let recorder = GitRequestRecorder()
        let client = try NativeShareGitClient(settings: makeSettings()) { request in
            recorder.append(request)
            let body = request.httpMethod == "GET"
                ? #"{"files":[{"path":"src/main.swift","index":" ","workingTree":"M","selected":false}],"branchSummary":"main...origin/main"}"#
                : #"{"ok":true,"commit":"abc1234","status":{"files":[],"branchSummary":"main...origin/main"}}"#
            return (Data(body.utf8), try self.response(for: request.url!))
        }

        let status = try await client.loadStatus(repositoryID: "repo-1", shareID: "share-1")
        let committed = try await client.commit(repositoryID: "repo-1", shareID: "share-1", message: " Fix changes ", paths: ["src/main.swift"])

        XCTAssertEqual(status.files.first?.path, "src/main.swift")
        XCTAssertEqual(committed.commit, "abc1234")
        let requests = recorder.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["GET", "POST"])
        XCTAssertEqual(requests[0].url?.path, "/api/ai/repositories/repo-1/git/status")
        XCTAssertEqual(URLComponents(url: requests[0].url!, resolvingAgainstBaseURL: false)?.queryItems, [URLQueryItem(name: "shareId", value: "share-1")])
        XCTAssertEqual(requests[1].url?.path, "/api/ai/repositories/repo-1/git/commit")
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer session-token" })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "id") == "user-7" })
        XCTAssertTrue(requests.allSatisfy { $0.httpShouldHandleCookies == false })
        XCTAssertTrue(requests.allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == nil })
        let commitBody = try XCTUnwrap(requests[1].httpBody)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: commitBody) as? [String: Any])
        XCTAssertEqual(payload["shareId"] as? String, "share-1")
        XCTAssertEqual(payload["message"] as? String, "Fix changes")
        XCTAssertEqual(payload["paths"] as? [String], ["src/main.swift"])
    }

    func testPullAndPushUseAuthenticatedPostEndpoints() async throws {
        let recorder = GitRequestRecorder()
        let client = try NativeShareGitClient(settings: makeSettings()) { request in
            recorder.append(request)
            let status = #"{"files":[],"branchSummary":"main...origin/main"}"#
            return (Data(status.utf8), try self.response(for: request.url!))
        }

        _ = try await client.pull(repositoryID: "repo-1")
        _ = try await client.push(repositoryID: "repo-1")

        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(recorder.requests.map { $0.url?.path }, [
            "/api/ai/repositories/repo-1/git/pull",
            "/api/ai/repositories/repo-1/git/push",
        ])
    }

    func testImportAndPersistMatchWebsitePayloadWithoutRetainingPastedToken() async throws {
        let recorder = GitRequestRecorder()
        let client = try NativeShareGitClient(settings: makeSettings()) { request in
            recorder.append(request)
            if request.url?.path == "/api/ai/import-repository" {
                return (Data(Self.repositoryJSON.utf8), try self.response(for: request.url!))
            }
            return (Data(#"{"ok":true,"id":"repo-1"}"#.utf8), try self.response(for: request.url!, status: 201))
        }

        let repository = try await client.importRepository(input: "owner/repo", githubToken: "ghp_one_time_secret")
        try await client.persistRepository(repository)

        XCTAssertEqual(repository.id, "repo-1")
        XCTAssertEqual(repository.ownerId, "user-7")
        XCTAssertEqual(repository.files.first?.path, "README.md")
        XCTAssertFalse(String(describing: repository).contains("ghp_one_time_secret"))
        let requests = recorder.requests
        XCTAssertEqual(requests.map(\.httpMethod), ["POST", "POST"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/ai/import-repository", "/api/ai/repositories"])
        let importBody = try XCTUnwrap(requests[0].httpBody)
        XCTAssertTrue(String(decoding: importBody, as: UTF8.self).contains("ghp_one_time_secret"))
        let persistBody = try XCTUnwrap(requests[1].httpBody)
        XCTAssertFalse(String(decoding: persistBody, as: UTF8.self).contains("ghp_one_time_secret"))
        let persisted = try XCTUnwrap(JSONSerialization.jsonObject(with: persistBody) as? [String: Any])
        XCTAssertEqual(persisted["id"] as? String, "repo-1")
        XCTAssertEqual(persisted["ownerId"] as? String, "user-7")
    }

    func testCredentialSetAndRemoveUseWebsiteRoutesAndDoNotExposeTokenInResponseModel() async throws {
        let recorder = GitRequestRecorder()
        let client = try NativeShareGitClient(settings: makeSettings()) { request in
            recorder.append(request)
            let body = request.httpMethod == "PUT"
                ? #"{"credential":{"provider":"github_pat","hasCredential":true,"tokenHint":"ghp_…abcd","attachedAt":"2026-01-01T00:00:00Z","lastUsedAt":null,"lastValidatedAt":null}}"#
                : #"{"ok":true}"#
            return (Data(body.utf8), try self.response(for: request.url!))
        }

        let summary = try await client.attachGitHubCredential(repositoryID: "repo-1", githubToken: "ghp_one_time_secret")
        try await client.removeGitHubCredential(repositoryID: "repo-1")

        XCTAssertTrue(summary.hasCredential)
        XCTAssertFalse(String(describing: summary).contains("ghp_one_time_secret"))
        XCTAssertEqual(recorder.requests.map(\.httpMethod), ["PUT", "DELETE"])
        XCTAssertEqual(recorder.requests.map { $0.url?.path }, [
            "/api/ai/repositories/repo-1/credentials/github",
            "/api/ai/repositories/repo-1/credentials/github",
        ])
        XCTAssertTrue(String(decoding: recorder.requests[0].httpBody!, as: UTF8.self).contains("ghp_one_time_secret"))
        XCTAssertNil(recorder.requests[1].httpBody)
    }

    func testUnsafeIdentifiersCommitPathsAndForeignOwnerAreRejectedBeforeMutation() async throws {
        let recorder = GitRequestRecorder()
        let client = try NativeShareGitClient(settings: makeSettings()) { request in
            recorder.append(request)
            let foreignOwner = Self.repositoryJSON.replacingOccurrences(of: "\"ownerId\":\"user-7\"", with: "\"ownerId\":\"user-8\"")
            return (Data(foreignOwner.utf8), try self.response(for: request.url!))
        }

        do {
            _ = try await client.loadStatus(repositoryID: "../other", shareID: "share-1")
            XCTFail("Path traversal IDs must be rejected before sending.")
        } catch { XCTAssertEqual(error as? NativeShareGitError, .invalidInput) }

        do {
            _ = try await client.commit(repositoryID: "repo-1", shareID: "share-1", message: "commit", paths: ["../secret"])
            XCTFail("Unsafe relative paths must be rejected before sending.")
        } catch { XCTAssertEqual(error as? NativeShareGitError, .invalidInput) }

        do {
            _ = try await client.commit(repositoryID: "repo-1", shareID: "share-1", message: "", paths: ["README.md"])
            XCTFail("Empty commit messages must be rejected before sending.")
        } catch { XCTAssertEqual(error as? NativeShareGitError, .invalidInput) }

        do {
            _ = try await client.importRepository(input: "owner/repo")
            XCTFail("A repository owned by another account must be rejected.")
        } catch { XCTAssertEqual(error as? NativeShareGitError, .invalidResponse) }

        XCTAssertTrue(recorder.requests.allSatisfy { $0.url?.path == "/api/ai/import-repository" })
        XCTAssertEqual(recorder.requests.count, 1)
    }

    func testResponseFromForeignHostIsRejected() async throws {
        let client = try NativeShareGitClient(settings: makeSettings()) { request in
            let response = HTTPURLResponse(url: URL(string: "https://evil.example/steal")!, statusCode: 200, httpVersion: nil, headerFields: nil)!
            return (Data(#"{"files":[],"branchSummary":null}"#.utf8), response)
        }
        do {
            _ = try await client.loadStatus(repositoryID: "repo-1", shareID: "share-1")
            XCTFail("Foreign-host responses must be rejected.")
        } catch { XCTAssertEqual(error as? NativeShareGitError, .invalidResponse) }
    }

    private func makeSettings() -> HanasandDesktopSettings {
        var settings = HanasandDesktopSettings()
        settings.apiBaseURL = "https://api.hanasand.com/api"
        settings.aiAPIURL = "https://api.hanasand.com/api/tools/ai"
        settings.userID = "user-7"
        settings.authToken = "session-token"
        return settings
    }

    private func response(for requestURL: URL, status: Int = 200) throws -> HTTPURLResponse {
        try XCTUnwrap(HTTPURLResponse(url: requestURL, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]))
    }

    private static let repositoryJSON = #"{"id":"repo-1","ownerId":"user-7","accessScope":"owned","name":"repo","fullName":"owner/repo","branch":"main","defaultBranch":"main","sourcePath":"","sourceUrl":"https://github.com/owner/repo/tree/main","authMode":"github_token","authHint":"Imported with temporary token.","syncStatus":"syncing","lastSyncedAt":null,"lastSyncError":null,"syncHistory":[{"timestamp":"2026-01-01T00:00:00Z","status":"syncing","source":"import","message":"Repository fetched."}],"stackType":"unknown","stackReason":"No supported deploy contract.","stackSupported":false,"files":[{"path":"README.md","name":"README.md","content":"hello"}],"truncated":false,"importedAt":"2026-01-01T00:00:00Z","credential":{"provider":"github_pat","hasCredential":false,"tokenHint":null,"attachedAt":null,"lastUsedAt":null,"lastValidatedAt":null}}"#
}

private final class GitRequestRecorder: @unchecked Sendable {
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
