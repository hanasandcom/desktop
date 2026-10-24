import Combine
import Foundation

@MainActor
final class HostConsoleSession: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var status = "Disconnected"
    @Published private(set) var username = ""
    @Published private(set) var isConnected = false

    private let url: URL?
    private let host: HostOverviewEnvelope.Host.ID
    private let isImpersonating: Bool
    private let userID: String
    private let token: String
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(host: HostOverviewEnvelope.Host.ID, apiBaseURL: String, userID: String, token: String, isImpersonating: Bool) {
        self.host = host
        self.isImpersonating = isImpersonating
        self.url = hostConsoleWebSocketURL(apiBaseURL: apiBaseURL, host: host)
        self.userID = userID
        self.token = token
    }

    func connect() {
        guard socket == nil else { return }
        guard hostConsoleMayOpen(hasAuth: true, isImpersonating: isImpersonating, userID: userID, token: token),
              let url else {
            status = "Sign in to your own account and configure a secure API URL to open the console."
            return
        }
        status = "Connecting to \(host.rawValue)…"
        let next = URLSession.shared.webSocketTask(with: url)
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
            }
        }
    }

    func sendLine(_ line: String) {
        let text = line + "\r"
        guard isConnected, let socket else { return }
        Task {
            do {
                try await socket.send(.string(try Self.message(type: "input", value: text)))
            } catch {
                status = "Could not send input: \(error.localizedDescription)"
                isConnected = false
            }
        }
    }

    func sendControlC() {
        guard isConnected, let socket else { return }
        Task { try? await socket.send(.string("{\"type\":\"input\",\"data\":\"\\u0003\"}")) }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isConnected = false
        status = "Disconnected"
    }

    private func handle(_ raw: String) {
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
        case "output":
            guard let chunk = value["data"] as? String else { return }
            output = String((output + Self.plainTerminalText(chunk)).suffix(65_536))
        case "error":
            isConnected = false
            status = value["message"] as? String ?? "Console could not be opened."
        case "closed":
            isConnected = false
            status = "Console disconnected."
        default:
            break
        }
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
