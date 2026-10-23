import Foundation

private final class AccountSubscriptionRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum AccountSubscriptionSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: AccountSubscriptionRedirectDelegate(), delegateQueue: nil)
    }()
}

enum AccountSubscriptionClientError: LocalizedError {
    case signInRequired
    case invalidBaseURL
    case invalidResponse
    case requestFailed(Int)
    case impersonationUnsupported
    case invalidPortalURL

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view subscription information."
        case .invalidBaseURL: "Subscription information requires a valid HTTPS API address."
        case .invalidResponse: "The subscription service returned an invalid response."
        case let .requestFailed(status): "Subscription request failed (HTTP \(status))."
        case .impersonationUnsupported: "Return to your own account to manage billing."
        case .invalidPortalURL: "The billing service returned an invalid management link."
        }
    }
}

struct AccountSubscriptionClient {
    let endpoint: URL
    let userID: String
    let token: String
    let impersonationToken: String
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await AccountSubscriptionSession.shared.data(for: request)
    }

    init(baseURL: URL, userID: String, token: String, impersonationToken: String = "", send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let cleanUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUserID.isEmpty, !cleanToken.isEmpty else {
            throw AccountSubscriptionClientError.signInRequired
        }
        guard baseURL.scheme?.lowercased() == "https", baseURL.host != nil,
              baseURL.user == nil, baseURL.password == nil,
              cleanUserID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              cleanToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw AccountSubscriptionClientError.invalidBaseURL
        }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        guard components?.query == nil, components?.fragment == nil else { throw AccountSubscriptionClientError.invalidBaseURL }
        let path = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.percentEncodedPath = "/" + [path, "billing/subscription"].filter { !$0.isEmpty }.joined(separator: "/")
        guard let endpoint = components?.url, endpoint.scheme == "https", endpoint.host == baseURL.host else {
            throw AccountSubscriptionClientError.invalidBaseURL
        }
        self.endpoint = endpoint
        self.userID = cleanUserID
        self.token = cleanToken
        self.impersonationToken = impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if let send { self.send = send }
    }

    func load() async throws -> AccountSubscriptionEnvelope {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if !impersonationToken.isEmpty {
            request.setValue(impersonationToken, forHTTPHeaderField: "x-impersonation-token")
        }
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw AccountSubscriptionClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AccountSubscriptionClientError.requestFailed(http.statusCode) }
        do { return try JSONDecoder().decode(AccountSubscriptionEnvelope.self, from: data) }
        catch { throw AccountSubscriptionClientError.invalidResponse }
    }

    func createBillingPortalURL() async throws -> URL {
        guard impersonationToken.isEmpty else { throw AccountSubscriptionClientError.impersonationUnsupported }
        var request = URLRequest(url: endpoint.deletingLastPathComponent().appendingPathComponent("portal"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else { throw AccountSubscriptionClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw AccountSubscriptionClientError.requestFailed(http.statusCode) }
        guard let payload = try? JSONDecoder().decode(BillingPortalEnvelope.self, from: data),
              let url = URL(string: payload.url),
              url.scheme?.lowercased() == "https", url.host?.lowercased() == "billing.stripe.com",
              url.user == nil, url.password == nil, url.port == nil else {
            throw AccountSubscriptionClientError.invalidPortalURL
        }
        return url
    }

    private struct BillingPortalEnvelope: Decodable { let url: String }
}
