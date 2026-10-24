import Foundation

enum NativeDatabaseClientError: LocalizedError {
    case signInRequired
    case invalidEndpoint
    case accessDenied
    case readOnly
    case invalidSelection
    case invalidResponse
    case requestFailed(Int)
    case uncertainOutcome

    var requiresSQLReviewBeforeRetry: Bool {
        switch self {
        case .uncertainOutcome, .accessDenied: true
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view database information."
        case .invalidEndpoint: "Use secure API addresses for database access."
        case .accessDenied: "Active Hanasand owner or editor access is required."
        case .readOnly: "Database statements require verified editing access on your own account."
        case .invalidSelection: "Choose a database or table from the current inventory."
        case .invalidResponse: "The database service returned an invalid response. Refresh to try again."
        case let .requestFailed(status): "Database request failed (HTTP \(status))."
        case .uncertainOutcome: "The statement outcome is unknown. Refresh the database and review its current state before another submission."
        }
    }
}

private final class NativeDatabaseRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct NativeDatabaseClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

    private let identityBaseURL: URL
    private let internalBaseURL: URL
    private let userID: String
    private let token: String
    private let impersonationToken: String
    private let isImpersonating: Bool
    private let send: Sender
    let scope: String

    init(settings: HanasandDesktopSettings, send: Sender? = nil) throws {
        let user = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !token.isEmpty else { throw NativeDatabaseClientError.signInRequired }
        guard let api = Self.validatedBase(settings.apiBaseURL),
              let internalAPI = Self.validatedBase(settings.internalAPIBaseURL),
              user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw NativeDatabaseClientError.invalidEndpoint
        }
        if api.host?.lowercased() == "api.hanasand.com" {
            var components = URLComponents(url: api, resolvingAgainstBaseURL: false)
            components?.host = "identity.hanasand.com"
            guard let identity = components?.url else { throw NativeDatabaseClientError.invalidEndpoint }
            identityBaseURL = identity
        } else {
            identityBaseURL = api
        }
        internalBaseURL = internalAPI
        userID = user
        self.token = token
        impersonationToken = settings.impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        isImpersonating = !settings.impersonationToken.isEmpty || !settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        scope = [api.absoluteString, identityBaseURL.absoluteString, internalAPI.absoluteString, user, token, impersonationToken,
                 settings.impersonatingUserID, settings.selectedOrganizationID].joined(separator: "\u{0}")
        if let send { self.send = send }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: NativeDatabaseRedirectBlocker(), delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    func loadAccess() async throws -> NativeDatabaseAccess {
        let data = try await request(base: identityBaseURL, path: "management/organizations?internalPages=1", method: "GET")
        guard let value = try? JSONDecoder().decode(DatabaseAccessResponse.self, from: data) else { throw NativeDatabaseClientError.invalidResponse }
        guard value.allowed else { throw NativeDatabaseClientError.accessDenied }
        return NativeDatabaseAccess(allowed: value.allowed, canEdit: value.canEdit, scope: scope)
    }

    func loadOverview(full: Bool = false) async throws -> NativeDatabaseOverview {
        let path = full ? "db" : "db?summary=1"
        let data = try await request(base: internalBaseURL, path: path, method: "GET")
        guard let overview = try? JSONDecoder().decode(NativeDatabaseOverview.self, from: data),
              !overview.generatedAt.isEmpty, !overview.health.message.isEmpty else { throw NativeDatabaseClientError.invalidResponse }
        return overview
    }

    func loadHealth() async throws -> NativeDatabaseHealth {
        let data = try await request(base: internalBaseURL, path: "db/health", method: "GET")
        guard let health = try? JSONDecoder().decode(NativeDatabaseHealth.self, from: data) else { throw NativeDatabaseClientError.invalidResponse }
        return health
    }

    func browse(_ overview: NativeDatabaseOverview, instanceID: String, databaseName: String, mode: String,
                schema: String? = nil, table: String? = nil, cursor: String? = nil,
                knownTableNames: Set<String> = []) async throws -> NativeDatabasePage {
        guard let storage = overview.storage, storage.stale != true,
              let instance = storage.instances.first(where: { $0.id == instanceID }),
              let database = instance.databases.first(where: { $0.name == databaseName }),
              ["contents", "rows", "count"].contains(mode) else { throw NativeDatabaseClientError.invalidSelection }
        if mode != "contents" {
            guard let table else { throw NativeDatabaseClientError.invalidSelection }
            if instance.engine.lowercased() == "redis" {
                guard knownTableNames.contains(table) else { throw NativeDatabaseClientError.invalidSelection }
            } else {
                guard database.tables?.contains(where: { $0.name == table && (schema == nil || $0.schema == schema) }) == true else {
                    throw NativeDatabaseClientError.invalidSelection
                }
            }
        }
        var items = [URLQueryItem(name: "instance", value: instance.id), URLQueryItem(name: "database", value: database.name), URLQueryItem(name: "mode", value: mode)]
        if let schema { items.append(URLQueryItem(name: "schema", value: schema)) }
        if let table { items.append(URLQueryItem(name: "table", value: table)) }
        if let cursor { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        let data = try await request(base: internalBaseURL, path: "db/browse", query: items, method: "GET")
        guard let page = try? JSONDecoder().decode(NativeDatabasePage.self, from: data),
              page.items != nil || page.rows != nil || page.totalRows != nil else { throw NativeDatabaseClientError.invalidResponse }
        return page
    }

    func loadCoreRows(access: NativeDatabaseAccess, table: NativeDatabaseOverview.Table, limit: Int = 50) async throws -> NativeDatabaseQueryResult {
        guard access.allowed, access.scope == scope else { throw NativeDatabaseClientError.accessDenied }
        guard Self.validIdentifier(table.schema), Self.validIdentifier(table.name), (1...500).contains(limit) else {
            throw NativeDatabaseClientError.invalidSelection
        }
        let data = try await request(base: internalBaseURL, path: "db/rows", query: [
            URLQueryItem(name: "schema", value: table.schema),
            URLQueryItem(name: "table", value: table.name),
            URLQueryItem(name: "limit", value: String(limit)),
        ], method: "GET")
        guard let result = try? JSONDecoder().decode(NativeDatabaseQueryResult.self, from: data) else { throw NativeDatabaseClientError.invalidResponse }
        return result
    }

    func runReviewedSQL(_ sql: String, access: NativeDatabaseAccess) async throws -> NativeDatabaseQueryResult {
        try requireWriter(access)
        let value = sql.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 65_536 else { throw NativeDatabaseClientError.invalidSelection }
        let body = try JSONSerialization.data(withJSONObject: ["sql": value])
        do {
            let data = try await request(base: internalBaseURL, path: "db/query", method: "POST", body: body)
            guard let result = try? JSONDecoder().decode(NativeDatabaseQueryResult.self, from: data) else { throw NativeDatabaseClientError.uncertainOutcome }
            return result
        } catch let error as NativeDatabaseClientError {
            switch error {
            case .accessDenied, .requestFailed, .invalidEndpoint, .readOnly, .invalidSelection, .signInRequired:
                throw error
            default:
                throw NativeDatabaseClientError.uncertainOutcome
            }
        } catch {
            throw NativeDatabaseClientError.uncertainOutcome
        }
    }

    private func requireWriter(_ access: NativeDatabaseAccess) throws {
        guard access.scope == scope, access.allowed, access.canEdit, !isImpersonating else { throw NativeDatabaseClientError.readOnly }
    }

    private func request(base: URL, path: String, query: [URLQueryItem] = [], method: String, body: Data? = nil) async throws -> Data {
        guard let url = Self.endpoint(base: base, path: path, query: query) else { throw NativeDatabaseClientError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: body == nil ? 25 : 1_800)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        request.setValue("hanasand_internal", forHTTPHeaderField: "User-Agent")
        if !impersonationToken.isEmpty { request.setValue(impersonationToken, forHTTPHeaderField: "x-impersonation-token") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response) = try await send(request)
        guard data.count <= 8 * 1024 * 1024,
              let http = response as? HTTPURLResponse,
              http.url?.scheme?.lowercased() == "https", http.url?.host?.lowercased() == base.host?.lowercased(),
              http.url?.port == base.port else { throw NativeDatabaseClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 || http.statusCode == 403 { throw NativeDatabaseClientError.accessDenied }
            if body != nil { throw NativeDatabaseClientError.uncertainOutcome }
            throw NativeDatabaseClientError.requestFailed(http.statusCode)
        }
        return data
    }

    private static func endpoint(base: URL, path: String, query: [URLQueryItem]) -> URL? {
        guard let valid = validatedBase(base) else { return nil }
        var components = URLComponents(url: valid, resolvingAgainstBaseURL: false)
        let prefix = components?.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let rawPath = path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
        let embeddedQuery = path.split(separator: "?", maxSplits: 1).dropFirst().first.map(String.init)
        components?.percentEncodedPath = "/" + [prefix, rawPath].filter { !$0.isEmpty }.joined(separator: "/")
        components?.percentEncodedQuery = embeddedQuery
        if !query.isEmpty { components?.queryItems = query }
        return components?.url
    }

    private static func validatedBase(_ value: String) -> URL? {
        guard let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    private static func validatedBase(_ url: URL) -> URL? {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil else { return nil }
        return url
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil
    }
}

private struct DatabaseAccessResponse: Decodable {
    let allowed: Bool
    let canEdit: Bool
}

struct NativeDatabaseHealth: Decodable {
    let ok: Bool
    let database: String?
    let checkedAt: String?
    let message: String?
    enum CodingKeys: String, CodingKey { case ok, database, checkedAt = "checked_at", message }
}
