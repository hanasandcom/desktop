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
        let guestFrame = try SupportLiveProtocol.guestAuthFrame(ticket: String(repeating: "a", count: 64))
        let guestPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(guestFrame.utf8)) as? [String: String])
        XCTAssertEqual(guestPayload, ["type": "auth", "ticket": String(repeating: "a", count: 64)])
        XCTAssertThrowsError(try SupportLiveProtocol.guestAuthFrame(ticket: "short"))
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

    func testGuestSessionUsesFreshTicketForReconnectAndRefreshesChanged() async throws {
        var sockets: [MockSupportLiveSocket] = []
        var ticketRequestCount = 0
        var refreshes = 0
        let session = SupportLiveSession(makeSocket: {
            let socket = MockSupportLiveSocket()
            sockets.append(socket)
            return socket
        }, waitBeforeRetry: { _ in })
        session.startGuest(apiBaseURL: "https://support.example.test/api", websiteBaseURL: "https://hanasand.com",
                           connectTicket: {
            ticketRequestCount += 1
            return String(repeating: ticketRequestCount == 1 ? "b" : "c", count: 64)
        }) {
            refreshes += 1
        }

        await waitUntil { sockets.first?.sent.isEmpty == false }
        let first = try XCTUnwrap(sockets.first)
        XCTAssertEqual(first.request?.value(forHTTPHeaderField: "Origin"), "https://hanasand.com")
        let firstAuth = try XCTUnwrap(first.sent.first)
        XCTAssertEqual(try SupportLiveProtocol.frameType(firstAuth), "auth")
        XCTAssertEqual(try authPayload(firstAuth), ["type": "auth", "ticket": String(repeating: "b", count: 64)])
        XCTAssertFalse(first.request?.url?.absoluteString.contains(String(repeating: "b", count: 64)) ?? true)

        first.push(#"{"type":"ready"}"#)
        await waitUntil { session.status == .live && refreshes == 1 }
        first.push(#"{"type":"changed","id":"conversation"}"#)
        await waitUntil { refreshes == 2 }
        first.failReceive()
        await waitUntil { sockets.count == 2 && sockets[1].sent.isEmpty == false }

        XCTAssertEqual(ticketRequestCount, 2)
        let secondAuth = try XCTUnwrap(sockets[1].sent.first)
        XCTAssertEqual(try authPayload(secondAuth), ["type": "auth", "ticket": String(repeating: "c", count: 64)])
        XCTAssertTrue(first.closed)
        sockets[1].push(#"{"type":"ready"}"#)
        await waitUntil { session.status == .live }
        session.stop()
        XCTAssertTrue(sockets[1].closed)
    }

    func testGuestTicketFailureBecomesAvailableForManualRefreshRetry() async throws {
        var sockets: [MockSupportLiveSocket] = []
        var ticketRequests = 0
        let session = SupportLiveSession(makeSocket: {
            let socket = MockSupportLiveSocket()
            sockets.append(socket)
            return socket
        }, waitBeforeRetry: { _ in })
        session.startGuest(apiBaseURL: "https://support.example.test/api", websiteBaseURL: "https://hanasand.com",
                           connectTicket: {
            ticketRequests += 1
            throw SupportDeskClientError.requestFailed(503, "Support is unavailable. Refresh to try again.")
        }, changed: {})
        await waitUntil { session.status == .unavailable }
        XCTAssertEqual(ticketRequests, 5)
        XCTAssertTrue(sockets.allSatisfy(\.closed))

        session.startGuest(apiBaseURL: "https://support.example.test/api", websiteBaseURL: "https://hanasand.com",
                           connectTicket: { String(repeating: "d", count: 64) }, changed: {})
        await waitUntil { sockets.count == 6 && sockets[5].sent.isEmpty == false }
        sockets[5].push(#"{"type":"ready"}"#)
        await waitUntil { session.status == .live }
        XCTAssertEqual(try authPayload(try XCTUnwrap(sockets[5].sent.first)),
                       ["type": "auth", "ticket": String(repeating: "d", count: 64)])
        session.stop()
    }

    private func authPayload(_ frame: String) throws -> [String: String] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: String])
    }

    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<2_000 {
            if condition() { return }
            await Task.yield()
        }
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
    func failReceive() {
        guard let pending else { return }
        self.pending = nil
        pending.resume(throwing: SupportLiveError.socketUnavailable)
    }
    func close() {
        closed = true
        if let pending { self.pending = nil; pending.resume(throwing: SupportLiveError.socketUnavailable) }
    }
}
