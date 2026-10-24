import Foundation

enum ArticleWorkspaceError: Error, LocalizedError, Equatable {
    case invalidBaseURL
    case signInRequired
    case invalidCredentials
    case impersonationUnsupported
    case invalidArticleID
    case invalidResponse
    case workspaceUnavailable
    case readOnly
    case scopeChanged
    case requestFailed(Int, String)

    var statusCode: Int? {
        if case .requestFailed(let status, _) = self { return status }
        return nil
    }

    var isDefiniteRejection: Bool {
        if let statusCode { return ArticleMutationSafety.isDefiniteRejection(status: statusCode) }
        switch self {
        case .invalidBaseURL, .signInRequired, .invalidCredentials, .impersonationUnsupported,
             .invalidArticleID, .workspaceUnavailable, .readOnly, .scopeChanged:
            return true
        case .invalidResponse, .requestFailed(_, _):
            return false
        }
    }

    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: "Articles require a secure API address."
        case .signInRequired: "Sign in to open the publishing workspace."
        case .invalidCredentials: "The publishing credentials are invalid. Sign in again."
        case .impersonationUnsupported: "Return to your own account before changing articles."
        case .invalidArticleID: "Use a valid article filename with letters, numbers, underscores, dashes, or dots."
        case .invalidResponse: "The publishing service returned an invalid response."
        case .workspaceUnavailable: "Refresh the selected organization and verify active publishing access."
        case .readOnly: "Your current account can read this workspace but cannot publish articles."
        case .scopeChanged: "The article belongs to a different workspace. Refresh the selected workspace before continuing."
        case .requestFailed(let status, let message): "Article request returned HTTP \(status): \(message)"
        }
    }
}

struct ArticleWorkspaceAccess: Equatable {
    let organizationID: String?
    let canRead: Bool
    let canWrite: Bool
}

enum ArticleWorkspacePolicy {
    static func organizationID(_ value: String) -> String? {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty || clean == "personal" ? nil : clean
    }

    static func articleID(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let id = clean.hasSuffix(".md") ? clean : clean + ".md"
        guard id.utf8.count <= 200,
              id.range(of: "^[A-Za-z0-9_.-]+\\.md$", options: .regularExpression) != nil,
              !id.hasPrefix(".") else { throw ArticleWorkspaceError.invalidArticleID }
        return id
    }

    static func articleBelongs(_ article: DashboardArticle, to organizationID: String?) -> Bool {
        article.organizationID == organizationID
    }

    static func canWriteOrganization(role: String, status: String) -> Bool {
        status.lowercased() == "active" && ["owner", "admin", "editor"].contains(role.lowercased())
    }
}

struct ArticleWorkspaceRequestContext: Equatable {
    let userID: String
    let authToken: String
    let apiBaseURL: String
    let organizationID: String?
    let selectedOrganizationID: String?
    let organizationUserID: String
    let impersonationToken: String
    let impersonatingUserID: String

    init(settings: HanasandDesktopSettings, userID: String, authToken: String, organizationID: String) {
        self.userID = userID
        self.authToken = authToken
        self.apiBaseURL = settings.apiBaseURL
        self.organizationID = ArticleWorkspacePolicy.organizationID(organizationID)
        self.selectedOrganizationID = ArticleWorkspacePolicy.organizationID(settings.selectedOrganizationID)
        self.organizationUserID = settings.selectedOrganizationUserID
        self.impersonationToken = settings.impersonationToken
        self.impersonatingUserID = settings.impersonatingUserID
    }

    func matches(settings: HanasandDesktopSettings, userID: String, authToken: String, organizationID: String) -> Bool {
        self == ArticleWorkspaceRequestContext(
            settings: settings,
            userID: userID,
            authToken: authToken,
            organizationID: organizationID
        )
    }
}

private final class ArticleWorkspaceRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum ArticleWorkspaceSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: ArticleWorkspaceRedirectBlocker(), delegateQueue: nil)
    }()
}

struct ArticleWorkspaceClient {
    let apiBaseURL: URL
    let identityBaseURL: URL
    let userID: String
    let authToken: String
    let impersonationToken: String
    let isImpersonating: Bool
    let organizationID: String?
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await ArticleWorkspaceSession.shared.data(for: request)
    }

    init(settings: HanasandDesktopSettings, userID: String, authToken: String, organizationID: String,
         send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let rawBase = settings.apiBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let apiBase = URL(string: rawBase), apiBase.scheme?.lowercased() == "https", apiBase.host != nil,
              apiBase.user == nil, apiBase.password == nil, apiBase.query == nil, apiBase.fragment == nil else {
            throw ArticleWorkspaceError.invalidBaseURL
        }
        let cleanUser = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanUser.isEmpty, !cleanToken.isEmpty else { throw ArticleWorkspaceError.signInRequired }
        guard cleanUser.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              cleanToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw ArticleWorkspaceError.invalidCredentials
        }
        let selected = ArticleWorkspacePolicy.organizationID(organizationID)
        guard ArticleWorkspacePolicy.organizationID(settings.selectedOrganizationID) == selected,
              selected == nil || settings.selectedOrganizationUserID == cleanUser else {
            throw ArticleWorkspaceError.scopeChanged
        }
        let impersonating = !settings.impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || !settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        var identityBase = apiBase
        if apiBase.host?.lowercased() == "api.hanasand.com" {
            var components = URLComponents(url: apiBase, resolvingAgainstBaseURL: false)
            components?.host = "identity.hanasand.com"
            guard let identityURL = components?.url else { throw ArticleWorkspaceError.invalidBaseURL }
            identityBase = identityURL
        }

        self.apiBaseURL = apiBase
        self.identityBaseURL = identityBase
        self.userID = cleanUser
        self.authToken = cleanToken
        self.impersonationToken = settings.impersonationToken
        self.isImpersonating = impersonating
        self.organizationID = selected
        if let send { self.send = send }
    }

    func loadAccess() async throws -> ArticleWorkspaceAccess {
        if let organizationID {
            let envelope: DashboardIdentityOrganizationsEnvelope = try await request(
                baseURL: identityBaseURL, path: "organizations", method: "GET", organizationHeader: nil
            )
            guard let organization = envelope.organizations.first(where: { $0.id == organizationID }),
                  organization.lifecycleStatus.lowercased() == "active" else { throw ArticleWorkspaceError.workspaceUnavailable }
            return ArticleWorkspaceAccess(
                organizationID: organizationID,
                canRead: true,
                canWrite: ArticleWorkspacePolicy.canWriteOrganization(role: organization.role, status: organization.lifecycleStatus)
                    && !isImpersonating
            )
        }

        let access: InternalArticleAccess = try await request(
            baseURL: apiBaseURL, path: "management/organizations?internalPages=1", method: "GET", organizationHeader: nil
        )
        return ArticleWorkspaceAccess(organizationID: nil, canRead: true, canWrite: access.allowed && access.canEdit && !isImpersonating)
    }

    func list() async throws -> [DashboardArticle] {
        let data = try await requestData(path: "articles?workspace=true", method: "GET", organizationHeader: organizationID)
        let rows: [DashboardArticle]
        do { rows = try JSONDecoder().decode([DashboardArticle].self, from: data) }
        catch { throw ArticleWorkspaceError.invalidResponse }
        guard rows.count <= 100_000,
              Set(rows.map(\.id)).count == rows.count,
              rows.allSatisfy({ (try? ArticleWorkspacePolicy.articleID($0.id)) == $0.id && ArticleWorkspacePolicy.articleBelongs($0, to: organizationID) }) else {
            throw ArticleWorkspaceError.scopeChanged
        }
        return rows
    }

    func detail(_ rawID: String) async throws -> DashboardArticle {
        let id = try ArticleWorkspacePolicy.articleID(rawID)
        let data = try await requestData(path: "article/\(segment(id))", method: "GET", organizationHeader: organizationID)
        return try decodeDetail(data, expectedID: id, organizationID: organizationID)
    }

    func detailForLegacyReview(_ rawID: String) async throws -> DashboardArticle {
        let id = try ArticleWorkspacePolicy.articleID(rawID)
        let data = try await requestData(path: "article/\(segment(id))", method: "GET", organizationHeader: nil)
        return try decodeDetail(data, expectedID: id, organizationID: nil, checkOrganization: false)
    }

    private func decodeDetail(_ data: Data, expectedID: String, organizationID expectedOrganizationID: String?, checkOrganization: Bool = true) throws -> DashboardArticle {
        let article: DashboardArticle
        do { article = try JSONDecoder().decode(DashboardArticle.self, from: data) }
        catch { throw ArticleWorkspaceError.invalidResponse }
        guard article.id == expectedID, article.content != nil,
              !checkOrganization || ArticleWorkspacePolicy.articleBelongs(article, to: expectedOrganizationID) else { throw ArticleWorkspaceError.scopeChanged }
        return article
    }

    func prepareCreate(_ rawID: String) async throws {
        let id = try ArticleWorkspacePolicy.articleID(rawID)
        do {
            _ = try await detail(id)
            throw ArticleWorkspaceError.requestFailed(409, "That article filename already exists in the repository.")
        } catch let error as ArticleWorkspaceError {
            guard error.statusCode == 404 else { throw error }
        }
    }

    func prepareExisting(_ article: DashboardArticle) async throws {
        guard ArticleWorkspacePolicy.articleBelongs(article, to: organizationID) else { throw ArticleWorkspaceError.scopeChanged }
        let current = try await detail(article.id)
        guard current.id == article.id else { throw ArticleWorkspaceError.scopeChanged }
    }

    func mutate(_ action: ArticleMutationAction, articleID rawID: String, content: String?, original: DashboardArticle?, access: ArticleWorkspaceAccess) async throws -> String {
        try requireWriter(access, original: original)
        let id = try ArticleWorkspacePolicy.articleID(rawID)
        guard id == rawID else { throw ArticleWorkspaceError.invalidArticleID }
        if let original, original.id != id { throw ArticleWorkspaceError.scopeChanged }
        if action != .delete {
            guard let content, !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  content.utf8.count <= 1_000_000 else { throw ArticleWorkspaceError.requestFailed(400, "Enter article content up to 1,000,000 bytes.") }
        }
        let method = action == .create ? "POST" : action == .update ? "PUT" : "DELETE"
        let body = action == .delete ? nil : try JSONEncoder().encode(ArticleContentPayload(content: content ?? ""))
        let (data, status) = try await requestDataWithStatus(
            path: "article/\(segment(id))", method: method, body: body, organizationHeader: organizationID
        )
        let receipt = String(data: data, encoding: .utf8) ?? ""
        guard status == (action == .create ? 201 : 200),
              ArticleMutationSafety.isValidReceipt(receipt, action: action, articleID: id) else {
            throw ArticleWorkspaceError.invalidResponse
        }
        return receipt
    }

    private func requireWriter(_ access: ArticleWorkspaceAccess, original: DashboardArticle?) throws {
        guard access.organizationID == organizationID, access.canRead, access.canWrite, !isImpersonating else {
            throw ArticleWorkspaceError.readOnly
        }
        if let original, !ArticleWorkspacePolicy.articleBelongs(original, to: organizationID) { throw ArticleWorkspaceError.scopeChanged }
    }

    private func request<T: Decodable>(baseURL: URL, path: String, method: String, organizationHeader: String?) async throws -> T {
        let data = try await requestData(baseURL: baseURL, path: path, method: method, organizationHeader: organizationHeader)
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ArticleWorkspaceError.invalidResponse }
    }

    private func requestData(path: String, method: String, body: Data? = nil, organizationHeader: String?) async throws -> Data {
        let (data, _) = try await requestDataWithStatus(path: path, method: method, body: body, organizationHeader: organizationHeader)
        return data
    }

    private func requestDataWithStatus(path: String, method: String, body: Data? = nil, organizationHeader: String?) async throws -> (Data, Int) {
        try await requestDataWithStatus(baseURL: apiBaseURL, path: path, method: method, body: body, organizationHeader: organizationHeader)
    }

    private func requestDataWithStatus(baseURL: URL, path: String, method: String, body: Data? = nil, organizationHeader: String?) async throws -> (Data, Int) {
        guard let url = endpointURL(baseURL: baseURL, path: path) else { throw ArticleWorkspaceError.invalidBaseURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if let organizationHeader { request.setValue(organizationHeader, forHTTPHeaderField: "x-organization-id") }
        if !impersonationToken.isEmpty { request.setValue(impersonationToken, forHTTPHeaderField: "x-impersonation-token") }
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https", http.url?.host?.lowercased() == baseURL.host?.lowercased() else {
            throw ArticleWorkspaceError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(ArticleWorkspaceAPIError.self, from: data).error.message) ?? "The publishing request failed."
            throw ArticleWorkspaceError.requestFailed(http.statusCode, message)
        }
        return (data, http.statusCode)
    }

    private func requestData(baseURL: URL, path: String, method: String, organizationHeader: String?) async throws -> Data {
        let (data, _) = try await requestDataWithStatus(baseURL: baseURL, path: path, method: method, organizationHeader: organizationHeader)
        return data
    }

    private func endpointURL(baseURL: URL, path: String) -> URL? {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let safePath = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encodedPath = String(parts[0]).split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: safePath) ?? "" }.joined(separator: "/")
        components.percentEncodedPath = "/" + [basePath, encodedPath].filter { !$0.isEmpty }.joined(separator: "/")
        if parts.count == 2 { components.percentEncodedQuery = String(parts[1]) }
        return components.url
    }

    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }
}

private struct InternalArticleAccess: Decodable {
    let allowed: Bool
    let canEdit: Bool
}

private struct ArticleContentPayload: Encodable {
    let content: String
}

private struct ArticleWorkspaceAPIError: Decodable {
    let error: Message
    struct Message: Decodable { let message: String }
}
