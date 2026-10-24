import Foundation
import XCTest

@testable import Hanasand

@MainActor
final class SupportLiveSessionTests: XCTestCase {
    func testSocketAddressAndAuthKeepCredentialsOutOfURL() throws {
        let url = try SupportLiveProtocol.socketURL(apiBaseURL: "https://support.example.test/api/")
        XCTAssertEqual(url.absoluteString, "wss://support.example.test/api/ws/support")
        XCTAssertFalse(url.absoluteString.contains("session-secret"))
        XCTAssertEqual(try SupportLiveProtocol.originHeader(websiteBaseURL: "https://www.hanasand.com/"), "https://www.hanasand.com")

        let frame = try SupportLiveProtocol.authFrame(userID: "agent.test", token: "session-secret", impersonationToken: "imp-secret")
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: String])
        XCTAssertEqual(payload["type"], "auth")
        XCTAssertEqual(payload["id"], "agent.test")
        XCTAssertEqual(payload["token"], "session-secret")
        XCTAssertEqual(payload["impersonationToken"], "imp-secret")
        XCTAssertThrowsError(try SupportLiveProtocol.socketURL(apiBaseURL: "http://support.example.test/api"))
        XCTAssertThrowsError(try SupportLiveProtocol.authFrame(userID: "agent", token: ""))
    }

    func testMockSocketMarksLiveOnlyAfterReadyAndRefreshesOnChanged() async throws {
        let socket = MockSupportLiveSocket()
        let session = SupportLiveSession(makeSocket: { socket })
        var changes = 0
        session.start(apiBaseURL: "https://support.example.test/api", websiteBaseURL: "https://hanasand.com",
                      userID: "agent.test", token: "session-secret") {
            changes += 1
        }
        for _ in 0..<20 where socket.sent.isEmpty { await Task.yield() }
        XCTAssertEqual(socket.request?.url?.absoluteString, "wss://support.example.test/api/ws/support")
        XCTAssertEqual(socket.request?.value(forHTTPHeaderField: "Origin"), "https://hanasand.com")
        let auth = try XCTUnwrap(socket.sent.first)
        XCTAssertEqual(try SupportLiveProtocol.frameType(auth), "auth")
        XCTAssertTrue(auth.contains("session-secret"))
        XCTAssertFalse(socket.request?.url?.absoluteString.contains("session-secret") ?? true)

        socket.push(#"{"type":"changed"}"#)
        await Task.yield()
        XCTAssertEqual(changes, 0)
        socket.push(#"{"type":"ready"}"#)
        for _ in 0..<20 where session.status != .live { await Task.yield() }
        XCTAssertEqual(session.status, .live)
        XCTAssertEqual(changes, 1)
        socket.push(#"{"type":"changed","id":"ticket"}"#)
        for _ in 0..<20 where changes != 2 { await Task.yield() }
        XCTAssertEqual(changes, 2)
        XCTAssertFalse(socket.closed)
        session.stop()
        XCTAssertEqual(session.status, .idle)
        XCTAssertTrue(socket.closed)
    }
}

@MainActor
private final class MockSupportLiveSocket: SupportLiveSocketTransport {
    private var pending: CheckedContinuation<String, Error>?
    private var queued: [String] = []
    private(set) var sent: [String] = []
    private(set) var request: URLRequest?
    private(set) var closed = false
    var closeCode: URLSessionWebSocketTask.CloseCode { .invalid }

    func connect(request: URLRequest) { self.request = request }
    func send(_ text: String) async throws { sent.append(text) }
    func receive() async throws -> String {
        if !queued.isEmpty { return queued.removeFirst() }
        return try await withCheckedThrowingContinuation { pending = $0 }
    }
    func push(_ text: String) {
        if let pending { self.pending = nil; pending.resume(returning: text) }
        else { queued.append(text) }
    }
    func close() {
        closed = true
        if let pending { self.pending = nil; pending.resume(throwing: SupportLiveError.socketUnavailable) }
    }
}
