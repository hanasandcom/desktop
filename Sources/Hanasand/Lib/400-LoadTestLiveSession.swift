import Combine
import CoreFoundation
import Foundation

enum LoadTestLiveEvent {
    case join(participants: Int)
    case log(String)
    case error(String)
    case done(code: Int, summary: JSONValue?, durationMilliseconds: Int?)
}

enum LoadTestLiveEventParser {
    static let maximumFrameBytes = 65_536

    static func parse(_ text: String) throws -> LoadTestLiveEvent {
        guard text.utf8.count <= maximumFrameBytes else { throw LoadTestLiveError.invalidEvent("Live output exceeded the 64 KiB frame limit.") }
        guard let data = text.data(using: .utf8),
              let value = try? JSONSerialization.jsonObject(with: data),
              let row = value as? [String: Any],
              let type = row["type"] as? String else {
            throw LoadTestLiveError.invalidEvent("The public stream sent invalid output.")
        }
        if type == "join" {
            guard let participants = integer(row["participants"]), (0...1_000_000).contains(participants) else {
                throw LoadTestLiveError.invalidEvent("The public stream sent an invalid viewer count.")
            }
            return .join(participants: participants)
        }
        guard type == "update", let update = row["data"] as? [String: Any], let updateType = update["type"] as? String else {
            throw LoadTestLiveError.invalidEvent("The public stream sent an unsupported event.")
        }
        if updateType == "log" || updateType == "error" {
            guard let message = update["message"] as? String else {
                throw LoadTestLiveError.invalidEvent("The public stream sent invalid text output.")
            }
            let bounded = String(message.prefix(8_000))
            return updateType == "log" ? .log(bounded) : .error(bounded)
        }
        if updateType == "done" {
            guard let code = integer(update["code"]) else {
                throw LoadTestLiveError.invalidEvent("The public stream sent an invalid completion status.")
            }
            let duration = integer(update["durationMs"]).flatMap { (0...86_400_000).contains($0) ? $0 : nil }
            let summary: JSONValue?
            if let raw = update["summary"], JSONSerialization.isValidJSONObject(raw),
               let encoded = try? JSONSerialization.data(withJSONObject: raw),
               let decoded = try? JSONDecoder().decode(JSONValue.self, from: encoded) {
                summary = decoded
            } else {
                summary = nil
            }
            return .done(code: code, summary: summary, durationMilliseconds: duration)
        }
        throw LoadTestLiveError.invalidEvent("The public stream sent an unsupported update.")
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite,
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue >= Double(Int32.min), number.doubleValue <= Double(Int32.max) else { return nil }
        return number.intValue
    }
}

enum LoadTestLiveError: LocalizedError {
    case invalidEvent(String)
    case unavailable

    var errorDescription: String? {
        switch self {
        case .invalidEvent(let message): return message
        case .unavailable: return "The public live stream is unavailable. No reconnect was attempted."
        }
    }
}

@MainActor
protocol LoadTestLiveSocket: AnyObject {
    func connect(to url: URL)
    func receive() async throws -> String
    func close()
}

@MainActor
private final class URLSessionLoadTestLiveSocket: LoadTestLiveSocket {
    private static let redirectBlocker = LoadTestLiveRedirectBlocker()
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

    func connect(to url: URL) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: Self.redirectBlocker, delegateQueue: nil)
        self.session = session
        let task = session.webSocketTask(with: URLRequest(url: url, timeoutInterval: 20))
        self.task = task
        task.resume()
    }

    func receive() async throws -> String {
        guard let task else { throw LoadTestLiveError.unavailable }
        switch try await task.receive() {
        case .string(let value): return value
        case .data: throw LoadTestLiveError.invalidEvent("The public stream sent unsupported binary output.")
        @unknown default: throw LoadTestLiveError.invalidEvent("The public stream sent an unsupported frame.")
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}

private final class LoadTestLiveRedirectBlocker: NSObject, URLSessionTaskDelegate {
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
final class LoadTestLiveSession: ObservableObject {
    @Published private(set) var testID: String?
    @Published private(set) var status = "Not listening"
    @Published private(set) var participants: Int?
    @Published private(set) var logs: [String] = []
    @Published private(set) var errors: [String] = []
    @Published private(set) var outputLimited = false
    @Published private(set) var completionStatus: String?
    @Published private(set) var exitCode: Int?
    @Published private(set) var durationMilliseconds: Int?
    @Published private(set) var summary: JSONValue?

    var isListening: Bool { socket != nil }

    private let makeSocket: @MainActor () -> LoadTestLiveSocket
    private var socket: LoadTestLiveSocket?
    private var worker: Task<Void, Never>?
    private var watchdog: Task<Void, Never>?
    private var generation = 0
    private var totalBytes = 0

    init(makeSocket: (@MainActor () -> LoadTestLiveSocket)? = nil) {
        self.makeSocket = makeSocket ?? { URLSessionLoadTestLiveSocket() }
    }

    @discardableResult
    func join(apiBaseURL: URL, id: String, reviewed: Bool, hasAuth: Bool, canWrite: Bool, isImpersonating: Bool) -> Bool {
        guard reviewed, hasAuth, canWrite, !isImpersonating else {
            status = "Join requires confirmation and your own signed-in account."
            return false
        }
        guard let url = LoadTestingClient.liveSocketURL(apiBaseURL: apiBaseURL, testID: id) else {
            status = "The public stream address or scan ID is invalid."
            return false
        }
        leave(status: "Not listening")
        generation &+= 1
        let own = generation
        testID = id
        participants = nil
        logs = []
        errors = []
        outputLimited = false
        completionStatus = nil
        exitCode = nil
        durationMilliseconds = nil
        summary = nil
        totalBytes = 0
        status = "Connecting to public stream…"
        let next = makeSocket()
        socket = next
        next.connect(to: url)
        armWatchdog(generation: own)
        worker = Task { [weak self, weak next] in
            guard let self, let next else { return }
            await self.receive(from: next, generation: own)
        }
        return true
    }

    func stopListening() {
        leave(status: "Stopped · join manually to listen again")
    }

    func stop() {
        leave(status: "Not listening")
    }

    private func receive(from socket: LoadTestLiveSocket, generation own: Int) async {
        do {
            while !Task.isCancelled, own == generation {
                let frame = try await socket.receive()
                guard !Task.isCancelled, own == generation else { return }
                let bytes = frame.utf8.count
                guard bytes <= LoadTestLiveEventParser.maximumFrameBytes else {
                    throw LoadTestLiveError.invalidEvent("Live output exceeded the 64 KiB frame limit.")
                }
                totalBytes += bytes
                guard totalBytes <= 2 * 1024 * 1024 else {
                    throw LoadTestLiveError.invalidEvent("Live output reached the 2 MiB session limit. Refresh the stored result.")
                }
                let event = try LoadTestLiveEventParser.parse(frame)
                armWatchdog(generation: own)
                status = "Live · public stream"
                switch event {
                case .join(let count): participants = count
                case .log(let value): append(value, to: &logs)
                case .error(let value): append(value, to: &errors)
                case .done(let code, let summary, let duration):
                    exitCode = code
                    self.summary = summary
                    durationMilliseconds = duration
                    completionStatus = code == 0 ? "done" : "failed"
                    status = "Run finished · stream closed"
                    close(generation: own)
                    return
                }
            }
        } catch {
            guard !Task.isCancelled, own == generation else { return }
            status = error.localizedDescription.contains("public stream") || error.localizedDescription.contains("Live output")
                ? error.localizedDescription
                : "The public stream closed. Refresh the stored result; no reconnect was attempted."
            close(generation: own)
        }
    }

    private func append(_ value: String, to output: inout [String]) {
        var bounded = String(value.prefix(8_000))
        let currentUnits = output.reduce(0) { $0 + $1.utf16.count }
        let remaining = max(0, 128 * 1024 - currentUnits)
        if bounded.utf16.count > remaining {
            bounded = String(bounded.utf16.prefix(remaining).compactMap(Unicode.Scalar.init).map(Character.init))
            outputLimited = true
        }
        if value.count >= 8_000 { outputLimited = true }
        guard !bounded.isEmpty else { outputLimited = true; return }
        output.append(bounded)
        if output.count > 500 {
            output.removeFirst(output.count - 500)
            outputLimited = true
        }
    }

    private func armWatchdog(generation own: Int) {
        watchdog?.cancel()
        watchdog = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: 90_000_000_000) } catch { return }
            guard let self, own == self.generation else { return }
            self.status = "Live output timed out. Server work may continue."
            self.close(generation: own)
        }
    }

    private func close(generation own: Int) {
        guard own == generation else { return }
        watchdog?.cancel()
        watchdog = nil
        worker?.cancel()
        worker = nil
        socket?.close()
        socket = nil
    }

    private func leave(status nextStatus: String) {
        generation &+= 1
        watchdog?.cancel()
        watchdog = nil
        worker?.cancel()
        worker = nil
        socket?.close()
        socket = nil
        status = nextStatus
        participants = nil
    }
}
