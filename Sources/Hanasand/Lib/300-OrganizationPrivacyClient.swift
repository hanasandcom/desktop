import Foundation

private final class OrganizationPrivacyRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum OrganizationPrivacySession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: OrganizationPrivacyRedirectDelegate(), delegateQueue: nil)
    }()
}

struct OrganizationPrivacyClient {
    let baseURL: URL
    let organizationID: String
    let userID: String
    let authToken: String
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await OrganizationPrivacySession.shared.data(for: request)
    }

    init(settings: HanasandDesktopSettings, organizationID: String, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let base = settings.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let url = URL(string: base), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw OrganizationPrivacyError.invalidBaseURL
        }
        let user = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !token.isEmpty else { throw OrganizationPrivacyError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw OrganizationPrivacyError.invalidCredentials
        }
        guard !organizationID.isEmpty, organizationID != "personal",
              settings.selectedOrganizationID == organizationID,
              settings.selectedOrganizationUserID == user else { throw OrganizationPrivacyError.organizationScopeChanged }
        guard settings.impersonationToken.isEmpty,
              settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrganizationPrivacyError.impersonationUnsupported
        }
        self.baseURL = url
        self.organizationID = organizationID
        self.userID = user
        self.authToken = token
        if let send { self.send = send }
    }

    func load(offset: Int = 0) async throws -> OrganizationPrivacySnapshot {
        guard (0...100_000).contains(offset), offset % 50 == 0 else { throw OrganizationPrivacyError.invalidOffset }
        let segment = organizationID.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { throw OrganizationPrivacyError.invalidBaseURL }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [basePath, "organizations/\(segment)/privacy"].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = [URLQueryItem(name: "itemOffset", value: String(offset)), URLQueryItem(name: "itemLimit", value: "50")]
        guard let url = components.url, url.scheme == "https", url.host == baseURL.host else { throw OrganizationPrivacyError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        let (data, response) = try await send(request)
        guard data.count <= 4 * 1024 * 1024 else { throw OrganizationPrivacyError.invalidResponse }
        guard let http = response as? HTTPURLResponse else { throw OrganizationPrivacyError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(ApiErrorEnvelope.self, from: data)
            throw OrganizationPrivacyError.requestFailed(http.statusCode, envelope?.error.message ?? "Privacy could not be loaded.")
        }
        let snapshot: OrganizationPrivacySnapshot
        do { snapshot = try JSONDecoder().decode(OrganizationPrivacySnapshot.self, from: data) }
        catch { throw OrganizationPrivacyError.invalidResponse }
        try snapshot.validate(organizationID: organizationID, requestedOffset: offset)
        return snapshot
    }

    private struct ApiErrorEnvelope: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
}
