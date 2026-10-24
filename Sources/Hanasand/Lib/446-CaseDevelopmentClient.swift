import Foundation

struct CaseDevelopmentClient {
    private let settings: HanasandDesktopSettings
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(settings: HanasandDesktopSettings, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        guard !settings.userID.isEmpty, !settings.authToken.isEmpty else { throw CaseDevelopmentClientError.signInRequired }
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else {
            throw CaseDevelopmentClientError.impersonationUnsupported
        }
        guard settings.userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              settings.authToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil,
              let api = URL(string: settings.apiBaseURL), api.scheme?.lowercased() == "https",
              api.host != nil, api.user == nil, api.password == nil, api.query == nil, api.fragment == nil else {
            throw CaseDevelopmentClientError.invalidEndpoint
        }
        self.settings = settings
        if let send { self.send = send }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: CaseDevelopmentRedirectBlocker(), delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    func load(caseID: String, offset: Int = 0, organizationID: String? = nil) async throws -> CaseDevelopmentPage {
        guard Self.validCaseID(caseID), (0...9_999_999).contains(offset) else { throw CaseDevelopmentClientError.invalidInput }
        let data = try await request(path: "cases/development", query: [
            URLQueryItem(name: "caseId", value: caseID), URLQueryItem(name: "offset", value: String(offset)),
        ], organizationID: organizationID)
        let page: CaseDevelopmentPage = try decode(data)
        guard page.items.count <= 50, Set(page.items.map(\.id)).count == page.items.count,
              page.items.allSatisfy({ $0.isValid() }) else { throw CaseDevelopmentClientError.invalidResponse }
        return page
    }

    func loadRepositories(organizationID: String? = nil) async throws -> [CaseDevelopmentRepository] {
        let data = try await request(path: "cases/repositories", organizationID: organizationID)
        let envelope: RepositoryEnvelope = try decode(data)
        guard envelope.items.count <= 500, Set(envelope.items.map(\.id)).count == envelope.items.count,
              envelope.items.allSatisfy({ $0.isValid(expectedOrganizationID: organizationID) }) else {
            throw CaseDevelopmentClientError.invalidResponse
        }
        return envelope.items
    }

    func loadCommits(repositoryID: String, search: String, cursor: String?, organizationID: String? = nil) async throws -> CaseDevelopmentCommitPage {
        guard CaseDevelopmentRepository.validID(repositoryID), search.utf8.count <= 200,
              cursor.map({ $0.range(of: "^[A-Fa-f0-9]{40,64}$", options: .regularExpression) != nil }) ?? true else {
            throw CaseDevelopmentClientError.invalidInput
        }
        var query = [
            URLQueryItem(name: "repositoryId", value: repositoryID),
            URLQueryItem(name: "search", value: search),
        ]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await request(path: "cases/development/commits", query: query, organizationID: organizationID)
        let page: CaseDevelopmentCommitPage = try decode(data)
        guard page.items.count <= 100, Set(page.items.map(\.id)).count == page.items.count,
              page.items.allSatisfy({ $0.isValid() }),
              page.nextCursor.map({ $0.range(of: "^[A-Fa-f0-9]{40,64}$", options: .regularExpression) != nil }) ?? true else {
            throw CaseDevelopmentClientError.invalidResponse
        }
        return page
    }

    func link(commit: String, repositoryID: String, caseID: String, organizationID: String? = nil) async throws {
        guard CaseDevelopmentRepository.validID(repositoryID), Self.validCaseID(caseID),
              commit.range(of: "^[A-Fa-f0-9]{40,64}$", options: .regularExpression) != nil else {
            throw CaseDevelopmentClientError.invalidInput
        }
        let body = try JSONSerialization.data(withJSONObject: ["repositoryId": repositoryID, "caseId": caseID, "commit": commit], options: [.sortedKeys])
        let data = try await request(path: "cases/development/commits", method: "POST", query: [], body: body, organizationID: organizationID)
        let receipt: CaseDevelopmentMutationReceipt = try decode(data)
        guard receipt.ok else { throw CaseDevelopmentClientError.invalidResponse }
    }

    func connect(provider: String, repositoryURL: String, organizationID: String? = nil) async throws -> CaseDevelopmentRepositorySetup {
        let cleanURL = repositoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ["github", "forgejo", "gitlab"].contains(provider), Self.validRepositoryURL(cleanURL) else {
            throw CaseDevelopmentClientError.invalidInput
        }
        let body = try JSONSerialization.data(withJSONObject: ["provider": provider, "repositoryUrl": cleanURL], options: [.sortedKeys])
        let data = try await request(path: "cases/repositories", method: "POST", query: [], body: body, organizationID: organizationID)
        let setup: CaseDevelopmentRepositorySetup = try decode(data)
        guard CaseDevelopmentRepository.validID(setup.id), setup.secret.range(of: "^[A-Fa-f0-9]{64}$", options: .regularExpression) != nil,
              setup.webhookPath == "/api/cases/repository-events/\(setup.id)" else {
            throw CaseDevelopmentClientError.invalidResponse
        }
        return setup
    }

    func disconnect(repositoryID: String, organizationID: String? = nil) async throws {
        guard CaseDevelopmentRepository.validID(repositoryID) else { throw CaseDevelopmentClientError.invalidInput }
        let data = try await request(path: "cases/repositories/\(repositoryID)", method: "DELETE", organizationID: organizationID)
        let receipt: CaseDevelopmentMutationReceipt = try decode(data)
        guard receipt.ok else { throw CaseDevelopmentClientError.invalidResponse }
    }

    static func validCaseID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_-]{1,200}$", options: .regularExpression) != nil
    }

    static func validRepositoryURL(_ value: String) -> Bool {
        guard value.utf8.count <= 2_000, let url = URL(string: value),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil,
              url.password == nil, url.query == nil, url.fragment == nil,
              !url.path.split(separator: "/").isEmpty else { return false }
        return true
    }

    private struct RepositoryEnvelope: Decodable { let items: [CaseDevelopmentRepository] }

    private func decode<T: Decodable>(_ data: Data) throws -> T {
        guard data.count <= 8 * 1024 * 1024 else { throw CaseDevelopmentClientError.invalidResponse }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw CaseDevelopmentClientError.invalidResponse }
    }

    private func request(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
                         organizationID: String? = nil) async throws -> Data {
        guard path.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil,
              !path.contains(".."), organizationID.map({ $0.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil }) ?? true else {
            throw CaseDevelopmentClientError.invalidEndpoint
        }
        var items = query
        if let organizationID { items.append(URLQueryItem(name: "organizationId", value: organizationID)) }
        let base = settings.apiBaseURL.normalizedBaseURL.appendingAPIPath(path)
        guard var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else { throw CaseDevelopmentClientError.invalidEndpoint }
        components.queryItems = items.isEmpty ? nil : items
        components.fragment = nil
        guard let url = components.url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw CaseDevelopmentClientError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.userID, forHTTPHeaderField: "id")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let data: Data
        let response: URLResponse
        do { (data, response) = try await send(request) }
        catch { throw CaseDevelopmentClientError.transport }
        guard let http = response as? HTTPURLResponse, http.url == url else { throw CaseDevelopmentClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw CaseDevelopmentClientError.requestFailed(http.statusCode) }
        guard data.count <= 8 * 1024 * 1024 else { throw CaseDevelopmentClientError.invalidResponse }
        return data
    }
}

enum CaseDevelopmentClientError: LocalizedError, Equatable {
    case signInRequired, impersonationUnsupported, invalidEndpoint, invalidResponse, invalidInput, transport
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to manage case development links."
        case .impersonationUnsupported: "Return to your own account before managing repository integrations."
        case .invalidEndpoint: "Case development requires a secure Hanasand API address."
        case .invalidResponse: "The repository service returned data that could not be verified. Refresh and review before trying again."
        case .invalidInput: "Review the repository, commit, and case details."
        case .transport: "The request may have completed. Refresh and review repository links before retrying."
        case .requestFailed(401): "Sign in again to access repository links."
        case .requestFailed(403): "Your current organization role cannot manage this repository integration."
        case .requestFailed(let status): "The repository request failed (HTTP \(status))."
        }
    }
}

private final class CaseDevelopmentRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
