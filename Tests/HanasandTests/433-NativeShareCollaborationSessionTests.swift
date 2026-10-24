import XCTest
@testable import Hanasand

final class NativeShareCollaborationSessionTests: XCTestCase {
    private let identity = NativeShareCollaborationIdentity(shareID: "room-123", accountID: "account-7")

    private func makeSession(content: String = "base") throws -> NativeShareCollaborationSession {
        try NativeShareCollaborationSession(identity: identity, clientID: "client-a", userID: "account-7",
                                            displayName: "A", initialContent: content)
    }

    private func update(_ content: String, timestamp: String = "2026-10-24T12:00:00Z") -> String {
        let payload: [String: Any] = ["type": "update", "content": content, "timestamp": timestamp, "participants": 2]
        return String(data: try! JSONSerialization.data(withJSONObject: payload), encoding: .utf8)!
    }

    func testOverlappingRemoteEditPreservesDraftUntilExplicitResolution() throws {
        var session = try makeSession()
        let generation = try session.connect(identity: identity)
        _ = session.markConnected(identity: identity, generation: generation)
        XCTAssertEqual(try session.edit("local v1"), [.edit(content: "local v1")])
        XCTAssertEqual(try session.edit("local v2"), [])

        _ = session.receive(update("remote"), identity: identity, generation: generation)
        XCTAssertEqual(session.localContent, "local v2")
        XCTAssertEqual(session.conflict?.remoteContent, "remote")
        XCTAssertEqual(session.saveState, .queued)
        XCTAssertEqual(session.keepLocalConflict(), [.edit(content: "local v2")])
        XCTAssertNil(session.conflict)
        XCTAssertEqual(session.persistedContent, "remote")

        _ = session.receive(#"{"type":"ack","content":"local v2"}"#, identity: identity, generation: generation)
        XCTAssertEqual(session.persistedContent, "local v2")
        XCTAssertEqual(session.saveState, .saved)
    }

    func testUseRemoteConflictDiscardsDraftOnlyAfterExplicitChoice() throws {
        var session = try makeSession()
        let generation = try session.connect(identity: identity)
        _ = session.markConnected(identity: identity, generation: generation)
        _ = try session.edit("draft")
        _ = session.receive(update("remote"), identity: identity, generation: generation)

        session.useRemoteConflict()
        XCTAssertEqual(session.localContent, "remote")
        XCTAssertEqual(session.persistedContent, "remote")
        XCTAssertNil(session.conflict)
        XCTAssertEqual(session.saveState, .saved)
    }

    func testDisconnectReconnectSendsOnlyNewestQueuedSnapshot() throws {
        var session = try makeSession()
        let firstGeneration = try session.connect(identity: identity)
        _ = session.markConnected(identity: identity, generation: firstGeneration)
        XCTAssertEqual(try session.edit("first"), [.edit(content: "first")])
        XCTAssertEqual(try session.edit("second"), [])
        session.disconnect(identity: identity, generation: firstGeneration)
        XCTAssertEqual(session.saveState, .queued)

        let secondGeneration = try session.connect(identity: identity)
        XCTAssertGreaterThan(secondGeneration, firstGeneration)
        let outbound = session.markConnected(identity: identity, generation: secondGeneration)
        XCTAssertEqual(outbound, [.hello(clientID: "client-a", userID: "account-7", displayName: "A"), .edit(content: "second")])
        XCTAssertEqual(session.saveState, .saving)
    }

    func testReconnectRetriesInFlightSnapshotEvenWhenDraftReturnsToBaseline() throws {
        var session = try makeSession()
        let firstGeneration = try session.connect(identity: identity)
        _ = session.markConnected(identity: identity, generation: firstGeneration)
        XCTAssertEqual(try session.edit("possibly-delivered"), [.edit(content: "possibly-delivered")])
        XCTAssertEqual(try session.edit("base"), [])
        session.disconnect(identity: identity, generation: firstGeneration)
        XCTAssertEqual(session.saveState, .queued)

        let secondGeneration = try session.connect(identity: identity)
        let outbound = session.markConnected(identity: identity, generation: secondGeneration)
        XCTAssertEqual(outbound.last, .edit(content: "base"))
    }

    func testMalformedAndStaleSocketEventsCannotMutateDocument() throws {
        var session = try makeSession()
        let oldGeneration = try session.connect(identity: identity)
        _ = session.markConnected(identity: identity, generation: oldGeneration)
        let newGeneration = try session.connect(identity: identity)
        _ = session.markConnected(identity: identity, generation: newGeneration)

        _ = session.receive(update("old callback"), identity: identity, generation: oldGeneration)
        XCTAssertEqual(session.localContent, "base")
        _ = session.receive("not-json", identity: identity, generation: newGeneration)
        XCTAssertEqual(session.localContent, "base")
        XCTAssertEqual(session.saveState, .saved)
        XCTAssertNotNil(session.lastError)

        _ = session.receive(update("fresh", timestamp: "2026-10-24T12:01:00Z"), identity: identity, generation: newGeneration)
        _ = session.receive(update("older", timestamp: "2026-10-24T12:00:00Z"), identity: identity, generation: newGeneration)
        XCTAssertEqual(session.localContent, "fresh")
    }

    func testAccountAndRoomIdentityFenceCallbacksAndResetRoomState() throws {
        var session = try makeSession()
        let generation = try session.connect(identity: identity)
        _ = session.markConnected(identity: identity, generation: generation)
        let otherAccount = NativeShareCollaborationIdentity(shareID: "room-123", accountID: "account-8")
        XCTAssertThrowsError(try session.connect(identity: otherAccount))
        _ = session.receive(update("wrong account"), identity: otherAccount, generation: generation)
        XCTAssertEqual(session.localContent, "base")

        let otherRoom = NativeShareCollaborationIdentity(shareID: "room-456", accountID: "account-7")
        let nextGeneration = try session.connect(identity: otherRoom)
        XCTAssertEqual(session.identity, otherRoom)
        XCTAssertNotEqual(nextGeneration, generation)
        _ = session.markConnected(identity: otherRoom, generation: nextGeneration)
        _ = session.receive(update("old room"), identity: identity, generation: nextGeneration)
        XCTAssertEqual(session.localContent, "")
    }

    func testProtocolFramesAndPresenceUseWebsiteWireNames() throws {
        let url = try NativeShareCollaborationProtocol.socketURL(apiBaseURL: "wss://api.hanasand.com/api/ws", shareID: "room-123")
        XCTAssertEqual(url.absoluteString, "wss://api.hanasand.com/api/ws/share/room-123")
        let parsed = try NativeShareCollaborationProtocol.parse(#"{"type":"join","participants":1,"users":[{"clientId":"client-b","userId":"account-8","displayName":"B","cursorLine":2,"cursorColumn":4}]}"#)
        guard case let .join(participants, users) = parsed else { return XCTFail("Expected join event") }
        XCTAssertEqual(participants, 1)
        XCTAssertEqual(users.first?.clientID, "client-b")
        XCTAssertEqual(users.first?.userID, "account-8")
    }
}
