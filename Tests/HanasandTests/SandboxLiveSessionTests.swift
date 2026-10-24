import Foundation
import XCTest

@testable import Hanasand

@MainActor
final class SandboxLiveSessionTests: XCTestCase {
    private let api = URL(string: "https://browser.example.test/api")!

    func testRequestUsesAuthenticatedWebSocketWithoutCookies() throws {
        let request = try SandboxLiveProtocol.request(
            apiBaseURL: api,
            userID: "owner.test",
            token: "session-token",
            isImpersonating: false,
            sessionID: "regular-123e4567-e89b-12d3-a456-426614174000"
        )

        XCTAssertEqual(request.url?.absoluteString, "wss://browser.example.test/api/ws/browser/regular-123e4567-e89b-12d3-a456-426614174000")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer session-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "id"), "owner.test")
        XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
        XCTAssertFalse(request.httpShouldHandleCookies)
    }

    func testTargetAndStartMessagePreserveServiceNetworkAndBounds() throws {
        let onion = try SandboxLiveProtocol.normalizedTarget("exampleaddress.onion/path")
        XCTAssertEqual(onion.absoluteString, "https://exampleaddress.onion/path")
        XCTAssertEqual(SandboxLiveProtocol.network(for: onion), "tor")

        var configuration = SandboxLiveConfiguration(
            userID: "owner.test", token: "token", target: "http://example.test/path", isImpersonating: false
        )
        configuration.width = 1_280
        configuration.height = 720
        let message = try SandboxLiveProtocol.startMessage(
            configuration: configuration,
            sessionID: "regular-123e4567-e89b-12d3-a456-426614174000",
            resumeToken: "resume-token",
            clientID: "desktop-client"
        )
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])
        XCTAssertEqual(payload["type"] as? String, "start")
        XCTAssertEqual(payload["target"] as? String, "http://example.test/path")
        XCTAssertEqual(payload["network"] as? String, "regular")
        XCTAssertEqual(payload["durationSeconds"] as? Int, 1_800)
        XCTAssertEqual(payload["width"] as? Int, 1_280)
        XCTAssertEqual(payload["height"] as? Int, 720)
        XCTAssertEqual(payload["profileTools"] as? [String], [])
    }

    func testRejectsImpersonationInvalidCredentialsAndInvalidTargets() throws {
        XCTAssertThrowsError(try SandboxLiveProtocol.request(
            apiBaseURL: api, userID: "owner.test", token: "token", isImpersonating: true,
            sessionID: "regular-123e4567-e89b-12d3-a456-426614174000"
        )) { XCTAssertEqual($0 as? SandboxLiveSessionError, .ownAccountRequired) }
        XCTAssertThrowsError(try SandboxLiveProtocol.request(
            apiBaseURL: api, userID: "owner.test", token: "token\r\nInjected: yes", isImpersonating: false,
            sessionID: "regular-123e4567-e89b-12d3-a456-426614174000"
        )) { XCTAssertEqual($0 as? SandboxLiveSessionError, .invalidCredentials) }
        XCTAssertThrowsError(try SandboxLiveProtocol.normalizedTarget("javascript:alert(1)")) {
            XCTAssertEqual($0 as? SandboxLiveSessionError, .invalidTarget)
        }
        XCTAssertThrowsError(try SandboxLiveProtocol.normalizedTarget("https://user:pass@example.test")) {
            XCTAssertEqual($0 as? SandboxLiveSessionError, .invalidTarget)
        }
    }

    func testEncodesSupportedNativeInputAndRejectsUnsupportedInput() throws {
        let click = try XCTUnwrap(SandboxLiveProtocol.inputMessage(type: "click", x: 21, y: 42, button: 2))
        let clickPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(click.utf8)) as? [String: Any])
        XCTAssertEqual(clickPayload["type"] as? String, "click")
        XCTAssertEqual(clickPayload["button"] as? Int, 2)
        let pointer = try XCTUnwrap(SandboxLiveProtocol.pointerMessage(
            event: "pointermove", x: 21, y: 42, button: 0, buttons: 1
        ))
        let pointerPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(pointer.utf8)) as? [String: Any])
        XCTAssertEqual(pointerPayload["type"] as? String, "pointer")
        XCTAssertEqual(pointerPayload["event"] as? String, "pointermove")
        XCTAssertEqual(pointerPayload["buttons"] as? Int, 1)
        XCTAssertNil(SandboxLiveProtocol.pointerMessage(event: "mousemove", x: 1, y: 2, button: 0, buttons: 0))
        XCTAssertNil(SandboxLiveProtocol.pointerMessage(event: "pointerup", x: 1, y: 2, button: -1, buttons: 0))
        XCTAssertNil(SandboxLiveProtocol.inputMessage(type: "click", x: -1, y: 2))
        XCTAssertNil(SandboxLiveProtocol.keyMessage(key: "Unidentified"))
        XCTAssertNotNil(SandboxLiveProtocol.keyMessage(key: "Enter"))
        XCTAssertNotNil(SandboxLiveProtocol.keyMessage(key: "a", command: true))
        XCTAssertNotNil(SandboxLiveProtocol.wheelMessage(x: 1, y: 2, deltaX: 0, deltaY: 24))
        XCTAssertNotNil(SandboxLiveProtocol.pasteMessage("clipboard text"))
    }

    func testDecodesBoundedJpegFrame() throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0xD9])
        let payload: [String: Any] = ["type": "frame", "image": jpeg.base64EncodedString(), "width": 1280, "height": 720]
        let (data, width, height) = try SandboxLiveProtocol.decodeFrame(payload)
        XCTAssertEqual(data, jpeg)
        XCTAssertEqual(width, 1_280)
        XCTAssertEqual(height, 720)
        XCTAssertThrowsError(try SandboxLiveProtocol.decodeFrame(["type": "frame", "image": "not-jpeg", "width": 1280, "height": 720]))
        XCTAssertThrowsError(try SandboxLiveProtocol.decodeFrame(["type": "frame", "image": jpeg.base64EncodedString(), "width": 9000, "height": 720]))
    }

    func testSessionStartsRendersFrameSerializesInputAndStops() async throws {
        let transport = MockSandboxLiveSocket()
        let session = SandboxLiveSession(transport: transport)
        let configuration = SandboxLiveConfiguration(
            userID: "owner.test", token: "token", target: "example.test", isImpersonating: false
        )

        await session.start(configuration)
        XCTAssertEqual(session.state, .starting)
        XCTAssertEqual(transport.request?.value(forHTTPHeaderField: "id"), "owner.test")
        let startPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(transport.messages.first).utf8)) as? [String: Any])
        XCTAssertEqual(startPayload["type"] as? String, "start")

        transport.enqueue(#"{"type":"ready"}"#)
        let frame = Data([0xFF, 0xD8, 0xFF, 0xD9]).base64EncodedString()
        transport.enqueue(#"{"type":"frame","image":"\#(frame)","width":1280,"height":720,"url":"https://example.test/","title":"Example"}"#)
        await waitFor { session.frameData != nil }
        XCTAssertEqual(session.state, .live)
        XCTAssertEqual(session.pageTitle, "Example")
        XCTAssertEqual(session.frameWidth, 1_280)

        session.sendInput(try XCTUnwrap(SandboxLiveProtocol.inputMessage(type: "click", x: 5, y: 6)))
        session.sendInput(try XCTUnwrap(SandboxLiveProtocol.keyMessage(key: "a")))
        await waitFor { transport.messages.count >= 3 }
        let sentTypes = try transport.messages.dropFirst().map { message -> String? in
            (try JSONSerialization.jsonObject(with: Data(message.utf8)) as? [String: Any])?["type"] as? String
        }
        XCTAssertEqual(sentTypes, ["click", "key"])

        await session.stop()
        XCTAssertEqual(session.state, .ended)
        XCTAssertEqual(transport.messages.last, #"{"type":"end"}"#)
        XCTAssertGreaterThanOrEqual(transport.closeCount, 1)
    }

    func testSessionResumesAnInterruptedSocketWithSameRunToken() async throws {
        let transport = MockSandboxLiveSocket()
        let session = SandboxLiveSession(transport: transport)
        await session.start(SandboxLiveConfiguration(
            userID: "owner.test", token: "token", target: "example.test", isImpersonating: false
        ))
        transport.enqueue(#"{"type":"ready"}"#)
        await waitFor { session.state == .live }

        transport.dropConnection()
        await waitFor { transport.messages.count >= 2 }
        let startPayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(transport.messages[0].utf8)) as? [String: Any])
        let resumePayload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(transport.messages[1].utf8)) as? [String: Any])
        XCTAssertEqual(resumePayload["type"] as? String, "resume")
        XCTAssertEqual(resumePayload["resumeToken"] as? String, startPayload["resumeToken"] as? String)

        transport.enqueue(#"{"type":"reconnected"}"#)
        await waitFor { session.state == .live }
        XCTAssertEqual(transport.request?.url?.path, "/api/ws/browser/\(startPayload["sessionId"] as? String ?? "missing")")
        await session.stop()
    }

    private func waitFor(_ predicate: @MainActor () -> Bool) async {
        for _ in 0..<100 where !predicate() {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

@MainActor
private final class MockSandboxLiveSocket: SandboxLiveSocketTransport {
    private(set) var request: URLRequest?
    private(set) var messages: [String] = []
    private(set) var closeCount = 0
    private var inbound: [String] = []
    private var waiting: [CheckedContinuation<String, Error>] = []

    func connect(request: URLRequest) { self.request = request }

    func send(_ text: String) async throws { messages.append(text) }

    func receive() async throws -> String {
        if !inbound.isEmpty { return inbound.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting.append($0) }
    }

    func enqueue(_ text: String) {
        if waiting.isEmpty { inbound.append(text) }
        else { waiting.removeFirst().resume(returning: text) }
    }

    func dropConnection() {
        let continuations = waiting
        waiting.removeAll()
        continuations.forEach { $0.resume(throwing: URLError(.networkConnectionLost)) }
    }

    func close() {
        closeCount += 1
        let continuations = waiting
        waiting.removeAll()
        continuations.forEach { $0.resume(throwing: CancellationError()) }
    }
}
