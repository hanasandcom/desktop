import Combine
import Foundation

private final class HostConsoleRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

@MainActor
final class HostConsoleSession: ObservableObject {
    @Published private(set) var terminal = NativeTerminalBuffer()
    @Published private(set) var status = "Disconnected"
    @Published private(set) var username = ""
    @Published private(set) var isConnected = false
    @Published private(set) var generation = 0

    private static let redirectBlocker = HostConsoleRedirectBlocker()
    private static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: redirectBlocker, delegateQueue: nil)
    }()

    private let url: URL?
    private let host: HostOverviewEnvelope.Host.ID
    private let isImpersonating: Bool
    private let userID: String
    private let token: String
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var totalOutputUnits = 0
    private var requestedColumns = 80
    private var requestedRows = 24

    init(host: HostOverviewEnvelope.Host.ID, apiBaseURL: String, userID: String, token: String, isImpersonating: Bool) {
        self.host = host
        self.isImpersonating = isImpersonating
        self.url = hostConsoleWebSocketURL(apiBaseURL: apiBaseURL, host: host)
        self.userID = userID
        self.token = token
    }

    func connect() {
        guard socket == nil else { return }
        generation &+= 1
        guard hostConsoleMayOpen(hasAuth: true, isImpersonating: isImpersonating, userID: userID, token: token),
              let url else {
            status = "Sign in to your own account and configure a secure API URL to open the console."
            return
        }
        terminal.reset()
        totalOutputUnits = 0
        status = "Connecting to \(host.rawValue)…"
        let next = Self.secureSession.webSocketTask(with: url)
        socket = next
        next.resume()
        receiveTask = Task { [weak self, weak next] in
            guard let self, let next else { return }
            do {
                let auth = try JSONSerialization.data(withJSONObject: ["type": "auth", "id": self.userID, "token": self.token])
                try await next.send(.string(String(decoding: auth, as: UTF8.self)))
                while !Task.isCancelled {
                    let message = try await next.receive()
                    guard case let .string(text) = message else { continue }
                    self.handle(text)
                }
            } catch {
                guard !Task.isCancelled else { return }
                self.isConnected = false
                self.status = "Console disconnected: \(error.localizedDescription)"
                self.socket?.cancel(with: .goingAway, reason: nil)
                self.socket = nil
                self.receiveTask = nil
                self.terminal.reset()
            }
        }
    }

    func sendLine(_ line: String, generation expectedGeneration: Int) -> Bool {
        sendInput(line + "\r", generation: expectedGeneration)
    }

    func sendInput(_ value: String, generation expectedGeneration: Int) -> Bool {
        guard expectedGeneration == generation, isConnected, let socket, !value.isEmpty, value.utf16.count <= 16_384 else { return false }
        Task {
            do {
                try await socket.send(.string(try Self.message(type: "input", value: value)))
            } catch {
                status = "Could not send input: \(error.localizedDescription)"
                isConnected = false
                generation &+= 1
                socket.cancel(with: .goingAway, reason: nil)
                self.socket = nil
            }
        }
        return true
    }

    func resize(columns: Int, rows: Int, generation expectedGeneration: Int) {
        guard expectedGeneration == generation else { return }
        requestedColumns = min(NativeTerminalBuffer.maximumColumns, max(20, columns))
        requestedRows = min(NativeTerminalBuffer.maximumRows, max(8, rows))
        let columns = requestedColumns
        let rows = requestedRows
        terminal.resize(columns: columns, rows: rows)
        guard isConnected, let socket else { return }
        let payload = try? JSONSerialization.data(withJSONObject: ["type": "resize", "cols": columns, "rows": rows])
        guard let payload else { return }
        Task { try? await socket.send(.string(String(decoding: payload, as: UTF8.self))) }
    }

    func sendControlC() {
        guard isConnected, let socket else { return }
        Task { try? await socket.send(.string("{\"type\":\"input\",\"data\":\"\\u0003\"}")) }
    }

    func disconnect() {
        generation &+= 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isConnected = false
        terminal.reset()
        status = "Disconnected"
    }

    private func handle(_ raw: String) {
        guard raw.utf16.count <= 131_072 else { failSession("Terminal output exceeded the event limit. Reconnect to continue."); return }
        guard raw.utf8.count <= 1_048_576 else { return }
        guard let data = raw.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = value["type"] as? String else { return }
        switch type {
        case "status":
            status = value["message"] as? String ?? "Connecting…"
        case "ready":
            username = value["username"] as? String ?? ""
            isConnected = true
            status = username.isEmpty ? "Connected" : "Connected · \(username)"
            resize(columns: requestedColumns, rows: requestedRows, generation: generation)
        case "output":
            guard let chunk = value["data"] as? String else { return }
            acceptOutput(chunk)
        case "error":
            isConnected = false
            generation &+= 1
            status = value["message"] as? String ?? "Console could not be opened."
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            terminal.reset()
        case "closed":
            isConnected = false
            generation &+= 1
            status = "Console disconnected."
            socket?.cancel(with: .normalClosure, reason: nil)
            socket = nil
            terminal.reset()
        default:
            break
        }
    }

    private func acceptOutput(_ chunk: String) {
        let count = chunk.utf16.count
        guard count <= 131_072, totalOutputUnits + count <= 8 * 1024 * 1024 else {
            failSession("Terminal output exceeded the safe buffer limit. Reconnect to continue.")
            return
        }
        totalOutputUnits += count
        let replies = terminal.feed(chunk)
        for reply in replies { _ = sendInput(reply, generation: generation) }
    }

    private func failSession(_ message: String) {
        generation &+= 1
        status = message
        isConnected = false
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .policyViolation, reason: nil)
        socket = nil
        terminal.reset()
    }

    private static func message(type: String, value: String) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: ["type": type, "data": value])
        return String(decoding: data, as: UTF8.self)
    }

    private static func plainTerminalText(_ value: String) -> String {
        let pattern = "\\u001B(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\u0007]*(?:\\u0007|\\u001B\\\\))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }
}
