import Combine
import Foundation

@MainActor
protocol NativeShareCollaborationSocketTransport: AnyObject {
    func connect(request: URLRequest)
    func send(_ text: String) async throws
    func receive() async throws -> String
    func close()
}

@MainActor
private final class URLSessionNativeShareCollaborationSocket: NativeShareCollaborationSocketTransport {
    private var session: URLSession?
    private var task: URLSessionWebSocketTask?

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
        guard let task else { throw NativeShareCollaborationProtocolError.invalidEndpoint }
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        guard let task else { throw NativeShareCollaborationProtocolError.invalidEndpoint }
        switch try await task.receive() {
        case .string(let text): return text
        case .data: throw NativeShareCollaborationProtocolError.invalidFrame
        @unknown default: throw NativeShareCollaborationProtocolError.invalidFrame
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
final class NativeShareCollaborationLiveSession: ObservableObject {
    @Published private(set) var session: NativeShareCollaborationSession?
    @Published private(set) var connection: NativeShareCollaborationConnection = .disconnected

    private let makeSocket: @MainActor () -> NativeShareCollaborationSocketTransport
    private var worker: Task<Void, Never>?
    private var socket: NativeShareCollaborationSocketTransport?
    private var activeIdentity: NativeShareCollaborationIdentity?
    private var activeUserID = ""
    private var activeToken = ""
    private var apiBaseURL = ""
    private var displayName = ""
    private var epoch = 0

    init(makeSocket: (@MainActor () -> NativeShareCollaborationSocketTransport)? = nil) {
        self.makeSocket = makeSocket ?? { URLSessionNativeShareCollaborationSocket() }
    }

    func start(identity: NativeShareCollaborationIdentity, apiBaseURL: String, userID: String,
               token: String, displayName: String, initialContent: String) {
        guard identity.isValid, identity.accountID == userID, !token.isEmpty else {
            stop()
            return
        }
        if activeIdentity == identity, activeUserID == userID, activeToken == token,
           self.apiBaseURL == apiBaseURL { return }
        stop()
        do {
            if session?.identity != identity {
                session = try NativeShareCollaborationSession(identity: identity, clientID: Self.clientID(),
                    userID: userID, displayName: displayName, initialContent: initialContent)
            }
        } catch {
            session = nil
            connection = .disconnected
            return
        }
        activeIdentity = identity
        activeUserID = userID
        activeToken = token
        self.apiBaseURL = apiBaseURL
        self.displayName = displayName
        epoch &+= 1
        let own = epoch
        worker = Task { [weak self] in await self?.run(generation: own) }
    }

    func stop() {
        epoch &+= 1
        worker?.cancel()
        worker = nil
        socket?.close()
        socket = nil
        if let activeIdentity, var session {
            session.disconnect(identity: activeIdentity, generation: session.generation)
            self.session = session
        }
        activeIdentity = nil
        activeUserID = ""
        activeToken = ""
        apiBaseURL = ""
        connection = .disconnected
    }

    func edit(_ content: String) {
        guard var session, let identity = activeIdentity else { return }
        do {
            let outbound = try session.edit(content)
            self.session = session
            send(outbound, identity: identity, generation: session.generation)
        } catch {
            session.sendFailed(identity: identity, generation: session.generation,
                               message: error.localizedDescription)
            self.session = session
        }
    }

    func useRemoteConflict() {
        guard var session else { return }
        session.useRemoteConflict()
        self.session = session
    }

    func keepLocalConflict() {
        guard var session, let identity = activeIdentity else { return }
        let outbound = session.keepLocalConflict()
        self.session = session
        send(outbound, identity: identity, generation: session.generation)
    }

    func keepReviewedLocalVersion(remoteContent: String, localContent: String) {
        guard let identity = activeIdentity, !activeUserID.isEmpty, !activeToken.isEmpty else { return }
        let userID = activeUserID
        let token = activeToken
        let endpoint = apiBaseURL
        let name = displayName
        stop()
        do {
            session = try NativeShareCollaborationSession(identity: identity, clientID: Self.clientID(),
                userID: userID, displayName: name, initialContent: remoteContent)
        } catch { return }
        start(identity: identity, apiBaseURL: endpoint, userID: userID, token: token,
              displayName: name, initialContent: remoteContent)
        edit(localContent)
    }

    private func run(generation own: Int) async {
        var failures = 0
        while !Task.isCancelled, own == epoch, let identity = activeIdentity {
            do {
                guard var session else { return }
                let callbackGeneration = try session.connect(identity: identity)
                self.session = session
                connection = .connecting
                let next = makeSocket()
                socket = next
                let url = try NativeShareCollaborationProtocol.socketURL(apiBaseURL: apiBaseURL,
                                                                         shareID: identity.shareID)
                var request = URLRequest(url: url, timeoutInterval: 20)
                request.httpShouldHandleCookies = false
                next.connect(request: request)
                // URLSessionWebSocketTask has no separate open callback. Sending hello is
                // the first protocol frame and a failed send returns through reconnect.
                let ready = session.markConnected(identity: identity, generation: callbackGeneration)
                self.session = session
                connection = .connected
                try await transmit(ready, identity: identity, generation: callbackGeneration,
                                   socket: next, runGeneration: own)
                while !Task.isCancelled, own == epoch, activeIdentity == identity {
                    let frame = try await next.receive()
                    failures = 0
                    guard own == epoch, activeIdentity == identity,
                          var current = self.session else { return }
                    let outbound = current.receive(frame, identity: identity, generation: callbackGeneration)
                    self.session = current
                    try await transmit(outbound, identity: identity, generation: callbackGeneration,
                                       socket: next, runGeneration: own)
                }
                return
            } catch {
                guard !Task.isCancelled, own == epoch else { return }
                if var current = session, let identity = activeIdentity {
                    current.sendFailed(identity: identity, generation: current.generation,
                                       message: error.localizedDescription)
                    session = current
                }
            }
            socket?.close()
            socket = nil
            connection = .disconnected
            failures = min(failures + 1, 5)
            do { try await Task.sleep(for: .seconds(min(30, 1 << failures))) }
            catch { return }
        }
    }

    private func send(_ outbound: [NativeShareCollaborationOutbound], identity: NativeShareCollaborationIdentity,
                      generation: Int) {
        guard let socket, !outbound.isEmpty else { return }
        let own = epoch
        Task { [weak self] in
            guard let self else { return }
            do { try await transmit(outbound, identity: identity, generation: generation,
                                    socket: socket, runGeneration: own) }
            catch {
                guard own == epoch, activeIdentity == identity,
                      var current = session else { return }
                current.sendFailed(identity: identity, generation: generation,
                                   message: error.localizedDescription)
                session = current
                self.socket?.close()
            }
        }
    }

    private func transmit(_ outbound: [NativeShareCollaborationOutbound], identity: NativeShareCollaborationIdentity,
                          generation: Int, socket: NativeShareCollaborationSocketTransport,
                          runGeneration: Int) async throws {
        for item in outbound {
            guard runGeneration == epoch, activeIdentity == identity,
                  session?.generation == generation else { return }
            let frame: String
            switch item {
            case let .hello(clientID, userID, displayName):
                frame = try NativeShareCollaborationProtocol.helloFrame(clientID: clientID,
                                                                         userID: userID,
                                                                         displayName: displayName)
            case let .edit(content):
                frame = try NativeShareCollaborationProtocol.editFrame(identity: identity,
                    userID: activeUserID, token: activeToken, content: content)
            case .cursor, .editing:
                continue
            }
            try await socket.send(frame)
        }
    }

    private static func clientID() -> String {
        "desktop-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }
}
