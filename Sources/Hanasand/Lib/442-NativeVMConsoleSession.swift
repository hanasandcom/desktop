import Combine
import Foundation

@MainActor
final class NativeVMConsoleSession: ObservableObject {
    @Published private(set) var output = ""
    @Published private(set) var status = "Disconnected"
    @Published private(set) var username = ""
    @Published private(set) var isConnected = false
    @Published private(set) var isPreparing = false

    private var apiBaseURL: String
    private let vmName: String
    private var userID: String
    private var token: String
    private var isImpersonating: Bool
    private var provisioningFlow: Bool
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?

    init(apiBaseURL: String, vmName: String, userID: String, token: String, isImpersonating: Bool, provisioningFlow: Bool) {
        self.apiBaseURL = apiBaseURL
        self.vmName = vmName
        self.userID = userID
        self.token = token
        self.isImpersonating = isImpersonating
        self.provisioningFlow = provisioningFlow
    }

    func updateCredentials(apiBaseURL: String, userID: String, token: String, isImpersonating: Bool, provisioningFlow: Bool) {
        guard self.apiBaseURL != apiBaseURL || self.userID != userID || self.token != token
                || self.isImpersonating != isImpersonating || self.provisioningFlow != provisioningFlow else { return }
        disconnect()
        self.apiBaseURL = apiBaseURL
        self.userID = userID
        self.token = token
        self.isImpersonating = isImpersonating
        self.provisioningFlow = provisioningFlow
        output = ""
        username = ""
    }

    func connect(reviewed: Bool = false) {
        guard socket == nil else { return }
        guard nativeVMConsoleMayOpen(hasAuth: true, isImpersonating: isImpersonating, reviewed: reviewed, userID: userID, token: token),
              let url = nativeVMConsoleWebSocketURL(apiBaseURL: apiBaseURL, vmName: vmName) else {
            status = reviewed
                ? "Sign in to your own account and configure a secure API URL to open this console."
                : "Review console access before connecting. Opening it may start this VM."
            return
        }
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !provisioningFlow { try await prepareVM() }
                guard !Task.isCancelled else { return }
                let task = URLSession.shared.webSocketTask(with: url)
                socket = task
                task.resume()
                let auth = try JSONSerialization.data(withJSONObject: ["type": "auth", "id": userID, "token": token])
                try await task.send(.string(String(decoding: auth, as: UTF8.self)))
                status = "Opening console…"
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard case let .string(text) = message else { continue }
                    handle(text)
                }
            } catch {
                guard !Task.isCancelled else { return }
                isConnected = false
                isPreparing = false
                status = "Console unavailable: \(error.localizedDescription)"
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil
            }
        }
    }

    func sendLine(_ line: String) {
        guard isConnected, let socket else { return }
        Task {
            do {
                try await socket.send(.string(try Self.message(type: "input", value: line + "\r")))
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

    func resize(columns: Int, rows: Int) {
        guard isConnected, let socket else { return }
        let columns = min(500, max(20, columns))
        let rows = min(200, max(8, rows))
        Task {
            let payload = try? JSONSerialization.data(withJSONObject: ["type": "resize", "cols": columns, "rows": rows])
            guard let payload else { return }
            try? await socket.send(.string(String(decoding: payload, as: UTF8.self)))
        }
    }

    func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        isConnected = false
        isPreparing = false
        status = "Disconnected"
    }

    private func prepareVM() async throws {
        guard let base = URL(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NativeVMConsoleError.invalidAPIURL
        }
        let detailsURL = base.appendingPathComponent("vm").appendingPathComponent(vmName)
        var request = URLRequest(url: detailsURL)
        request.httpMethod = "GET"
        request.setValue(userID, forHTTPHeaderField: "id")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData
        isPreparing = true
        status = "Checking container…"
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NativeVMConsoleError.prepareFailed(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: Self.apiError(data))
        }
        let value = try JSONSerialization.jsonObject(with: data)
        let vm = (value as? [[String: Any]])?.first ?? value as? [String: Any]
        guard let vm else { throw NativeVMConsoleError.invalidVMResponse }
        if String(describing: vm["status"] ?? "").lowercased() == "stopped" {
            status = "Starting container…"
            var start = URLRequest(url: base.appendingPathComponent("vm").appendingPathComponent(vmName).appendingPathComponent("start"))
            start.httpMethod = "POST"
            start.setValue(userID, forHTTPHeaderField: "id")
            start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (startData, startResponse) = try await URLSession.shared.data(for: start)
            guard let startHTTP = startResponse as? HTTPURLResponse, (200..<300).contains(startHTTP.statusCode) else {
                throw NativeVMConsoleError.prepareFailed(status: (startResponse as? HTTPURLResponse)?.statusCode ?? 0, message: Self.apiError(startData))
            }
        }
        isPreparing = false
        status = "Opening console…"
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
            isPreparing = false
            status = username.isEmpty ? "Connected" : "Connected · \(username)"
            resize(columns: 100, rows: 30)
        case "output":
            guard let chunk = value["data"] as? String else { return }
            output = String((output + Self.plainTerminalText(chunk)).suffix(65_536))
        case "boot-output":
            guard let chunk = value["data"] as? String else { return }
            output = String((output + chunk).suffix(65_536))
        case "boot-error", "error":
            isConnected = false
            isPreparing = false
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

    private static func apiError(_ data: Data) -> String {
        guard let value = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let message = value["error"] as? String else { return "HTTP request failed." }
        return String(message.prefix(300))
    }

    private static func plainTerminalText(_ value: String) -> String {
        let pattern = "\\u001B(?:\\[[0-?]*[ -/]*[@-~]|\\][^\\u0007]*(?:\\u0007|\\u001B\\\\))"
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(in: value, range: range, withTemplate: "")
            .replacingOccurrences(of: "\\r\\n", with: "\\n")
            .replacingOccurrences(of: "\\r", with: "\\n")
    }
}

enum NativeVMConsoleError: LocalizedError {
    case invalidAPIURL
    case invalidVMResponse
    case prepareFailed(status: Int, message: String)

    var errorDescription: String? {
        switch self {
        case .invalidAPIURL: "The API URL is invalid."
        case .invalidVMResponse: "The VM status response was incomplete."
        case let .prepareFailed(status, message): "Unable to prepare the VM (HTTP \(status)): \(message)"
        }
    }
}
