import Foundation
import XCTest
@testable import Hanasand

private actor ChatGPTPromptTransport {
    private let replies: [(Data, Int)]
    private var requestsValue: [URLRequest] = []

    init(_ replies: [(Data, Int)]) { self.replies = replies }

    func send(_ request: URLRequest) throws -> (Data, URLResponse) {
        requestsValue.append(request)
        let value = replies[min(requestsValue.count - 1, replies.count - 1)]
        return (value.0, HTTPURLResponse(url: request.url!, statusCode: value.1, httpVersion: "HTTP/1.1", headerFields: nil)!)
    }

    func requests() -> [URLRequest] { requestsValue }
}

final class ChatGPTPromptPortalClientTests: XCTestCase {
    func testMembershipReadAndActivityUseAuthenticatedWebsiteContracts() async throws {
        let transport = ChatGPTPromptTransport([
            (Data(#"{"organizations":[{"slug":"Hanasand","lifecycle_status":"active"}]}"#.utf8), 200),
            (Data(#"{"items":[{"id":"b","conversationId":"chat 1","threadId":"chatgpt-chat 1","prompt":"later","status":"queued","priority":"next","createdAt":"2026-10-24T10:01:00Z"},{"id":"other","conversationId":"other","threadId":"chatgpt-other","prompt":"ignore","status":"done","createdAt":"2026-10-24T10:00:00Z"},{"id":"a","conversationId":"chat 1","threadId":"chatgpt-chat 1","prompt":"first","status":"done","createdAt":"2026-10-24T10:00:00Z","result":"answer"}]}"#.utf8), 200),
        ])
        let client = try ChatGPTPromptPortalClient(settings: settings(), send: { request in try await transport.send(request) })

        let isMember = try await client.hasActiveHanasandMembership()
        XCTAssertTrue(isMember)
        let items = try await client.loadActivity(conversationID: "chat 1")
        XCTAssertEqual(items.map(\.id), ["a", "b"])

        let requests = await transport.requests()
        XCTAssertEqual(requests.map { $0.url?.host }, ["identity.hanasand.com", "hanasand.com"])
        XCTAssertEqual(requests.map { $0.url?.path }, ["/api/organizations", "/api/prompt"])
        XCTAssertEqual(requests[1].url?.query, "conversationId=chat%201&threadId=chatgpt-chat%201")
        for request in requests {
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-token")
            XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "user-1")
            XCTAssertFalse(request.httpShouldHandleCookies)
        }
    }

    func testSubmitEncodesPromptThreadPriorityAndContextAsMultipartFields() async throws {
        let accepted = Data(#"{"items":[{"id":"job-1","conversationId":"chat-1","threadId":"chatgpt-chat-1","prompt":"Question","status":"queued","priority":"next","createdAt":"2026-10-24T10:00:00Z"}]}"#.utf8)
        let transport = ChatGPTPromptTransport([(accepted, 202)])
        let client = try ChatGPTPromptPortalClient(settings: settings(), send: { request in try await transport.send(request) })
        let context = [ChatGPTPromptContextMessage(role: "user", content: "Earlier question"),
                       ChatGPTPromptContextMessage(role: "assistant", content: "Earlier answer", modelName: "Hanasand GPT",
                           files: [.init(itemId: "prior-job", fileId: "file-1")])]

        let items = try await client.submit(prompt: "Question", conversationID: "chat-1", context: context)
        XCTAssertEqual(items.first?.id, "job-1")

        let requests = await transport.requests()
        let request = try XCTUnwrap(requests.first)
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.url?.absoluteString, "https://hanasand.com/api/prompt")
        XCTAssertTrue(request.value(forHTTPHeaderField: "Content-Type")?.hasPrefix("multipart/form-data; boundary=") == true)
        let body = String(decoding: try XCTUnwrap(request.httpBody), as: UTF8.self)
        XCTAssertTrue(body.contains("name=\"prompt\"\r\n\r\nQuestion"))
        XCTAssertTrue(body.contains("name=\"conversationId\"\r\n\r\nchat-1"))
        XCTAssertTrue(body.contains("name=\"threadId\"\r\n\r\nchatgpt-chat-1"))
        XCTAssertTrue(body.contains("name=\"priority\"\r\n\r\nnext"))
        XCTAssertTrue(body.contains("name=\"context\""))
        XCTAssertTrue(body.contains("Earlier question"))
        XCTAssertTrue(body.contains("Earlier answer"))
        XCTAssertTrue(body.contains("\"itemId\":\"prior-job\""))
        XCTAssertTrue(body.contains("\"fileId\":\"file-1\""))
        XCTAssertFalse(body.contains("\"modelName\":null"))
    }

    func testMembershipMustBeActiveAndUnsupportedQueueStatusesAreRejected() async throws {
        let inactive = ChatGPTPromptTransport([(Data(#"{"organizations":[{"slug":"hanasand","lifecycleStatus":"deleted"}]}"#.utf8), 200)])
        let client = try ChatGPTPromptPortalClient(settings: settings(), send: { request in try await inactive.send(request) })
        let isMember = try await client.hasActiveHanasandMembership()
        XCTAssertFalse(isMember)

        let invalid = Data(#"{"items":[{"id":"job","status":"pending","prompt":"Question"}]}"#.utf8)
        let malformed = ChatGPTPromptTransport([(invalid, 200)])
        let invalidClient = try ChatGPTPromptPortalClient(settings: settings(), send: { request in try await malformed.send(request) })
        do {
            _ = try await invalidClient.loadActivity(conversationID: "chat-1")
            XCTFail("Expected unknown queue status to be rejected")
        } catch { XCTAssertTrue(error is DecodingError) }
    }

    private func settings() -> HanasandDesktopSettings {
        var value = HanasandDesktopSettings()
        value.websiteBaseURL = "https://hanasand.com"
        value.apiBaseURL = "https://api.hanasand.com/api"
        value.userID = "user-1"
        value.authToken = "test-token"
        return value
    }
}
