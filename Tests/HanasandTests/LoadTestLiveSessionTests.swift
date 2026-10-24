import Foundation
import XCTest
@testable import Hanasand

@MainActor
final class LoadTestLiveSessionTests: XCTestCase {
    func testParserAcceptsWebsiteEventsAndBoundsText() throws {
        guard case .join(let participants) = try LoadTestLiveEventParser.parse("{\"type\":\"join\",\"participants\":3}") else { return XCTFail("Expected a join event") }
        XCTAssertEqual(participants, 3)
        guard case .log(let log) = try LoadTestLiveEventParser.parse("{\"type\":\"update\",\"data\":{\"type\":\"log\",\"message\":\"hello\"}}") else { return XCTFail("Expected a log event") }
        XCTAssertEqual(log, "hello")
        guard case .error(let error) = try LoadTestLiveEventParser.parse("{\"type\":\"update\",\"data\":{\"type\":\"error\",\"message\":\"bad\"}}") else { return XCTFail("Expected an error event") }
        XCTAssertEqual(error, "bad")
        guard case .done(let code, _, let duration) = try LoadTestLiveEventParser.parse("{\"type\":\"update\",\"data\":{\"type\":\"done\",\"code\":0,\"durationMs\":12}}") else { return XCTFail("Expected a done event") }
        XCTAssertEqual(code, 0)
        XCTAssertEqual(duration, 12)
        let long = String(repeating: "x", count: 9_000)
        let frame = try JSONSerialization.data(withJSONObject: ["type": "update", "data": ["type": "log", "message": long]])
        guard case .log(let bounded) = try LoadTestLiveEventParser.parse(String(decoding: frame, as: UTF8.self)) else { return XCTFail("Expected a log event") }
        XCTAssertEqual(bounded.count, 8_000)
    }

    func testParserRejectsMalformedOversizedAndInvalidCounts() throws {
        for frame in ["not json", String(repeating: "x", count: LoadTestLiveEventParser.maximumFrameBytes + 1), "{\"type\":\"join\",\"participants\":-1}", "{\"type\":\"join\",\"participants\":true}", "{\"type\":\"update\",\"data\":{\"type\":\"done\",\"code\":true}}"] {
            XCTAssertThrowsError(try LoadTestLiveEventParser.parse(frame), "Frame should be rejected")
        }
    }

    func testJoinRequiresManualReviewOwnAccountAndSafeURL() throws {
        let socket = FakeLoadTestLiveSocket()
        let session = LoadTestLiveSession(makeSocket: { socket })
        let base = URL(string: "https://api.synthetic.invalid/api")!

        XCTAssertFalse(session.join(apiBaseURL: base, id: "run-1", reviewed: false, hasAuth: true, canWrite: true, isImpersonating: false))
        XCTAssertFalse(session.join(apiBaseURL: base, id: "run-1", reviewed: true, hasAuth: true, canWrite: false, isImpersonating: true))
        XCTAssertFalse(session.join(apiBaseURL: URL(string: "http://api.synthetic.invalid/api")!, id: "run-1", reviewed: true, hasAuth: true, canWrite: true, isImpersonating: false))
        XCTAssertFalse(session.join(apiBaseURL: base, id: "../other", reviewed: true, hasAuth: true, canWrite: true, isImpersonating: false))
        XCTAssertNil(socket.connectedURL)
    }

    func testJoinStreamsLiveEventsClosesAtDoneAndNeverReconnects() async throws {
        let socket = FakeLoadTestLiveSocket()
        let session = LoadTestLiveSession(makeSocket: { socket })
        XCTAssertTrue(session.join(apiBaseURL: URL(string: "https://api.synthetic.invalid/api")!, id: "run-4", reviewed: true, hasAuth: true, canWrite: true, isImpersonating: false))
        XCTAssertEqual(socket.connectedURL?.absoluteString, "wss://api.synthetic.invalid/api/ws/test/run-4")
        XCTAssertEqual(session.status, "Connecting to public stream…")

        socket.push("{\"type\":\"join\",\"participants\":7}")
        try await waitUntil { session.participants == 7 }
        socket.push("{\"type\":\"update\",\"data\":{\"type\":\"log\",\"message\":\"progress\"}}")
        try await waitUntil { session.logs == ["progress"] }
        socket.push("{\"type\":\"update\",\"data\":{\"type\":\"done\",\"code\":0,\"durationMs\":42,\"summary\":{\"requests\":4,\"duration\":{\"p95\":18}}}}")
        try await waitUntil { session.completionStatus == "done" }

        XCTAssertEqual(session.exitCode, 0)
        XCTAssertEqual(session.durationMilliseconds, 42)
        XCTAssertEqual(session.summary?.numberValue(for: ["duration", "p95"]), 18)
        XCTAssertEqual(session.status, "Run finished · stream closed")
        XCTAssertTrue(socket.didClose)
        XCTAssertEqual(socket.connectionCount, 1)
    }

    func testLeaveClosesSocketAndDoesNotReconnect() async throws {
        let socket = FakeLoadTestLiveSocket()
        let session = LoadTestLiveSession(makeSocket: { socket })
        XCTAssertTrue(session.join(apiBaseURL: URL(string: "https://api.synthetic.invalid/api")!, id: "run-5", reviewed: true, hasAuth: true, canWrite: true, isImpersonating: false))
        try await waitUntil { socket.waitingForMessage }

        session.stopListening()
        XCTAssertTrue(socket.didClose)
        XCTAssertEqual(session.status, "Stopped · join manually to listen again")
        XCTAssertEqual(socket.connectionCount, 1)
        socket.push("{\"type\":\"join\",\"participants\":10}")
        await Task.yield()
        XCTAssertNil(session.participants)
    }

    func testTotalSessionBytesAndOutputAreBounded() async throws {
        let socket = FakeLoadTestLiveSocket()
        let session = LoadTestLiveSession(makeSocket: { socket })
        XCTAssertTrue(session.join(apiBaseURL: URL(string: "https://api.synthetic.invalid/api")!, id: "run-6", reviewed: true, hasAuth: true, canWrite: true, isImpersonating: false))
        try await waitUntil { socket.waitingForMessage }
        let message = String(repeating: "x", count: 59_900)
        let data = try JSONSerialization.data(withJSONObject: ["type": "update", "data": ["type": "log", "message": message]])
        let frame = String(decoding: data, as: UTF8.self)
        XCTAssertLessThanOrEqual(frame.utf8.count, LoadTestLiveEventParser.maximumFrameBytes)
        for _ in 0..<36 { socket.push(frame) }
        try await waitUntil { session.status.contains("2 MiB session limit") }

        XCTAssertTrue(session.outputLimited)
        XCTAssertLessThanOrEqual(session.logs.count, 500)
        XCTAssertLessThanOrEqual(session.logs.reduce(0) { $0 + $1.utf16.count }, 128 * 1024)
        XCTAssertTrue(socket.didClose)
        XCTAssertEqual(socket.connectionCount, 1)
    }

    private func waitUntil(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<500 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for the fake public stream.")
    }
}

@MainActor
private final class FakeLoadTestLiveSocket: LoadTestLiveSocket {
    private var queue: [String] = []
    private var waiter: CheckedContinuation<String, Error>?
    private var closed = false
    private(set) var connectedURL: URL?
    private(set) var connectionCount = 0

    var didClose: Bool { closed }
    var waitingForMessage: Bool { waiter != nil }

    func connect(to url: URL) {
        connectedURL = url
        connectionCount += 1
    }

    func push(_ value: String) {
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        } else {
            queue.append(value)
        }
    }

    func receive() async throws -> String {
        if !queue.isEmpty { return queue.removeFirst() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { waiter = $0 }
    }

    func close() {
        closed = true
        if let waiter {
            self.waiter = nil
            waiter.resume(throwing: CancellationError())
        }
    }
}
