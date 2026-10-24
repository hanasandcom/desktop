import Combine
import Foundation

private final class NativeVMConsoleRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

@MainActor
final class NativeVMConsoleSession: ObservableObject {
    private static let redirectBlocker = NativeVMConsoleRedirectBlocker()
    private static let secureSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: redirectBlocker, delegateQueue: nil)
    }()

    @Published private(set) var terminal = NativeTerminalBuffer()
    @Published private(set) var bootLog = NativeVMBootLog()
    @Published private(set) var status = "Disconnected"
    @Published private(set) var username = ""
    @Published private(set) var isConnected = false
    @Published private(set) var isPreparing = false
    @Published private(set) var generation = 0

    private var apiBaseURL: String
    private let vmName: String
    private var userID: String
    private var token: String
    private var organizationID: String
    private var isImpersonating: Bool
    private var provisioningFlow: Bool
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var totalOutputUnits = 0
    private var requestedColumns = 80
    private var requestedRows = 24

    init(apiBaseURL: String, vmName: String, userID: String, token: String, isImpersonating: Bool, provisioningFlow: Bool, organizationID: String = "") {
        self.apiBaseURL = apiBaseURL
        self.vmName = vmName
        self.userID = userID
        self.token = token
        self.organizationID = organizationID
        self.isImpersonating = isImpersonating
        self.provisioningFlow = provisioningFlow
    }

    func updateCredentials(apiBaseURL: String, userID: String, token: String, isImpersonating: Bool, provisioningFlow: Bool, organizationID: String = "") {
        guard self.apiBaseURL != apiBaseURL || self.userID != userID || self.token != token
                || self.isImpersonating != isImpersonating || self.provisioningFlow != provisioningFlow
                || self.organizationID != organizationID else { return }
        disconnect()
        self.apiBaseURL = apiBaseURL
        self.userID = userID
        self.token = token
        self.organizationID = organizationID
        self.isImpersonating = isImpersonating
        self.provisioningFlow = provisioningFlow
        terminal.reset()
        bootLog.clear()
        username = ""
    }

    func connect(reviewed: Bool = false) {
        guard socket == nil else { return }
        generation &+= 1
        guard nativeVMConsoleMayOpen(hasAuth: true, isImpersonating: isImpersonating, reviewed: reviewed, userID: userID, token: token),
              let url = nativeVMConsoleWebSocketURL(apiBaseURL: apiBaseURL, vmName: vmName) else {
            status = reviewed
                ? "Sign in to your own account and configure a secure API URL to open this console."
                : "Review console access before connecting. Opening it may start this VM."
            return
        }
        terminal.reset()
        bootLog.clear()
        totalOutputUnits = 0
        receiveTask = Task { [weak self] in
            guard let self else { return }
            do {
                if !provisioningFlow { try await prepareVM() }
                guard !Task.isCancelled else { return }
                let task = Self.secureSession.webSocketTask(with: url)
                socket = task
                task.resume()
                let auth = try JSONSerialization.data(withJSONObject: ["type": "auth", "id": userID, "token": token])
                try await task.send(.string(String(decoding: auth, as: UTF8.self)))
                status = "Opening console…"
                while !Task.isCancelled {
                    let message = try await task.receive()
                    guard case let .string(text) = message else { continue }
                    handleMessage(text)
                }
            } catch {
                guard !Task.isCancelled else { return }
                isConnected = false
                isPreparing = false
                status = "Console unavailable: \(error.localizedDescription)"
                socket?.cancel(with: .goingAway, reason: nil)
                socket = nil
                terminal.reset()
                bootLog.clear()
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
                bootLog.clear()
            }
        }
        return true
    }

    func sendControlC() {
        guard isConnected, let socket else { return }
        Task { try? await socket.send(.string("{\"type\":\"input\",\"data\":\"\\u0003\"}")) }
    }

    func resize(columns: Int, rows: Int, generation expectedGeneration: Int) {
        guard expectedGeneration == generation else { return }
        let columns = min(NativeTerminalBuffer.maximumColumns, max(20, columns))
        let rows = min(NativeTerminalBuffer.maximumRows, max(8, rows))
        requestedColumns = columns
        requestedRows = rows
        terminal.resize(columns: columns, rows: rows)
        guard isConnected, let socket else { return }
        Task {
            let payload = try? JSONSerialization.data(withJSONObject: ["type": "resize", "cols": columns, "rows": rows])
            guard let payload else { return }
            try? await socket.send(.string(String(decoding: payload, as: UTF8.self)))
        }
    }

    func disconnect() {
        generation &+= 1
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .normalClosure, reason: nil)
        socket = nil
        terminal.reset()
        bootLog.clear()
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
        let (data, response) = try await Self.secureSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw NativeVMConsoleError.prepareFailed(status: (response as? HTTPURLResponse)?.statusCode ?? 0, message: Self.apiError(data))
        }
        let value = try JSONSerialization.jsonObject(with: data)
        let vm = (value as? [[String: Any]])?.first ?? value as? [String: Any]
        guard let vm else { throw NativeVMConsoleError.invalidVMResponse }
        let accessClient = try NativeVMWorkspaceClient(
            apiBaseURL: apiBaseURL,
            userID: userID,
            token: token,
            organizationID: organizationID.isEmpty ? nil : organizationID
        )
        let access = try await accessClient.loadManagement(for: vmName)
        guard access.canManage, !isImpersonating else { throw NativeVMWorkspaceClientError.permissionDenied }
        if String(describing: vm["status"] ?? "").lowercased() == "stopped" {
            status = "Starting container…"
            var start = URLRequest(url: base.appendingPathComponent("vm").appendingPathComponent(vmName).appendingPathComponent("start"))
            start.httpMethod = "POST"
            start.setValue(userID, forHTTPHeaderField: "id")
            start.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (startData, startResponse) = try await Self.secureSession.data(for: start)
            guard let startHTTP = startResponse as? HTTPURLResponse, (200..<300).contains(startHTTP.statusCode) else {
                throw NativeVMConsoleError.prepareFailed(status: (startResponse as? HTTPURLResponse)?.statusCode ?? 0, message: Self.apiError(startData))
            }
        }
        let latestAccess = try await accessClient.loadManagement(for: vmName)
        guard latestAccess.canManage, !isImpersonating else { throw NativeVMWorkspaceClientError.permissionDenied }
        isPreparing = false
        status = "Opening console…"
    }

    func handleMessage(_ raw: String) {
        guard raw.utf16.count <= 131_072 else { failSession("Terminal output exceeded the event limit. Reconnect to continue."); return }
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
            resize(columns: requestedColumns, rows: requestedRows, generation: generation)
        case "output":
            guard let chunk = value["data"] as? String else { return }
            acceptOutput(chunk)
        case "boot-output":
            guard let chunk = value["data"] as? String else { return }
            bootLog.append(chunk)
        case "boot-error":
            bootLog.recordError()
        case "error":
            isConnected = false
            isPreparing = false
            generation &+= 1
            status = value["message"] as? String ?? "Console could not be opened."
            socket?.cancel(with: .goingAway, reason: nil)
            socket = nil
            terminal.reset()
            bootLog.clear()
        case "closed":
            isConnected = false
            isPreparing = false
            generation &+= 1
            status = "Console disconnected."
            socket?.cancel(with: .normalClosure, reason: nil)
            socket = nil
            terminal.reset()
            bootLog.clear()
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
        isPreparing = false
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .policyViolation, reason: nil)
        socket = nil
        terminal.reset()
        bootLog.clear()
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
