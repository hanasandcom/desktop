import Foundation

private final class AutomationRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum AutomationSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: AutomationRedirectBlocker(), delegateQueue: nil)
    }()
}

struct AutomationClient {
    private let baseURL: URL
    private let userID: String
    private let token: String
    private let impersonationToken: String
    private let canMutate: Bool
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(settings: HanasandDesktopSettings, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        guard settings.userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              settings.authToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw AutomationClientError.signInRequired
        }
        guard let url = URL(string: settings.apiBaseURL), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw AutomationClientError.invalidBaseURL
        }
        baseURL = settings.apiBaseURL.normalizedBaseURL
        userID = settings.userID
        token = settings.authToken
        impersonationToken = settings.impersonationToken
        canMutate = settings.impersonationToken.isEmpty && settings.impersonatingUserID.isEmpty
        self.send = send ?? { request in try await AutomationSession.shared.data(for: request) }
    }

    func list(scope: String? = nil) async throws -> DesktopAutomationEnvelope {
        guard var components = URLComponents(url: endpoint("automations"), resolvingAgainstBaseURL: false) else {
            throw AutomationClientError.invalidBaseURL
        }
        if let scope { components.queryItems = [URLQueryItem(name: "scope", value: scope)] }
        guard let url = components.url else { throw AutomationClientError.invalidBaseURL }
        return try await request(url)
    }

    func detail(id: String, page: Int = 1, from: Date? = nil, to: Date? = nil) async throws -> DesktopAutomationDetailEnvelope {
        guard Self.validID(id), page > 0 else { throw AutomationClientError.invalidInput }
        guard var components = URLComponents(url: endpoint("automations/\(Self.pathComponent(id))"), resolvingAgainstBaseURL: false) else {
            throw AutomationClientError.invalidBaseURL
        }
        var query = [URLQueryItem(name: "page", value: String(page))]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let from { query.append(URLQueryItem(name: "from", value: formatter.string(from: from))) }
        if let to { query.append(URLQueryItem(name: "to", value: formatter.string(from: to))) }
        components.queryItems = query
        guard let url = components.url else { throw AutomationClientError.invalidBaseURL }
        return try await request(url)
    }

    func save(_ payload: DesktopAutomationPayload, id: String? = nil) async throws -> DesktopAutomationMutationEnvelope {
        try requireMutation()
        if let id, !Self.validID(id) { throw AutomationClientError.invalidInput }
        let path = id.map { "automations/\(Self.pathComponent($0))" } ?? "automations"
        return try await request(endpoint(path), method: id == nil ? "POST" : "PUT", body: JSONEncoder().encode(payload))
    }

    func setStatus(_ id: String, status: String) async throws -> DesktopAutomationMutationEnvelope {
        try requireMutation()
        guard Self.validID(id), ["active", "paused"].contains(status) else { throw AutomationClientError.invalidInput }
        let body = try JSONEncoder().encode(DesktopAutomationStatusPayload(status: status))
        return try await request(endpoint("automations/\(Self.pathComponent(id))"), method: "PUT", body: body)
    }

    func delete(_ id: String) async throws -> DesktopAutomationMutationEnvelope {
        try requireMutation()
        guard Self.validID(id) else { throw AutomationClientError.invalidInput }
        return try await request(endpoint("automations/\(Self.pathComponent(id))"), method: "DELETE")
    }

    func run(_ id: String) async throws -> DesktopAutomationRunNowEnvelope {
        try requireMutation()
        guard Self.validID(id) else { throw AutomationClientError.invalidInput }
        return try await request(endpoint("automations/\(Self.pathComponent(id))/run"), method: "POST")
    }

    func createSenderKey(_ id: String) async throws -> DesktopAutomationSenderKeyEnvelope {
        try requireMutation()
        guard Self.validID(id) else { throw AutomationClientError.invalidInput }
        return try await request(endpoint("automations/\(Self.pathComponent(id))/sender-key"), method: "POST")
    }

    static func pathComponent(_ value: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/?#%")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? ""
    }

    private static func validID(_ value: String) -> Bool {
        value != "." && value != ".." && value.range(of: "^[A-Za-z0-9._~-]{1,256}$", options: .regularExpression) != nil
    }

    private func endpoint(_ path: String) -> URL {
        baseURL.appendingAPIPath(path)
    }

    private func request<T: Decodable>(_ url: URL, method: String = "GET", body: Data? = nil) async throws -> T {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if !impersonationToken.isEmpty { request.setValue(impersonationToken, forHTTPHeaderField: "x-impersonation-token") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse else { throw AutomationClientError.invalidResponse }
        guard response.url?.scheme?.lowercased() == "https", response.url?.host?.lowercased() == baseURL.host?.lowercased() else {
            throw AutomationClientError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else { throw AutomationClientError.requestFailed(response.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw AutomationClientError.invalidResponse }
    }

    private func requireMutation() throws {
        guard canMutate else { throw AutomationClientError.impersonationReadOnly }
    }
}

enum AutomationClientError: LocalizedError, Equatable {
    case signInRequired, invalidBaseURL, invalidInput, invalidResponse, impersonationReadOnly, requestFailed(Int)
    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to manage automations."
        case .invalidBaseURL: "Automations require a secure API address."
        case .invalidInput: "The automation request is invalid."
        case .invalidResponse: "The automation service returned an invalid response."
        case .impersonationReadOnly: "Return to your own account to change automations."
        case .requestFailed(let status) where status == 401: "Your session could not be verified. Sign in again."
        case .requestFailed(let status) where status == 403: "You do not have access to this automation."
        case .requestFailed: "The automation request failed. Refresh to try again."
        }
    }
}
