import Foundation

private final class SocialConnectionsRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum SocialConnectionsSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: SocialConnectionsRedirectBlocker(), delegateQueue: nil)
    }()
}

struct SocialConnection: Decodable, Equatable, Identifiable {
    let provider: String
    let email: String?

    var id: String { provider }
}

private struct SocialConnectionsEnvelope: Decodable {
    let connections: [SocialConnection]
}

private struct SocialProvidersEnvelope: Decodable {
    let providers: [SocialProviderStatus]
}

private struct SocialProviderStatus: Decodable {
    let provider: String
    let configured: Bool
}

enum SocialConnectionsClientError: LocalizedError, Equatable {
    case signInRequired
    case ownAccountRequired
    case invalidEndpoint
    case invalidResponse
    case invalidProvidersResponse
    case requestFailed(Int)
    case providersRequestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view connected accounts."
        case .ownAccountRequired: "Return to your own account to view connected accounts."
        case .invalidEndpoint: "Connected accounts require a valid secure API address."
        case .invalidResponse: "The connected accounts response could not be verified. Refresh and review the current state."
        case .invalidProvidersResponse: "The sign-in provider status could not be verified. Refresh and review the current state."
        case let .requestFailed(status): "Connected accounts request failed (HTTP \(status))."
        case let .providersRequestFailed(status): "Sign-in provider status request failed (HTTP \(status))."
        }
    }
}

struct SocialConnectionsClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

    let endpoint: URL
    let providersEndpoint: URL
    let userID: String
    let token: String
    var send: Sender

    init(settings: HanasandDesktopSettings, send: Sender? = nil) throws {
        let rawBase = settings.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let apiBase = URL(string: rawBase), apiBase.scheme?.lowercased() == "https",
              apiBase.host != nil, apiBase.user == nil, apiBase.password == nil,
              apiBase.query == nil, apiBase.fragment == nil else {
            throw SocialConnectionsClientError.invalidEndpoint
        }

        let user = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !credential.isEmpty else { throw SocialConnectionsClientError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw SocialConnectionsClientError.invalidEndpoint
        }
        guard settings.impersonationToken.isEmpty,
              settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SocialConnectionsClientError.ownAccountRequired
        }

        var identityBase = apiBase
        if apiBase.host?.lowercased() == "api.hanasand.com" {
            var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)
            components?.host = "identity.hanasand.com"
            guard let identityURL = components?.url else { throw SocialConnectionsClientError.invalidEndpoint }
            identityBase = identityURL
        }
        let url = identityBase.appendingAPIPath("auth/social/connections")
        guard url.scheme?.lowercased() == "https", url.host == identityBase.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw SocialConnectionsClientError.invalidEndpoint
        }

        endpoint = url
        providersEndpoint = identityBase.appendingAPIPath("auth/social/providers")
        userID = user
        token = credential
        self.send = send ?? { request in try await SocialConnectionsSession.shared.data(for: request) }
    }

    func load() async throws -> [SocialConnection] {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https", http.url?.host == endpoint.host else {
            throw SocialConnectionsClientError.invalidResponse
        }
        guard http.statusCode == 200 else { throw SocialConnectionsClientError.requestFailed(http.statusCode) }

        let envelope: SocialConnectionsEnvelope
        do { envelope = try JSONDecoder().decode(SocialConnectionsEnvelope.self, from: data) }
        catch { throw SocialConnectionsClientError.invalidResponse }
        guard Set(envelope.connections.map(\.provider)).count == envelope.connections.count,
              envelope.connections.allSatisfy(Self.isValid) else {
            throw SocialConnectionsClientError.invalidResponse
        }
        return envelope.connections
    }

    func isGoogleConfigured() async throws -> Bool {
        var request = URLRequest(url: providersEndpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https", http.url?.host == providersEndpoint.host else {
            throw SocialConnectionsClientError.invalidProvidersResponse
        }
        guard http.statusCode == 200 else { throw SocialConnectionsClientError.providersRequestFailed(http.statusCode) }

        let envelope: SocialProvidersEnvelope
        do { envelope = try JSONDecoder().decode(SocialProvidersEnvelope.self, from: data) }
        catch { throw SocialConnectionsClientError.invalidProvidersResponse }
        guard Set(envelope.providers.map(\.provider)).count == envelope.providers.count,
              envelope.providers.allSatisfy({ ["google", "apple"].contains($0.provider) }),
              let google = envelope.providers.first(where: { $0.provider == "google" }) else {
            throw SocialConnectionsClientError.invalidProvidersResponse
        }
        return google.configured
    }

    private static func isValid(_ connection: SocialConnection) -> Bool {
        guard ["google", "apple"].contains(connection.provider) else { return false }
        guard let email = connection.email else { return true }
        return email.count <= 254 && !email.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
    }
}
