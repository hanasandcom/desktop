import Foundation
import XCTest
@testable import Hanasand

private actor ShareChatContextTransport {
    private(set) var requestsValue: [URLRequest] = []

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requestsValue.append(request)
        let body: String
        switch request.url?.path {
        case "/api/share/tree/share-1":
            body = #"[{"id":"root","name":"project-demo","type":"folder","children":[{"id":"src","name":"src","type":"folder","children":[{"id":"file-main","name":"main.swift","type":"file"},{"id":"file-util","name":"util.swift","type":"file"}]},{"id":"readme","name":"README.md","type":"file"}]}]"#
        case "/api/share/file-main":
            body = #"{"id":"file-main","path":"src/main.swift","content":"print(\"hello\")"}"#
        case "/api/share/file-util":
            body = #"{"id":"file-util","path":"src/util.swift","content":"func utility() {}"}"#
        case "/api/share/readme":
            body = ##"{"id":"readme","path":"README.md","content":"# Demo"}"##
        default: throw URLError(.badURL)
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        return (Data(body.utf8), response)
    }

    func requests() -> [URLRequest] { requestsValue }
}

final class ShareChatContextTests: XCTestCase {
    func testLoadsTreeAndBoundedFileTextWithAuthenticatedShareRequests() async throws {
        let transport = ShareChatContextTransport()
        let client = try ShareChatContextClient(settings: settings(), send: { request in
            try await transport.send(request)
        })

        let context = try await client.load(shareID: "share-1", selectedFileID: "file-main", selectedFilePath: "project-demo/src/main.swift", existingShareIDs: ["share-1", "other-share", "other-share"])
        XCTAssertEqual(context.shareID, "share-1")
        XCTAssertEqual(context.workspaceId, "share-1")
        XCTAssertEqual(context.workspaceKind, "share")
        XCTAssertEqual(context.shareIds, ["share-1", "other-share"])
        XCTAssertEqual(context.selectedFilePath, "project-demo/src/main.swift")
        XCTAssertEqual(context.treePaths, ["project-demo/src/main.swift", "project-demo/src/util.swift", "project-demo/README.md"])
        XCTAssertEqual(context.files.map(\.path), ["project-demo/src/main.swift", "project-demo/src/util.swift", "project-demo/README.md"])
        XCTAssertTrue(context.promptContext.contains("print(\"hello\")"))
        XCTAssertTrue(context.promptContext.contains("Workspace files:"))

        let requests = await transport.requests()
        XCTAssertEqual(requests.count, 4)
        XCTAssertEqual(requests.first?.url?.path, "/api/share/tree/share-1")
        XCTAssertEqual(requests.first?.url?.host, "cdn.hanasand.com")
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
    }

    func testConversationReceivesPersistentShareWorkspaceFieldsAndUniqueIDs() async throws {
        let transport = ShareChatContextTransport()
        let client = try ShareChatContextClient(settings: settings(), send: { request in
            try await transport.send(request)
        })
        let context = try await client.load(shareID: "share-1", selectedFilePath: "project-demo/src/main.swift")
        var conversation = DesktopAIConversation(id: "chat-1", ownerId: "user-1")
        conversation.shareIds = ["share-1", "existing"]
        context.apply(to: &conversation)

        XCTAssertEqual(conversation.workspaceId, "share-1")
        XCTAssertEqual(conversation.workspaceKind, "share")
        XCTAssertEqual(conversation.shareIds, ["share-1", "existing"])
        XCTAssertEqual(conversation.workspaceMeta["selectedFilePath"], .string("project-demo/src/main.swift"))
        XCTAssertEqual(conversation.persistencePayload()["workspaceId"], .string("share-1"))
    }

    func testRejectsMissingCredentialsImpersonationAndUnsafeContextBeforeRequests() async throws {
        var missing = settings()
        missing.authToken = ""
        XCTAssertThrowsError(try ShareChatContextClient(settings: missing))

        var impersonated = settings()
        impersonated.impersonatingUserID = "other-user"
        XCTAssertThrowsError(try ShareChatContextClient(settings: impersonated))

        let transport = ShareChatContextTransport()
        let client = try ShareChatContextClient(settings: settings(), send: { request in
            try await transport.send(request)
        })
        do {
            _ = try await client.load(shareID: "share-1", selectedFilePath: "../private.txt")
            XCTFail("Unsafe selected path must be rejected")
        } catch let error as ShareChatContextClient.ClientError {
            XCTAssertEqual(error, .invalidSelectedFilePath)
        }
        let sentRequests = await transport.requests()
        XCTAssertTrue(sentRequests.isEmpty)
    }

    private func settings() -> HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.apiBaseURL = "https://api.hanasand.com/api"
        value.cdnBaseURL = "https://cdn.hanasand.com/api"
        value.userID = "user-1"
        value.authToken = "test-token"
        return value
    }
}
