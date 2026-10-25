import Combine
import Foundation

@MainActor
protocol NativeShareTerminalSocket: AnyObject {
    func resume()
    func send(_ text: String) async throws
    func receive() async throws -> String
    func cancel()
}

@MainActor
private final class URLSessionNativeShareTerminalSocket: NativeShareTerminalSocket {
    private let session: URLSession
    private let task: URLSessionWebSocketTask

    init(url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        session = URLSession(configuration: configuration)
        task = session.webSocketTask(with: url)
    }

    func resume() {
        task.resume()
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        let message = try await task.receive()
        let text: String
        switch message {
        case let .string(value): text = value
        case let .data(value): text = String(decoding: value, as: UTF8.self)
        @unknown default: throw NativeShareTerminalSessionError.invalidMessage
        }
        guard text.utf8.count <= NativeShareTerminalSessionLimits.maximumEventBytes else {
            throw NativeShareTerminalSessionError.eventTooLarge
        }
        return text
    }

    func cancel() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

struct NativeShareTerminalCredentials: Decodable, Equatable {
    let username: String
    let password: String
    let sshCommand: String
    let domain: String

    func validate() throws {
        guard !username.isEmpty, !sshCommand.isEmpty, !domain.isEmpty,
              username.utf8.count <= NativeShareTerminalSessionLimits.maximumCredentialFieldBytes,
              password.utf8.count <= NativeShareTerminalSessionLimits.maximumCredentialFieldBytes,
              sshCommand.utf8.count <= NativeShareTerminalSessionLimits.maximumCredentialFieldBytes,
              domain.utf8.count <= NativeShareTerminalSessionLimits.maximumCredentialFieldBytes else {
            throw NativeShareTerminalSessionError.invalidMessage
        }
    }
}

enum NativeShareTerminalLifecycle: Equatable {
    case closed
    case connecting
    case ready
    case failed
}

enum NativeShareTerminalSessionError: LocalizedError, Equatable {
    case invalidBaseURL
    case invalidIdentity
    case invalidInput
    case invalidMessage
    case eventTooLarge

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "The configured share terminal address is invalid."
        case .invalidIdentity: "The share terminal identity is invalid."
        case .invalidInput: "Enter terminal input of 1 to 4,096 bytes."
        case .invalidMessage: "The share terminal returned an invalid event."
        case .eventTooLarge: "The share terminal event exceeded the supported size."
        }
    }
}

enum NativeShareTerminalSessionLimits {
    static let maximumIdentityBytes = 128
    static let maximumInputBytes = 4_096
    static let maximumEventBytes = 32 * 1_024
    static let maximumCredentialFieldBytes = 1_024
    static let maximumOutputBytes = 128 * 1_024
    static let maximumOutputChunks = 256
    static let maximumParticipants = 128
}

@MainActor
final class NativeShareTerminalSession: ObservableObject {
    typealias SocketFactory = @MainActor (URL) throws -> NativeShareTerminalSocket
    typealias RetryCancellation = @MainActor () -> Void
    typealias RetryScheduler = @MainActor (_ delayNanoseconds: UInt64, _ action: @escaping @MainActor () -> Void) -> RetryCancellation
    static let reconnectDelayNanoseconds: UInt64 = 1_000_000_000

    @Published private(set) var lifecycle: NativeShareTerminalLifecycle = .closed
    @Published private(set) var status = "Terminal closed."
    @Published private(set) var isConnected = false
    @Published private(set) var participants = 1
    @Published private(set) var output: [String] = []
    @Published private(set) var credentials: NativeShareTerminalCredentials?
    @Published private(set) var errorMessage: String?

    let alias: String
    let userID: String
    private(set) var sessionID: String

    private let apiBaseURL: URL
    private let socketFactory: SocketFactory
    private let retryScheduler: RetryScheduler
    private var socket: NativeShareTerminalSocket?
    private var receiveTask: Task<Void, Never>?
    private var cancelScheduledRetry: RetryCancellation?
    private var outputBytes = 0
    private(set) var generation = 0

    init(apiBaseURL: URL, alias: String, userID: String, sessionID: String = UUID().uuidString.lowercased(),
         socketFactory: SocketFactory? = nil, retryScheduler: RetryScheduler? = nil) {
        self.apiBaseURL = apiBaseURL
        self.alias = alias
        self.userID = userID
        self.sessionID = sessionID
        self.socketFactory = socketFactory ?? { URLSessionNativeShareTerminalSocket(url: $0) }
        self.retryScheduler = retryScheduler ?? { delay, action in
            var task: Task<Void, Never>?
            task = Task {
                try? await Task.sleep(nanoseconds: delay)
                guard !Task.isCancelled else { return }
                action()
            }
            return { task?.cancel() }
        }
    }

    static func socketURL(apiBaseURL: URL, alias: String, userID: String, sessionID: String) throws -> URL {
        guard validIdentity(alias), validIdentity(userID), validIdentity(sessionID) else {
            throw NativeShareTerminalSessionError.invalidIdentity
        }
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw NativeShareTerminalSessionError.invalidBaseURL
        }

        let rawPath = apiBaseURL.path
        let decodedSegments = rawPath.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).removingPercentEncoding ?? String($0) }
        guard decodedSegments.allSatisfy({
            $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\\")
        }) else {
            throw NativeShareTerminalSessionError.invalidBaseURL
        }

        var components = URLComponents(url: apiBaseURL, resolvingAgainstBaseURL: false)
        let prefix = rawPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let hasAPIPath = decodedSegments.last?.lowercased() == "api"
        let route = hasAPIPath ? "ws/share" : "api/ws/share"
        let root = prefix.isEmpty ? "" : "/\(prefix)"
        components?.path = "\(root)/\(route)/\(alias)/shell/\(userID)/\(sessionID)"
        components?.scheme = "wss"
        guard let url = components?.url, url.scheme == "wss", url.host == apiBaseURL.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw NativeShareTerminalSessionError.invalidBaseURL
        }
        return url
    }

    func connect() {
        guard lifecycle != .connecting, lifecycle != .ready else { return }
        cancelPendingRetry()
        disconnect(clearOutput: true)
        generation &+= 1
        let currentGeneration = generation
        lifecycle = .connecting
        status = "Connecting to terminal…"
        errorMessage = nil
        credentials = nil
        participants = 1

        do {
            let url = try Self.socketURL(apiBaseURL: apiBaseURL, alias: alias, userID: userID, sessionID: sessionID)
            let newSocket = try socketFactory(url)
            socket = newSocket
            newSocket.resume()
            receiveTask = Task { [weak self, weak newSocket] in
                guard let newSocket else { return }
                do {
                    while !Task.isCancelled {
                        let message = try await newSocket.receive()
                        guard !Task.isCancelled else { return }
                        self?.handleMessage(message, generation: currentGeneration)
                    }
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.handleReceiveFailure(generation: currentGeneration)
                }
            }
        } catch {
            lifecycle = .failed
            status = "Terminal connection failed."
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Terminal connection failed."
            scheduleReconnect()
        }
    }

    @discardableResult
    func sendInput(_ value: String) async -> Bool {
        guard !value.isEmpty, value.utf8.count <= NativeShareTerminalSessionLimits.maximumInputBytes else {
            errorMessage = NativeShareTerminalSessionError.invalidInput.errorDescription
            return false
        }
        guard isConnected, let socket else { return false }
        do {
            let payload = try JSONSerialization.data(withJSONObject: ["type": "terminalInput", "content": value])
            guard payload.count <= NativeShareTerminalSessionLimits.maximumEventBytes else { return false }
            try await socket.send(String(decoding: payload, as: UTF8.self))
            return true
        } catch {
            handleReceiveFailure(generation: generation)
            return false
        }
    }

    func disconnect() {
        disconnect(clearOutput: true)
    }

    func reconnect() {
        cancelPendingRetry()
        disconnect(clearOutput: true)
        connect()
    }

    func restart() {
        cancelPendingRetry()
        disconnect(clearOutput: true)
        sessionID = UUID().uuidString.lowercased()
        connect()
    }

    func handleMessage(_ raw: String, generation expectedGeneration: Int) {
        guard expectedGeneration == generation else { return }
        guard raw.utf8.count <= NativeShareTerminalSessionLimits.maximumEventBytes,
              let data = raw.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String else {
            handleReceiveFailure(generation: expectedGeneration)
            return
        }

        switch type {
        case "update":
            guard let content = event["content"] as? String,
                  content.utf8.count <= NativeShareTerminalSessionLimits.maximumEventBytes else {
                handleReceiveFailure(generation: expectedGeneration)
                return
            }
            isConnected = true
            lifecycle = .ready
            appendTerminalOutput(from: terminalContent(from: content))
            status = terminalStatus(from: content) ?? "Terminal ready."
            if let count = event["participants"] as? Int, (1...NativeShareTerminalSessionLimits.maximumParticipants).contains(count) {
                participants = count
            }
        case "terminal_credentials":
            guard let value = event["credentials"],
                  let credentialData = try? JSONSerialization.data(withJSONObject: value),
                  let parsed = try? JSONDecoder().decode(NativeShareTerminalCredentials.self, from: credentialData),
                  (try? parsed.validate()) != nil else {
                handleReceiveFailure(generation: expectedGeneration)
                return
            }
            credentials = parsed
            isConnected = true
            lifecycle = .ready
            status = "Terminal ready."
        case "join":
            guard let count = event["participants"] as? Int,
                  (1...NativeShareTerminalSessionLimits.maximumParticipants).contains(count) else { return }
            participants = count
            isConnected = true
            lifecycle = .ready
            status = "Terminal ready."
        default:
            break
        }
    }

    private func appendOutput(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        var bounded = chunk
        if bounded.utf8.count > NativeShareTerminalSessionLimits.maximumOutputBytes {
            bounded = String(decoding: Data(bounded.utf8.suffix(NativeShareTerminalSessionLimits.maximumOutputBytes)), as: UTF8.self)
            output = []
            outputBytes = 0
        }
        output.append(bounded)
        outputBytes += bounded.utf8.count
        while output.count > NativeShareTerminalSessionLimits.maximumOutputChunks
                || outputBytes > NativeShareTerminalSessionLimits.maximumOutputBytes {
            outputBytes -= output.removeFirst().utf8.count
        }
    }

    private func appendTerminalOutput(from content: String) {
        let clearSequence = "\u{001B}c"
        guard let clearRange = content.range(of: clearSequence, options: .backwards) else {
            appendOutput(content)
            return
        }
        output = []
        outputBytes = 0
        appendOutput(String(content[clearRange.upperBound...]))
    }

    private func terminalContent(from raw: String) -> String {
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let content = value["content"] as? String else { return raw }
        return content
    }

    private func terminalStatus(from raw: String) -> String? {
        let content = terminalContent(from: raw)
        let status = content.replacingOccurrences(of: "\r", with: "\n")
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && !$0.contains("sudo: unable to resolve host") }
            .last
        return status.map { String($0.prefix(300)) }
    }

    private func handleReceiveFailure(generation expectedGeneration: Int) {
        guard expectedGeneration == generation else { return }
        generation &+= 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel()
        socket = nil
        isConnected = false
        lifecycle = .failed
        status = "Terminal connection was lost."
        errorMessage = status
        scheduleReconnect()
    }

    private func disconnect(clearOutput: Bool) {
        cancelPendingRetry()
        generation &+= 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel()
        socket = nil
        isConnected = false
        lifecycle = .closed
        status = "Terminal closed."
        credentials = nil
        errorMessage = nil
        participants = 1
        if clearOutput {
            output = []
            outputBytes = 0
        }
    }

    private func scheduleReconnect() {
        cancelPendingRetry()
        let retryGeneration = generation
        cancelScheduledRetry = retryScheduler(Self.reconnectDelayNanoseconds) { [weak self] in
            guard let self, self.generation == retryGeneration, self.lifecycle == .failed else { return }
            self.cancelScheduledRetry = nil
            self.connect()
        }
    }

    private func cancelPendingRetry() {
        let cancel = cancelScheduledRetry
        cancelScheduledRetry = nil
        cancel?()
    }

    private static func validIdentity(_ value: String) -> Bool {
        value != "." && value != ".."
            && value.utf8.count <= NativeShareTerminalSessionLimits.maximumIdentityBytes
            && value.range(of: #"^[A-Za-z0-9._~-]{1,128}$"#, options: .regularExpression) != nil
    }
}
