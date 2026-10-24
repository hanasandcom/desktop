import AppKit
import Combine
import Foundation

enum SandboxLiveSessionState: Equatable {
    case idle
    case connecting
    case starting
    case live
    case stopping
    case ended
    case failed(String)
}

enum SandboxLiveSessionError: LocalizedError, Equatable {
    case signInRequired
    case ownAccountRequired
    case invalidCredentials
    case invalidEndpoint
    case invalidTarget
    case invalidResponse
    case frameTooLarge
    case socketUnavailable
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to start a Sandbox session."
        case .ownAccountRequired: "Return to your own account to start a Sandbox session."
        case .invalidCredentials: "The current account credentials are invalid. Sign in again."
        case .invalidEndpoint: "Sandbox requires a valid secure browser service address."
        case .invalidTarget: "Enter a valid HTTP or HTTPS address."
        case .invalidResponse: "The Sandbox service returned an invalid response."
        case .frameTooLarge: "The Sandbox frame exceeded its size limit."
        case .socketUnavailable: "The Sandbox connection is unavailable."
        case .requestFailed(401): "Sign in again to start a Sandbox session."
        case .requestFailed(403): "Your account cannot start this Sandbox session."
        case .requestFailed: "The Sandbox service is unavailable. Try again."
        }
    }
}

struct SandboxLiveConfiguration {
    let userID: String
    let token: String
    let target: String
    let isImpersonating: Bool
    var apiBaseURL = URL(string: "https://browsers.hanasand.com/api")!
    var width = 1280
    var height = 720
    var durationSeconds = 1800
    var userAgent = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"
    var locale = "en-US"
    var timezoneId = "UTC"
    var platform = "Linux x86_64"
}

@MainActor
protocol SandboxLiveSocketTransport: AnyObject {
    func connect(request: URLRequest)
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

@MainActor
private final class URLSessionSandboxLiveSocket: SandboxLiveSocketTransport {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    private func makeSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }

    func connect(request: URLRequest) {
        let session = makeSession()
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(_ text: String) async throws {
        guard let task else { throw SandboxLiveSessionError.socketUnavailable }
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        guard let task else { throw SandboxLiveSessionError.socketUnavailable }
        switch try await task.receive() {
        case let .string(text): return text
        case .data: throw SandboxLiveSessionError.invalidResponse
        @unknown default: throw SandboxLiveSessionError.invalidResponse
        }
    }

    func close() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}

enum SandboxLiveProtocol {
    static let defaultAPIBaseURL = URL(string: "https://browsers.hanasand.com/api")!
    static let maximumTargetBytes = 2_048
    static let maximumFrameBytes = 12 * 1_024 * 1_024
    static let maximumFrameWidth = 3_840
    static let maximumFrameHeight = 2_160

    static func normalizedTarget(_ value: String) throws -> URL {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maximumTargetBytes else {
            throw SandboxLiveSessionError.invalidTarget
        }
        let candidate = trimmed.range(of: "^https?://", options: [.regularExpression, .caseInsensitive]) == nil
            ? "https://\(trimmed)" : trimmed
        guard let components = URLComponents(string: candidate),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.port.map({ (1...65_535).contains($0) }) ?? true,
              let url = components.url else {
            throw SandboxLiveSessionError.invalidTarget
        }
        return url
    }

    static func network(for target: URL) -> String {
        (target.host?.lowercased().hasSuffix(".onion") == true) ? "tor" : "regular"
    }

    static func request(apiBaseURL: URL = defaultAPIBaseURL, userID: String, token: String,
                        isImpersonating: Bool, sessionID: String) throws -> URLRequest {
        guard !isImpersonating else { throw SandboxLiveSessionError.ownAccountRequired }
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !credential.isEmpty else { throw SandboxLiveSessionError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw SandboxLiveSessionError.invalidCredentials
        }
        guard apiBaseURL.scheme?.lowercased() == "https", let host = apiBaseURL.host,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil,
              sessionID.range(of: "^(?:regular-)?[a-f0-9-]{36}$", options: .regularExpression) != nil else {
            throw SandboxLiveSessionError.invalidEndpoint
        }
        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.scheme = "wss"
        components?.path = "/" + [basePath, "ws", "browser", sessionID].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components?.url, url.scheme == "wss", url.host == host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw SandboxLiveSessionError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpShouldHandleCookies = false
        request.setValue("Bearer \(credential)", forHTTPHeaderField: "Authorization")
        request.setValue(user, forHTTPHeaderField: "id")
        return request
    }

    static func startMessage(configuration: SandboxLiveConfiguration, sessionID: String,
                             resumeToken: String, clientID: String) throws -> String {
        let target = try normalizedTarget(configuration.target)
        guard (320...3_840).contains(configuration.width), (320...2_160).contains(configuration.height),
              (60...1_800).contains(configuration.durationSeconds),
              configuration.userAgent.utf8.count <= 512,
              configuration.locale.utf8.count <= 64,
              configuration.timezoneId.utf8.count <= 128,
              configuration.platform.utf8.count <= 128,
              !resumeToken.isEmpty, !clientID.isEmpty else {
            throw SandboxLiveSessionError.invalidResponse
        }
        let payload: [String: Any] = [
            "type": "start", "sessionId": sessionID, "resumeToken": resumeToken,
            "network": network(for: target), "target": target.absoluteString,
            "durationSeconds": configuration.durationSeconds,
            "profileTools": [], "userAgent": configuration.userAgent,
            "width": configuration.width, "height": configuration.height,
            "locale": configuration.locale, "timezoneId": configuration.timezoneId,
            "platform": configuration.platform, "clientId": clientID,
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw SandboxLiveSessionError.invalidResponse }
        return text
    }

    static func inputMessage(type: String, x: Int, y: Int, button: Int = 0) -> String? {
        guard ["click", "pointer"].contains(type), x >= 0, y >= 0,
              x < maximumFrameWidth, y < maximumFrameHeight else { return nil }
        let payload: [String: Any] = ["type": type, "x": x, "y": y, "button": button]
        return try? jsonString(payload)
    }

    static func pointerMessage(event: String, x: Int, y: Int, button: Int, buttons: Int) -> String? {
        guard ["pointerdown", "pointermove", "pointerup", "pointercancel"].contains(event),
              (event == "pointermove" ? (-1...2).contains(button) : (0...2).contains(button)),
              (0...7).contains(buttons), x >= 0, y >= 0,
              x < maximumFrameWidth, y < maximumFrameHeight else { return nil }
        let payload: [String: Any] = [
            "type": "pointer", "event": event, "x": x, "y": y,
            "button": button, "buttons": buttons,
        ]
        return try? jsonString(payload)
    }

    static func keyMessage(key: String, command: Bool = false, control: Bool = false,
                           option: Bool = false, shift: Bool = false) -> String? {
        let supportedSpecialKeys: Set<String> = [
            "Enter", "Tab", "Backspace", "Delete", "Escape",
            "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
        ]
        guard (key.count == 1 || supportedSpecialKeys.contains(key)), key.utf8.count <= 64 else { return nil }
        let payload: [String: Any] = [
            "type": "key", "key": key, "metaKey": command, "ctrlKey": control,
            "altKey": option, "shiftKey": shift,
        ]
        return try? jsonString(payload)
    }

    static func wheelMessage(x: Int, y: Int, deltaX: Double, deltaY: Double) -> String? {
        guard x >= 0, y >= 0, x < maximumFrameWidth, y < maximumFrameHeight,
              deltaX.isFinite, deltaY.isFinite else { return nil }
        let payload: [String: Any] = ["type": "wheel", "x": x, "y": y, "deltaX": deltaX, "deltaY": deltaY]
        return try? jsonString(payload)
    }

    static func pasteMessage(_ text: String) -> String? {
        guard text.utf8.count <= 1_000_000 else { return nil }
        return try? jsonString(["type": "clipboard", "direction": "browser-to-remote", "text": text])
    }

    static func decodeFrame(_ payload: [String: Any]) throws -> (Data, Int, Int) {
        guard payload["type"] as? String == "frame",
              let encoded = payload["image"] as? String,
              encoded.utf8.count <= maximumFrameBytes * 4 / 3 + 8,
              let data = Data(base64Encoded: encoded), data.count <= maximumFrameBytes,
              data.starts(with: [0xFF, 0xD8, 0xFF]),
              let width = payload["width"] as? Int, (1...maximumFrameWidth).contains(width),
              let height = payload["height"] as? Int, (1...maximumFrameHeight).contains(height) else {
            throw SandboxLiveSessionError.invalidResponse
        }
        return (data, width, height)
    }

    private static func jsonString(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let text = String(data: data, encoding: .utf8) else { throw SandboxLiveSessionError.invalidResponse }
        return text
    }
}

@MainActor
final class SandboxLiveSession: ObservableObject {
    @Published private(set) var state: SandboxLiveSessionState = .idle
    @Published private(set) var frameData: Data?
    @Published private(set) var frameWidth = 0
    @Published private(set) var frameHeight = 0
    @Published private(set) var pageURL = ""
    @Published private(set) var pageTitle = ""
    @Published private(set) var serviceMessage = ""

    private let transport: SandboxLiveSocketTransport
    private var receiveTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var inputSendTask: Task<Void, Never>?
    private var sessionID: String?
    private var resumeToken: String?
    private var connectionRequest: URLRequest?
    private var isStopping = false

    init() {
        transport = URLSessionSandboxLiveSocket()
    }

    init(transport: SandboxLiveSocketTransport) {
        self.transport = transport
    }

    var isActive: Bool {
        switch state {
        case .connecting, .starting, .live, .stopping: true
        case .idle, .ended, .failed: false
        }
    }

    func start(_ configuration: SandboxLiveConfiguration) async {
        guard !isActive else { return }
        clearSession()
        let id = "regular-\(UUID().uuidString.lowercased())"
        do {
            _ = try SandboxLiveProtocol.normalizedTarget(configuration.target)
            guard configuration.width <= SandboxLiveProtocol.maximumFrameWidth,
                  configuration.height <= SandboxLiveProtocol.maximumFrameHeight else {
                throw SandboxLiveSessionError.invalidTarget
            }
            let request = try SandboxLiveProtocol.request(
                apiBaseURL: configuration.apiBaseURL,
                userID: configuration.userID,
                token: configuration.token,
                isImpersonating: configuration.isImpersonating,
                sessionID: id
            )
            let newResumeToken = UUID().uuidString.lowercased()
            let message = try SandboxLiveProtocol.startMessage(
                configuration: configuration,
                sessionID: id,
                resumeToken: newResumeToken,
                clientID: "desktop-\(UUID().uuidString.lowercased())"
            )
            sessionID = id
            resumeToken = newResumeToken
            connectionRequest = request
            state = .connecting
            transport.connect(request: request)
            receiveTask = Task { [weak self] in await self?.receiveMessages() }
            try await transport.send(message)
            guard !Task.isCancelled, sessionID == id else { return }
            state = .starting
            heartbeatTask = Task { [weak self] in await self?.sendHeartbeats() }
        } catch {
            fail(error)
        }
    }

    func stop() async {
        guard isActive else { transport.close(); state = .ended; return }
        isStopping = true
        state = .stopping
        heartbeatTask?.cancel()
        heartbeatTask = nil
        inputSendTask?.cancel()
        inputSendTask = nil
        if sessionID != nil { try? await transport.send(#"{"type":"end"}"#) }
        transport.close()
        receiveTask?.cancel()
        receiveTask = nil
        sessionID = nil
        resumeToken = nil
        connectionRequest = nil
        isStopping = false
        state = .ended
        serviceMessage = "Sandbox session ended."
    }

    func sendInput(_ message: String) {
        guard case .live = state else { return }
        let previous = inputSendTask
        inputSendTask = Task { [weak self] in
            await previous?.value
            guard let self else { return }
            guard case .live = state else { return }
            do { try await transport.send(message) }
            catch { fail(error) }
        }
    }

    private func receiveMessages() async {
        do {
            while !Task.isCancelled, sessionID != nil {
                let text: String
                do {
                    text = try await transport.receive()
                } catch {
                    guard !Task.isCancelled, !isStopping else { return }
                    guard await reconnect() else { fail(error); return }
                    continue
                }
                guard text.utf8.count <= SandboxLiveProtocol.maximumFrameBytes * 4 / 3 + 64 * 1_024 else {
                    throw SandboxLiveSessionError.frameTooLarge
                }
                guard let data = text.data(using: .utf8),
                      let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let type = payload["type"] as? String else {
                    throw SandboxLiveSessionError.invalidResponse
                }
                handle(payload, type: type)
            }
        } catch {
            guard !Task.isCancelled, !isStopping else { return }
            fail(error)
        }
    }

    private func handle(_ payload: [String: Any], type: String) {
        switch type {
        case "ready":
            state = .live
            serviceMessage = "Browser ready. The viewport refreshes after page changes and input."
        case "reconnected":
            state = .live
            serviceMessage = "Browser connection restored. The viewport refreshes after page changes and input."
        case "resume_unavailable":
            failMessage("The Sandbox session expired and can no longer be resumed. Start a new session.")
        case "frame":
            do {
                let (data, width, height) = try SandboxLiveProtocol.decodeFrame(payload)
                frameData = data
                frameWidth = width
                frameHeight = height
                pageURL = (payload["url"] as? String).map { String($0.prefix(2_048)) } ?? pageURL
                pageTitle = (payload["title"] as? String).map { String($0.prefix(512)) } ?? pageTitle
                state = .live
                serviceMessage = "Viewport updated · \(width) × \(height)"
            } catch { fail(error) }
        case "status":
            let reason = (payload["state"] as? String) ?? ""
            let message = (payload["message"] as? String) ?? ""
            serviceMessage = String((message.isEmpty ? reason : message).prefix(512))
            if ["quota_exhausted", "concurrency_limit", "run_exists", "failed"].contains(reason) {
                fail(SandboxLiveSessionError.requestFailed(reason == "quota_exhausted" ? 403 : 429))
            }
        case "error":
            let message = (payload["message"] as? String).map { String($0.prefix(512)) } ?? "The browser service rejected this session."
            failMessage(message)
        case "ended":
            heartbeatTask?.cancel()
            heartbeatTask = nil
            inputSendTask?.cancel()
            inputSendTask = nil
            sessionID = nil
            state = .ended
            serviceMessage = "Sandbox session ended."
            transport.close()
        case "stream_ready":
            // The service's tokenized stream URL is intentionally not opened. Native
            // interaction uses the authenticated frame/input channel on this socket.
            break
        case "pong":
            break
        default:
            break
        }
    }

    private func sendHeartbeats() async {
        while !Task.isCancelled, sessionID != nil {
            try? await Task.sleep(for: .seconds(10))
            guard !Task.isCancelled, sessionID != nil else { return }
            do { try await transport.send(#"{"type":"ping"}"#) }
            catch {
                transport.close()
                return
            }
        }
    }

    private func reconnect() async -> Bool {
        guard let request = connectionRequest, let resumeToken, sessionID != nil else { return false }
        let deadline = Date().addingTimeInterval(120)
        var attempt = 0
        transport.close()
        while !Task.isCancelled, !isStopping, sessionID != nil, Date() < deadline {
            state = .connecting
            serviceMessage = "Connection interrupted. Reconnecting to the isolated browser…"
            let delayMilliseconds = min(500 * (1 << min(attempt, 4)), 5_000)
            try? await Task.sleep(for: .milliseconds(delayMilliseconds))
            guard !Task.isCancelled, !isStopping, sessionID != nil else { return false }
            transport.connect(request: request)
            do {
                let payload: [String: Any] = ["type": "resume", "resumeToken": resumeToken]
                let data = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                guard let text = String(data: data, encoding: .utf8) else { throw SandboxLiveSessionError.invalidResponse }
                try await transport.send(text)
                state = .starting
                attempt += 1
                return true
            } catch {
                transport.close()
                attempt += 1
            }
        }
        return false
    }

    private func fail(_ error: Error) {
        failMessage((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
    }

    private func failMessage(_ message: String) {
        heartbeatTask?.cancel()
        heartbeatTask = nil
        inputSendTask?.cancel()
        inputSendTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        transport.close()
        sessionID = nil
        resumeToken = nil
        connectionRequest = nil
        isStopping = false
        state = .failed(String(message.prefix(512)))
        serviceMessage = String(message.prefix(512))
    }

    private func clearSession() {
        receiveTask?.cancel()
        heartbeatTask?.cancel()
        inputSendTask?.cancel()
        receiveTask = nil
        heartbeatTask = nil
        inputSendTask = nil
        transport.close()
        sessionID = nil
        resumeToken = nil
        connectionRequest = nil
        frameData = nil
        frameWidth = 0
        frameHeight = 0
        pageURL = ""
        pageTitle = ""
        serviceMessage = "Connecting to the isolated browser…"
        isStopping = false
    }
}
