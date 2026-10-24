import Foundation
import XCTest
@testable import Hanasand

@MainActor
private final class FakeNativeShareSocket: NativeShareCollaborationSocketTransport {
    private(set) var request: URLRequest?
    private(set) var sent: [String] = []
    private var frames: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var isClosed = false
    var closed: Bool { isClosed }

    func connect(request: URLRequest) { self.request = request }

    func send(_ text: String) async throws {
        guard !isClosed else { throw NativeShareCollaborationProtocolError.invalidEndpoint }
        sent.append(text)
    }

    func receive() async throws -> String {
        if !frames.isEmpty { return frames.removeFirst() }
        if isClosed { throw NativeShareCollaborationProtocolError.invalidEndpoint }
        return try await withCheckedThrowingContinuation { waiters.append($0) }
    }

    func push(_ text: String) {
        if !waiters.isEmpty { waiters.removeFirst().resume(returning: text) }
        else { frames.append(text) }
    }

    func close() {
        isClosed = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume(throwing: NativeShareCollaborationProtocolError.invalidEndpoint) }
    }
}

@MainActor
final class NativeShareCollaborationLiveSessionTests: XCTestCase {
    func testConnectUsesAPIBaseAndSendsHelloThenAuthenticatedEdit() async throws {
        let socket = FakeNativeShareSocket()
        let live = NativeShareCollaborationLiveSession(makeSocket: { socket })
        live.start(identity: identity(), apiBaseURL: "https://api.hanasand.com/api", userID: "user-1",
                   token: "secret", displayName: "User", initialContent: "before")
        await eventually { socket.sent.count >= 1 }
        live.edit("after")
        await eventually { socket.sent.count >= 2 }

        XCTAssertEqual(socket.request?.url?.absoluteString, "wss://api.hanasand.com/api/ws/share/file-1")
        let hello = try json(socket.sent[0])
        XCTAssertEqual(hello["type"] as? String, "hello")
        XCTAssertEqual(hello["userId"] as? String, "user-1")
        let edit = try json(socket.sent[1])
        XCTAssertEqual(edit["type"] as? String, "edit")
        XCTAssertEqual(edit["userId"] as? String, "user-1")
        XCTAssertEqual(edit["token"] as? String, "secret")
        XCTAssertEqual(edit["id"] as? String, "file-1")
        XCTAssertEqual(edit["content"] as? String, "after")
        XCTAssertNil(edit["dpop"])
        live.stop()
    }

    func testReconnectReplaysLatestQueuedEdit() async throws {
        let first = FakeNativeShareSocket()
        let second = FakeNativeShareSocket()
        var sockets = [first, second]
        let live = NativeShareCollaborationLiveSession(makeSocket: { sockets.removeFirst() })
        live.start(identity: identity(), apiBaseURL: "https://api.hanasand.com/api", userID: "user-1",
                   token: "secret", displayName: "User", initialContent: "base")
        await eventually { first.sent.count == 1 }
        live.edit("latest")
        await eventually { first.sent.count == 2 }
        first.close()
        await eventually { second.sent.count >= 2 }
        let replayed = try json(second.sent[1])
        XCTAssertEqual(replayed["content"] as? String, "latest")
        live.stop()
    }

    func testCleanRemoteUpdateReplacesEditorSnapshot() async throws {
        let socket = FakeNativeShareSocket()
        let live = NativeShareCollaborationLiveSession(makeSocket: { socket })
        live.start(identity: identity(), apiBaseURL: "https://api.hanasand.com/api", userID: "user-1",
                   token: "secret", displayName: "User", initialContent: "base")
        await eventually { socket.sent.count == 1 }
        socket.push(#"{"type":"update","content":"remote","timestamp":"2026-10-24T10:00:00.000Z","participants":2}"#)
        await eventually { live.session?.localContent == "remote" }
        XCTAssertEqual(live.session?.persistedContent, "remote")
        live.stop()
    }

    func testSelectedFileChangeClosesOldRoomAndStartsNewIdentity() async throws {
        let first = FakeNativeShareSocket()
        let second = FakeNativeShareSocket()
        var sockets = [first, second]
        let live = NativeShareCollaborationLiveSession(makeSocket: { sockets.removeFirst() })
        live.start(identity: identity(), apiBaseURL: "https://api.hanasand.com/api", userID: "user-1",
                   token: "secret", displayName: "User", initialContent: "first")
        await eventually { first.sent.count == 1 }
        live.start(identity: NativeShareCollaborationIdentity(shareID: "file-2", accountID: "user-1"),
                   apiBaseURL: "https://api.hanasand.com/api", userID: "user-1", token: "secret",
                   displayName: "User", initialContent: "second")
        await eventually { second.sent.count == 1 }
        XCTAssertTrue(first.closed)
        XCTAssertEqual(live.session?.identity.shareID, "file-2")
        live.stop()
    }

    func testOverlappingRemoteUpdateRequiresExplicitResolution() async throws {
        let socket = FakeNativeShareSocket()
        let live = NativeShareCollaborationLiveSession(makeSocket: { socket })
        live.start(identity: identity(), apiBaseURL: "https://api.hanasand.com/api", userID: "user-1",
                   token: "secret", displayName: "User", initialContent: "base")
        await eventually { socket.sent.count == 1 }
        live.edit("mine")
        await eventually { socket.sent.count == 2 }
        socket.push(#"{"type":"update","content":"theirs","timestamp":"2026-10-24T10:00:00.000Z","participants":2}"#)
        await eventually { live.session?.conflict != nil }
        XCTAssertEqual(live.session?.localContent, "mine")
        XCTAssertEqual(live.session?.conflict?.remoteContent, "theirs")
        let sendsBeforeResolution = socket.sent.count
        live.keepLocalConflict()
        await eventually { socket.sent.count == sendsBeforeResolution + 1 }
        XCTAssertEqual(try json(socket.sent.last!)["content"] as? String, "mine")
        live.stop()
    }

    func testStaleIdentityAndMalformedFrameDoNotReplaceCurrentDraft() async throws {
        var core = try NativeShareCollaborationSession(identity: identity(), clientID: "client-1", userID: "user-1",
            displayName: "User", initialContent: "local")
        let generation = try core.connect(identity: identity())
        _ = core.markConnected(identity: identity(), generation: generation)
        let other = NativeShareCollaborationIdentity(shareID: "file-2", accountID: "user-1")
        _ = core.receive(#"{"type":"update","content":"stale","timestamp":"2026-10-24T10:00:00.000Z"}"#,
                         identity: other, generation: generation)
        _ = core.receive("{", identity: identity(), generation: generation)
        XCTAssertEqual(core.localContent, "local")
        XCTAssertNotNil(core.lastError)
        core.disconnect(identity: identity(), generation: generation)
        XCTAssertEqual(core.receive("{}", identity: identity(), generation: generation), [])
    }

    func testStopClosesSocketAndFencesLateCallbacks() async throws {
        let socket = FakeNativeShareSocket()
        let live = NativeShareCollaborationLiveSession(makeSocket: { socket })
        live.start(identity: identity(), apiBaseURL: "https://api.hanasand.com/api", userID: "user-1",
                   token: "secret", displayName: "User", initialContent: "base")
        await eventually { socket.sent.count == 1 }
        live.stop()
        XCTAssertEqual(live.connection, .disconnected)
        XCTAssertTrue(socket.closed)
        XCTAssertNil(live.session?.conflict)
        XCTAssertThrowsError(try NativeShareCollaborationProtocol.socketURL(apiBaseURL: "https://cdn.hanasand.com/api", shareID: "bad/id"))
    }

    private func identity() -> NativeShareCollaborationIdentity {
        NativeShareCollaborationIdentity(shareID: "file-1", accountID: "user-1")
    }

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func eventually(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<600 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}
