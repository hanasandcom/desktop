import Foundation

private final class OrganizationDirectoryRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum OrganizationDirectorySession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: OrganizationDirectoryRedirectBlocker(), delegateQueue: nil)
    }()
}

struct OrganizationDirectoryClient {
    let apiBaseURL: URL
    let identityBaseURL: URL
    let userID: String
    let authToken: String
    let impersonationToken: String
    let isImpersonating: Bool
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await OrganizationDirectorySession.shared.data(for: request)
    }

    init(settings: HanasandDesktopSettings,
         send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let rawBase = settings.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let apiBase = URL(string: rawBase), apiBase.scheme?.lowercased() == "https", apiBase.host != nil,
              apiBase.user == nil, apiBase.password == nil, apiBase.query == nil, apiBase.fragment == nil else {
            throw OrganizationDirectoryClientError.invalidBaseURL
        }
        let user = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !token.isEmpty else { throw OrganizationDirectoryClientError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw OrganizationDirectoryClientError.invalidCredentials
        }

        var identityBase = apiBase
        if apiBase.host?.lowercased() == "api.hanasand.com" {
            var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)
            components?.host = "identity.hanasand.com"
            guard let identityURL = components?.url else { throw OrganizationDirectoryClientError.invalidBaseURL }
            identityBase = identityURL
        }

        apiBaseURL = apiBase
        identityBaseURL = identityBase
        userID = user
        authToken = token
        impersonationToken = settings.impersonationToken
        isImpersonating = !settings.impersonationToken.isEmpty
            || !settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let send { self.send = send }
    }

    func loadSnapshot() async throws -> DashboardOrganizationDirectorySnapshot {
        do {
            let directory: DashboardDirectoryOrganizationsEnvelope = try await request(
                baseURL: apiBaseURL, path: "management/organizations", method: "GET"
            )
            let memberships = try await loadOwnMemberships()
            return DashboardOrganizationDirectorySnapshot(
                organizations: directory.organizations,
                memberships: memberships.map(\.activeMembership)
            )
        } catch OrganizationDirectoryClientError.requestFailed(403, _) {
            let ownOrganizations = try await loadOwnOrganizations()
            return DashboardOrganizationDirectorySnapshot(
                organizations: ownOrganizations.map(\.directoryOrganization),
                memberships: ownOrganizations.map(\.activeMembership)
            )
        }
    }

    func createOrganization(name: String) async throws -> String {
        guard !isImpersonating else { throw OrganizationDirectoryClientError.impersonationUnsupported }
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanName.isEmpty else { throw OrganizationDirectoryClientError.invalidName }
        let body = try JSONEncoder().encode(CreateOrganizationPayload(name: cleanName))
        let receipt: CreateOrganizationReceipt = try await request(
            baseURL: identityBaseURL, path: "organizations", method: "POST", body: body, expectedStatus: 201
        )
        let id = receipt.organization.id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty,
              !receipt.organization.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw OrganizationDirectoryClientError.invalidResponse
        }
        return id
    }

    private func loadOwnMemberships() async throws -> [DashboardIdentityOrganization] {
        try await loadOwnOrganizations()
    }

    private func loadOwnOrganizations() async throws -> [DashboardIdentityOrganization] {
        let envelope: DashboardIdentityOrganizationsEnvelope = try await request(
            baseURL: identityBaseURL, path: "organizations", method: "GET"
        )
        return envelope.organizations
    }

    private func request<T: Decodable>(baseURL: URL, path: String, method: String, body: Data? = nil,
                                       expectedStatus: Int? = nil) async throws -> T {
        guard let url = endpointURL(baseURL: baseURL, path: path) else { throw OrganizationDirectoryClientError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if !impersonationToken.isEmpty {
            request.setValue(impersonationToken, forHTTPHeaderField: "x-impersonation-token")
        }

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https", http.url?.host == baseURL.host else {
            throw OrganizationDirectoryClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode), expectedStatus == nil || http.statusCode == expectedStatus else {
            let message = (try? JSONDecoder().decode(OrganizationDirectoryAPIError.self, from: data).error.message)
                ?? "Organization request failed."
            throw OrganizationDirectoryClientError.requestFailed(http.statusCode, message)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw OrganizationDirectoryClientError.invalidResponse }
    }

    private func endpointURL(baseURL: URL, path: String) -> URL? {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let safePathCharacters = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%")
        let encodedPath = path.split(separator: "/").map {
            String($0).addingPercentEncoding(withAllowedCharacters: safePathCharacters) ?? ""
        }.joined(separator: "/")
        components.percentEncodedPath = "/" + [basePath, encodedPath].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components.url, url.scheme?.lowercased() == "https", url.host == baseURL.host else { return nil }
        return url
    }

    private struct CreateOrganizationPayload: Encodable { let name: String }
    private struct CreateOrganizationReceipt: Decodable {
        let organization: CreatedOrganization
        let lifecycleReadiness: JSONValue
    }
    private struct CreatedOrganization: Decodable { let id: String; let name: String }
    private struct OrganizationDirectoryAPIError: Decodable {
        struct Detail: Decodable { let message: String }
        let error: Detail
    }
}

enum OrganizationDirectoryClientError: LocalizedError {
    case invalidBaseURL, signInRequired, invalidCredentials, impersonationUnsupported, invalidName, invalidResponse
    case requestFailed(Int, String)

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Organizations require a secure API URL."
        case .signInRequired: return "Sign in to view organizations."
        case .invalidCredentials: return "The current account credentials are invalid. Sign in again."
        case .impersonationUnsupported: return "Return to your own account before creating an organization."
        case .invalidName: return "Enter an organization name."
        case .invalidResponse: return "The organization service returned an invalid response."
        case let .requestFailed(status, message): return "Organization request returned HTTP \(status): \(message)"
        }
    }
}
