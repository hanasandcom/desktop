import Combine
import Foundation

@MainActor
protocol SupportLiveSocketTransport: AnyObject {
    func connect(request: URLRequest)
    func send(_ text: String) async throws
    func receive() async throws -> String
    var closeCode: URLSessionWebSocketTask.CloseCode { get }
    func close()
}

@MainActor
private final class URLSessionSupportLiveSocket: SupportLiveSocketTransport {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    var closeCode: URLSessionWebSocketTask.CloseCode { task?.closeCode ?? .invalid }

    func connect(request: URLRequest) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration)
        self.session = session
        let task = session.webSocketTask(with: request)
        self.task = task
        task.resume()
    }

    func send(_ text: String) async throws {
        guard let task else { throw SupportLiveError.socketUnavailable }
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        guard let task else { throw SupportLiveError.socketUnavailable }
        switch try await task.receive() {
        case .string(let text): return text
        case .data: throw SupportLiveError.invalidResponse
        @unknown default: throw SupportLiveError.invalidResponse
        }
    }

    func close() {
        task?.cancel(with: .normalClosure, reason: nil)
        task = nil
        session?.invalidateAndCancel()
        session = nil
    }
}

@MainActor
final class SupportLiveSession: ObservableObject {
    @Published private(set) var status: SupportLiveStatus = .idle

    private let makeSocket: @MainActor () -> SupportLiveSocketTransport
    private let waitBeforeRetry: @MainActor (Duration) async throws -> Void
    private var worker: Task<Void, Never>?
    private var socket: SupportLiveSocketTransport?
    private var generation = 0

    init(makeSocket: (@MainActor () -> SupportLiveSocketTransport)? = nil,
         waitBeforeRetry: (@MainActor (Duration) async throws -> Void)? = nil) {
        self.makeSocket = makeSocket ?? { URLSessionSupportLiveSocket() }
        self.waitBeforeRetry = waitBeforeRetry ?? { duration in try await Task.sleep(for: duration) }
    }

    func start(apiBaseURL: String, websiteBaseURL: String, userID: String, token: String, impersonationToken: String = "",
               changed: @escaping @MainActor () -> Void) {
        stop()
        guard !userID.isEmpty, !token.isEmpty else { status = .idle; return }
        start(apiBaseURL: apiBaseURL, websiteBaseURL: websiteBaseURL,
              makeAuthFrame: { try SupportLiveProtocol.authFrame(userID: userID, token: token,
                                                                  impersonationToken: impersonationToken) },
              changed: changed)
    }

    func startGuest(apiBaseURL: String, websiteBaseURL: String,
                    connectTicket: @escaping @MainActor () async throws -> String,
                    changed: @escaping @MainActor () -> Void) {
        stop()
        start(apiBaseURL: apiBaseURL, websiteBaseURL: websiteBaseURL,
              makeAuthFrame: { try SupportLiveProtocol.guestAuthFrame(ticket: await connectTicket()) },
              changed: changed)
    }

    private func start(apiBaseURL: String, websiteBaseURL: String,
                       makeAuthFrame: @escaping @MainActor () async throws -> String,
                       changed: @escaping @MainActor () -> Void) {
        let own = generation
        worker = Task { [weak self] in
            guard let self else { return }
            await self.run(apiBaseURL: apiBaseURL, websiteBaseURL: websiteBaseURL,
                           makeAuthFrame: makeAuthFrame, generation: own, changed: changed)
        }
    }

    func stop() {
        generation += 1
        worker?.cancel()
        worker = nil
        socket?.close()
        socket = nil
        status = .idle
    }

    private func run(apiBaseURL: String, websiteBaseURL: String,
                     makeAuthFrame: @escaping @MainActor () async throws -> String,
                     generation own: Int, changed: @escaping @MainActor () -> Void) async {
        var failures = 0
        while !Task.isCancelled && own == generation {
            status = failures == 0 ? .connecting : .reconnecting
            let next = makeSocket()
            socket = next
            do {
                let url = try SupportLiveProtocol.socketURL(apiBaseURL: apiBaseURL)
                let origin = try SupportLiveProtocol.originHeader(websiteBaseURL: websiteBaseURL)
                // Guest tickets are short-lived and single-use, so build auth for each socket attempt.
                let auth = try await makeAuthFrame()
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.httpShouldHandleCookies = false
                request.setValue(origin, forHTTPHeaderField: "Origin")
                next.connect(request: request)
                try await next.send(auth)
                var ready = false
                while !Task.isCancelled && own == generation {
                    let frame = try SupportLiveProtocol.frameType(await next.receive())
                    guard own == generation else { return }
                    switch frame {
                    case "ready" where !ready:
                        ready = true
                        failures = 0
                        status = .live
                        changed()
                    case "changed" where ready:
                        changed()
                    default:
                        break
                    }
                }
                if Task.isCancelled || own != generation { return }
            } catch {
                guard !Task.isCancelled, own == generation else { return }
                if next.closeCode == .policyViolation {
                    status = .refreshAccess
                    next.close()
                    socket = nil
                    return
                }
            }
            next.close()
            if socket === next { socket = nil }
            failures += 1
            guard failures < 5 else { status = .unavailable; return }
            do { try await waitBeforeRetry(.seconds(min(15, 1 << failures))) }
            catch { return }
        }
    }
}
