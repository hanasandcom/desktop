import Foundation

private final class ProfileAccountSessionsRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum ProfileAccountSessionsTransport {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: ProfileAccountSessionsRedirectDelegate(), delegateQueue: nil)
    }()
}

enum ProfileAccountSessionsClientError: LocalizedError, Equatable {
    case signInRequired
    case invalidBaseURL
    case impersonationUnsupported
    case invalidResponse
    case requestFailed(Int)
    case currentSessionRequiresLogout

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to review account sessions."
        case .invalidBaseURL: "Sessions require a valid HTTPS API address."
        case .impersonationUnsupported: "Return to your own account to manage sessions."
        case .invalidResponse: "The session service returned an invalid response."
        case let .requestFailed(status): "Session request failed (HTTP \(status))."
        case .currentSessionRequiresLogout: "Use Log out to end this device’s session."
        }
    }
}

struct ProfileAccountSession: Decodable, Identifiable, Equatable {
    let tokenID: Int
    let ip: String?
    let privateIP: String?
    let current: Bool
    let userAgent: String
    let createdAt: String
    let lastSeenAt: String
    let revokedAt: String?
    let network: Network?

    struct Network: Decodable, Equatable {
        let provider: String?
        let country: String?
        let region: String?
        let city: String?
    }

    enum CodingKeys: String, CodingKey {
        case tokenID = "token_id"
        case ip
        case privateIP = "private_ip"
        case current
        case userAgent = "user_agent"
        case createdAt = "created_at"
        case lastSeenAt = "last_seen_at"
        case revokedAt = "revoked_at"
        case network
    }

    var id: Int { tokenID }
    var isActive: Bool { revokedAt == nil }
    var deviceLabel: String {
        let agent = userAgent.lowercased()
        if (ip == nil || ip?.isEmpty == true) && agent.range(of: "^bun/", options: .regularExpression) != nil {
            return "Device details unavailable"
        }
        if agent.range(of: "hanasand[-_\\s]?desktop|desktop[-_\\s]?app|tauri|electron", options: .regularExpression) != nil { return "Hanasand desktop app" }
        if agent.range(of: "hanasand[-_\\s]?mobile|mobile[-_\\s]?app|reactnative|expo|okhttp", options: .regularExpression) != nil { return "Mobile app" }
        if agent.range(of: "curl|node|bun/|monitor|playwright|python", options: .regularExpression) != nil { return "Automation or API client" }
        let browser: String
        if agent.contains("edg/") { browser = "Edge" }
        else if agent.contains("opr/") { browser = "Opera" }
        else if agent.contains("firefox/") { browser = "Firefox" }
        else if agent.contains("chrome/") { browser = "Chrome" }
        else if agent.contains("safari/") { browser = "Safari" }
        else { browser = "" }
        let os: String
        if userAgent.localizedCaseInsensitiveContains("iPhone") { os = "iPhone" }
        else if userAgent.localizedCaseInsensitiveContains("iPad") { os = "iPad" }
        else if userAgent.localizedCaseInsensitiveContains("Android") { os = "Android" }
        else if userAgent.localizedCaseInsensitiveContains("Windows") { os = "Windows" }
        else if userAgent.localizedCaseInsensitiveContains("Mac OS X") || userAgent.localizedCaseInsensitiveContains("Macintosh") { os = "macOS" }
        else if userAgent.localizedCaseInsensitiveContains("Linux") { os = "Linux" }
        else { os = "" }
        if !browser.isEmpty && !os.isEmpty { return "\(browser) on \(os)" }
        if !browser.isEmpty { return browser }
        if !os.isEmpty { return os }
        return userAgent.isEmpty ? "Device details unavailable" : "Unknown client"
    }

    var addressLabel: String {
        if let ip, !ip.isEmpty { return "Public IP \(ip)" }
        if let privateIP, !privateIP.isEmpty { return "Private IP \(privateIP)" }
        return "Public IP was not captured for this login"
    }

    var networkLabel: String {
        if (ip == nil || ip?.isEmpty == true), privateIP != nil { return "Private network" }
        if let provider = network?.provider, !provider.isEmpty { return provider }
        return "Unavailable"
    }

    var locationLabel: String {
        if (ip == nil || ip?.isEmpty == true), privateIP != nil { return "Unavailable for private addresses" }
        let values = [network?.city, network?.region, network?.country].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
        let unique = values.reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
        return unique.isEmpty ? "Unavailable" : unique.joined(separator: ", ")
    }

    func matches(search terms: [String]) -> Bool {
        guard !terms.isEmpty else { return true }
        let state = current ? "this device current session" : (isActive ? "active" : "revoked")
        let searchable = [deviceLabel, addressLabel, networkLabel, locationLabel, userAgent, state].joined(separator: " ").lowercased()
        return terms.allSatisfy(searchable.contains)
    }
}

struct ProfileAccountSessionsEnvelope: Decodable {
    let sessions: [ProfileAccountSession]
}

struct ProfileAccountSessionsClient {
    let baseURL: URL
    let userID: String
    let token: String
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await ProfileAccountSessionsTransport.shared.data(for: request)
    }

    init(baseURL: URL, userID: String, token: String, impersonationToken: String = "", impersonatingUserID: String = "", send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !auth.isEmpty else { throw ProfileAccountSessionsClientError.signInRequired }
        guard impersonationToken.isEmpty, impersonatingUserID.isEmpty else { throw ProfileAccountSessionsClientError.impersonationUnsupported }
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              auth.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw ProfileAccountSessionsClientError.invalidBaseURL
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        guard components?.query == nil, components?.fragment == nil else { throw ProfileAccountSessionsClientError.invalidBaseURL }
        let prefix = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.percentEncodedPath = "/" + [prefix, "auth/sessions"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let normalized = components?.url, normalized.scheme == "https", normalized.host == baseURL.host else { throw ProfileAccountSessionsClientError.invalidBaseURL }
        self.baseURL = normalized
        self.userID = user
        self.token = auth
        if let send { self.send = send }
    }

    func load() async throws -> [ProfileAccountSession] {
        let response = try await perform(path: "", method: "GET")
        do { return try JSONDecoder().decode(ProfileAccountSessionsEnvelope.self, from: response.0).sessions }
        catch { throw ProfileAccountSessionsClientError.invalidResponse }
    }

    func revoke(_ session: ProfileAccountSession) async throws {
        guard !session.current else { throw ProfileAccountSessionsClientError.currentSessionRequiresLogout }
        _ = try await perform(path: "/\(session.tokenID)", method: "DELETE")
    }

    func revokeOthers() async throws {
        let body = try JSONEncoder().encode(RevokeOthersPayload(keepCurrent: true))
        _ = try await perform(path: "/revoke", method: "POST", body: body)
    }

    private func perform(path: String, method: String, body: Data? = nil) async throws -> (Data, URLResponse) {
        let url = path.isEmpty ? baseURL : baseURL.appending(path: path)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let result = try await send(request)
        guard let http = result.1 as? HTTPURLResponse else { throw ProfileAccountSessionsClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ProfileAccountSessionsClientError.requestFailed(http.statusCode) }
        return result
    }

    private struct RevokeOthersPayload: Encodable { let keepCurrent: Bool; enum CodingKeys: String, CodingKey { case keepCurrent = "keep_current" } }
}
