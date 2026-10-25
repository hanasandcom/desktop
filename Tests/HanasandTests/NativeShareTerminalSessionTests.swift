import Foundation
import XCTest
@testable import Hanasand

@MainActor
final class NativeShareTerminalSessionTests: XCTestCase {
    func testSocketURLMapsHTTPSAndPreservesSingleAPIPrefix() throws {
        let root = try NativeShareTerminalSession.socketURL(
            apiBaseURL: URL(string: "https://api.example.test")!,
            alias: "share-1", userID: "user.1", sessionID: "session_1"
        )
        XCTAssertEqual(root.absoluteString, "wss://api.example.test/api/ws/share/share-1/shell/user.1/session_1")

        let prefixed = try NativeShareTerminalSession.socketURL(
            apiBaseURL: URL(string: "https://api.example.test/api/")!,
            alias: "share-1", userID: "user-1", sessionID: "session-1"
        )
        XCTAssertEqual(prefixed.absoluteString, "wss://api.example.test/api/ws/share/share-1/shell/user-1/session-1")
    }

    func testSocketURLRejectsCredentialsQueryTraversalAndUnsafeIdentity() {
        let cases = [
            "https://user:password@api.example.test",
            "https://api.example.test?token=secret",
            "https://api.example.test/a/%2e%2e/private",
        ]
        for value in cases {
            XCTAssertThrowsError(try NativeShareTerminalSession.socketURL(
                apiBaseURL: URL(string: value)!, alias: "share-1", userID: "user-1", sessionID: "session-1"
            ), "Expected URL rejection for \(value)")
        }

        XCTAssertThrowsError(try NativeShareTerminalSession.socketURL(
            apiBaseURL: URL(string: "http://api.example.test")!, alias: "share-1", userID: "user-1", sessionID: "session-1"
        ))
        XCTAssertThrowsError(try NativeShareTerminalSession.socketURL(
            apiBaseURL: URL(string: "https://api.example.test")!, alias: "../other", userID: "user-1", sessionID: "session-1"
        ))
    }

    func testUpdateAndCredentialsMessagesSetStatusAndBoundParticipants() async throws {
        let socket = FakeNativeShareTerminalSocket()
        let session = makeSession(sockets: [socket])
        session.connect()
        socket.emit(try message([
            "type": "update", "content": "{\"content\":\"Preparing terminal\\nTerminal ready.\"}", "participants": 2,
        ]))
        await waitUntil { session.isConnected }

        XCTAssertTrue(session.isConnected)
        XCTAssertEqual(session.lifecycle, .ready)
        XCTAssertEqual(session.status, "Terminal ready.")
        XCTAssertEqual(session.participants, 2)
        XCTAssertEqual(session.output.count, 1)

        socket.emit(try message([
            "type": "terminal_credentials",
            "credentials": ["username": "vm-user", "password": "", "sshCommand": "ssh vm-user@example.test", "domain": "example.test"],
        ]))
        await waitUntil { session.credentials != nil }
        XCTAssertEqual(session.credentials?.username, "vm-user")
        XCTAssertEqual(session.status, "Terminal ready.")

        socket.emit(try message(["type": "join", "participants": 999]))
        await Task.yield()
        XCTAssertEqual(session.participants, 2)
    }

    func testInputUsesWebsiteTerminalInputEnvelopeAndRejectsOversizedPayload() async throws {
        let socket = FakeNativeShareTerminalSocket()
        let session = makeSession(sockets: [socket])
        session.connect()
        socket.emit(try message(["type": "update", "content": "ready", "participants": 1]))
        await waitUntil { session.isConnected }

        let accepted = await session.sendInput("pwd\r")
        XCTAssertTrue(accepted)
        let sent = try XCTUnwrap(socket.sentMessages.first)
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: String])
        XCTAssertEqual(payload["type"], "terminalInput")
        XCTAssertEqual(payload["content"], "pwd\r")

        let oversizedAccepted = await session.sendInput(String(repeating: "x", count: NativeShareTerminalSessionLimits.maximumInputBytes + 1))
        XCTAssertFalse(oversizedAccepted)
        XCTAssertEqual(socket.sentMessages.count, 1)
    }

    func testOutputRetentionIsBoundedAndKeepsNewestChunks() async throws {
        let socket = FakeNativeShareTerminalSocket()
        let session = makeSession(sockets: [socket])
        session.connect()
        for index in 0..<300 {
            socket.emit(try message(["type": "update", "content": "\(index):" + String(repeating: "x", count: 1_000)]))
        }
        await waitUntil { session.output.last?.hasPrefix("299:") == true }

        let retainedBytes = session.output.reduce(0) { $0 + $1.utf8.count }
        XCTAssertLessThanOrEqual(retainedBytes, NativeShareTerminalSessionLimits.maximumOutputBytes)
        XCTAssertLessThanOrEqual(session.output.count, NativeShareTerminalSessionLimits.maximumOutputChunks)
        XCTAssertTrue(session.output.last?.hasPrefix("299:") == true)
    }

    func testClearControlResetsOutputAndKeepsTextAfterTheLastClear() async throws {
        let socket = FakeNativeShareTerminalSocket()
        let session = makeSession(sockets: [socket])
        session.connect()
        socket.emit(try message(["type": "update", "content": "before clear", "participants": 1]))
        await waitUntil { session.output.last == "before clear" }

        socket.emit(try message(["type": "update", "content": "{\"content\":\"clear\\r\\n\\u001Bc$ \"}", "participants": 1]))
        await waitUntil { session.output.last == "$ " }

        XCTAssertEqual(session.output, ["$ "])
    }

    func testSocketCloseTransitionsToFailureAndClearsConnectedState() async throws {
        let socket = FakeNativeShareTerminalSocket()
        let scheduler = FakeNativeShareTerminalRetryScheduler()
        let session = makeSession(sockets: [socket], retryScheduler: scheduler)
        session.connect()
        socket.emit(try message(["type": "update", "content": "ready", "participants": 1]))
        await waitUntil { session.isConnected }
        socket.fail(.closed)
        await waitUntil { session.lifecycle == .failed && scheduler.pending.count == 1 }

        XCTAssertFalse(session.isConnected)
        XCTAssertEqual(session.status, "Terminal connection was lost.")
        XCTAssertNotNil(session.errorMessage)
    }

    func testReceiveCloseSchedulesOneSecondRetryOnSameSession() async throws {
        let firstSocket = FakeNativeShareTerminalSocket()
        let retrySocket = FakeNativeShareTerminalSocket()
        let scheduler = FakeNativeShareTerminalRetryScheduler()
        let session = makeSession(sockets: [firstSocket, retrySocket], retryScheduler: scheduler)
        let originalSessionID = session.sessionID
        session.connect()
        let originalGeneration = session.generation

        firstSocket.fail(.closed)
        await waitUntil { scheduler.pending.count == 1 && session.lifecycle == .failed }
        XCTAssertEqual(scheduler.pending[0].delayNanoseconds, NativeShareTerminalSession.reconnectDelayNanoseconds)

        scheduler.fire(0)
        await waitUntil { retrySocket.resumed }
        XCTAssertEqual(session.sessionID, originalSessionID)
        XCTAssertGreaterThan(session.generation, originalGeneration)
        XCTAssertEqual(session.lifecycle, .connecting)
    }

    func testManualReconnectReusesSessionIDAndOpensNewSocket() async {
        let firstSocket = FakeNativeShareTerminalSocket()
        let nextSocket = FakeNativeShareTerminalSocket()
        let scheduler = FakeNativeShareTerminalRetryScheduler()
        let session = makeSession(sockets: [firstSocket, nextSocket], retryScheduler: scheduler)
        let originalSessionID = session.sessionID
        session.connect()
        let originalGeneration = session.generation

        session.reconnect()
        await waitUntil { nextSocket.resumed }

        XCTAssertEqual(session.sessionID, originalSessionID)
        XCTAssertGreaterThan(session.generation, originalGeneration)
        XCTAssertTrue(firstSocket.isCancelled)
        XCTAssertEqual(session.lifecycle, .connecting)
    }

    func testRestartCreatesNewSessionIDAndReconnectsWithoutExecutingCommands() async {
        let firstSocket = FakeNativeShareTerminalSocket()
        let restartedSocket = FakeNativeShareTerminalSocket()
        let scheduler = FakeNativeShareTerminalRetryScheduler()
        let session = makeSession(sockets: [firstSocket, restartedSocket], retryScheduler: scheduler)
        let originalSessionID = session.sessionID
        session.connect()

        session.restart()
        await waitUntil { restartedSocket.resumed }

        XCTAssertNotEqual(session.sessionID, originalSessionID)
        XCTAssertTrue(firstSocket.isCancelled)
        XCTAssertEqual(session.lifecycle, .connecting)
        XCTAssertTrue(restartedSocket.sentMessages.isEmpty)
    }

    func testDisconnectCancelsPendingRetryAndPreventsReconnect() async {
        let firstSocket = FakeNativeShareTerminalSocket()
        let retrySocket = FakeNativeShareTerminalSocket()
        let scheduler = FakeNativeShareTerminalRetryScheduler()
        let session = makeSession(sockets: [firstSocket, retrySocket], retryScheduler: scheduler)
        session.connect()
        firstSocket.fail(.closed)
        await waitUntil { scheduler.pending.count == 1 && session.lifecycle == .failed }
        let disconnectedGeneration = session.generation

        session.disconnect()
        scheduler.fire(0, evenIfCancelled: true)
        await Task.yield()

        XCTAssertTrue(scheduler.pending[0].isCancelled)
        XCTAssertFalse(retrySocket.resumed)
        XCTAssertEqual(session.lifecycle, .closed)
        XCTAssertEqual(session.generation, disconnectedGeneration + 1)
    }

    func testDisconnectAndReconnectIgnoreOldGenerationEvents() throws {
        let oldSocket = FakeNativeShareTerminalSocket()
        let newSocket = FakeNativeShareTerminalSocket()
        let session = makeSession(sockets: [oldSocket, newSocket])
        session.connect()
        let oldGeneration = session.generation
        session.disconnect()
        session.connect()
        let newGeneration = session.generation
        XCTAssertGreaterThan(newGeneration, oldGeneration)

        session.handleMessage(try message(["type": "update", "content": "stale", "participants": 9]), generation: oldGeneration)
        XCTAssertEqual(session.lifecycle, .connecting)
        XCTAssertEqual(session.output, [])
        XCTAssertEqual(session.participants, 1)
    }

    func testInvalidMessageFailsSessionWithoutRetainingUnboundedData() async {
        let socket = FakeNativeShareTerminalSocket()
        let session = makeSession(sockets: [socket])
        session.connect()
        socket.emit(String(repeating: "x", count: NativeShareTerminalSessionLimits.maximumEventBytes + 1))
        await waitUntil { session.lifecycle == .failed }
        XCTAssertEqual(session.lifecycle, .failed)
        XCTAssertEqual(session.output, [])
    }

    private func makeSession(
        sockets: [FakeNativeShareTerminalSocket],
        retryScheduler: FakeNativeShareTerminalRetryScheduler? = nil
    ) -> NativeShareTerminalSession {
        var remaining = sockets
        return NativeShareTerminalSession(
            apiBaseURL: URL(string: "https://api.example.test")!,
            alias: "share-1",
            userID: "user-1",
            sessionID: "session-1",
            socketFactory: { _ in
                guard !remaining.isEmpty else { throw NativeShareTerminalTestError.noSocket }
                return remaining.removeFirst()
            },
            retryScheduler: retryScheduler.map { scheduler in
                { delay, action in scheduler.schedule(delay, action: action) }
            }
        )
    }

    private func message(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        return String(decoding: data, as: UTF8.self)
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100 where !condition() {
            await Task.yield()
        }
        XCTAssertTrue(condition(), file: file, line: line)
    }
}

@MainActor
private final class FakeNativeShareTerminalSocket: NativeShareTerminalSocket {
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var pending: [Result<String, Error>] = []
    private var cancelled = false
    private(set) var resumed = false
    private(set) var isCancelled = false
    private(set) var sentMessages: [String] = []

    func resume() { resumed = true }

    func send(_ text: String) async throws {
        guard !cancelled else { throw NativeShareTerminalTestError.closed }
        sentMessages.append(text)
    }

    func receive() async throws -> String {
        if !pending.isEmpty { return try pending.removeFirst().get() }
        return try await withCheckedThrowingContinuation { continuation in
            if cancelled {
                continuation.resume(throwing: NativeShareTerminalTestError.closed)
            } else {
                waiters.append(continuation)
            }
        }
    }

    func cancel() {
        guard !cancelled else { return }
        cancelled = true
        isCancelled = true
        settle(.failure(NativeShareTerminalTestError.closed))
    }

    func emit(_ message: String) { settle(.success(message)) }
    func fail(_ error: NativeShareTerminalTestError) { settle(.failure(error)) }

    private func settle(_ result: Result<String, Error>) {
        if waiters.isEmpty {
            pending.append(result)
        } else {
            waiters.removeFirst().resume(with: result)
        }
    }
}

@MainActor
private final class FakeNativeShareTerminalRetryScheduler {
    final class PendingRetry {
        let delayNanoseconds: UInt64
        let action: @MainActor () -> Void
        private(set) var isCancelled = false

        init(delayNanoseconds: UInt64, action: @escaping @MainActor () -> Void) {
            self.delayNanoseconds = delayNanoseconds
            self.action = action
        }

        func cancel() { isCancelled = true }
    }

    private(set) var pending: [PendingRetry] = []

    func schedule(
        _ delayNanoseconds: UInt64,
        action: @escaping @MainActor () -> Void
    ) -> NativeShareTerminalSession.RetryCancellation {
        let item = PendingRetry(delayNanoseconds: delayNanoseconds, action: action)
        pending.append(item)
        return { item.cancel() }
    }

    func fire(_ index: Int, evenIfCancelled: Bool = false) {
        guard pending.indices.contains(index) else { return }
        let item = pending[index]
        guard evenIfCancelled || !item.isCancelled else { return }
        item.action()
    }
}

private enum NativeShareTerminalTestError: Error {
    case closed
    case noSocket
}
