import Foundation

struct ThreatIntelligenceOperationsClient {
    private let settings: HanasandDesktopSettings
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(
        settings: HanasandDesktopSettings,
        send: ((URLRequest) async throws -> (Data, URLResponse))? = nil
    ) throws {
        guard !settings.userID.isEmpty, !settings.authToken.isEmpty else {
            throw ThreatIntelligenceOperationsError.signInRequired
        }
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else {
            throw ThreatIntelligenceOperationsError.impersonationUnsupported
        }
        guard settings.userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
            settings.authToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil
        else {
            throw ThreatIntelligenceOperationsError.invalidCredentials
        }
        guard let configuredBase = URL(string: settings.websiteBaseURL), configuredBase.scheme?.lowercased() == "https",
            configuredBase.host != nil, configuredBase.user == nil, configuredBase.password == nil,
            configuredBase.query == nil, configuredBase.fragment == nil
        else {
            throw ThreatIntelligenceOperationsError.invalidBaseURL
        }
        self.settings = settings
        if let send {
            self.send = send
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: ThreatIntelligenceRedirectBlocker(), delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    func loadProfiles(query: String, page: Int) async throws -> ThreatIntelligenceOperationsPage {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...20_000).contains(page), clean.count <= 200 else {
            throw ThreatIntelligenceOperationsError.invalidRequest
        }
        var components = try components(path: "api/v1/actors")
        components.queryItems = [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "page", value: String(page))]
        if !clean.isEmpty { components.queryItems?.append(URLQueryItem(name: "q", value: clean)) }
        let envelope: ProfileEnvelope = try await get(components)
        let hasValidNextPage = envelope.pagination.nextPage.map { $0 > page } ?? true
        guard envelope.pagination.page == page, envelope.pagination.total >= 0,
            envelope.data.count <= 50, Set(envelope.data.map(\.id)).count == envelope.data.count,
            envelope.data.allSatisfy({ !$0.id.isEmpty }),
            hasValidNextPage
        else {
            throw ThreatIntelligenceOperationsError.invalidResponse
        }
        return ThreatIntelligenceOperationsPage(
            profiles: envelope.data, total: envelope.pagination.total,
            page: page, nextPage: envelope.pagination.nextPage)
    }

    func loadSources(query: String, page: Int) async throws -> ThreatIntelligenceSourcePage {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...20_000).contains(page), clean.count <= 200 else {
            throw ThreatIntelligenceOperationsError.invalidRequest
        }
        var components = try components(path: "api/v1/sources")
        components.queryItems = [URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "page", value: String(page))]
        if !clean.isEmpty { components.queryItems?.append(URLQueryItem(name: "q", value: clean)) }
        let envelope: SourceEnvelope = try await get(components)
        let hasValidNextPage = envelope.pagination.nextPage.map { $0 > page } ?? true
        guard envelope.pagination.page == page, envelope.pagination.total >= 0,
            envelope.data.count <= 50, Set(envelope.data.map(\.id)).count == envelope.data.count,
            envelope.data.allSatisfy({ !$0.id.isEmpty }),
            hasValidNextPage
        else {
            throw ThreatIntelligenceOperationsError.invalidResponse
        }
        return ThreatIntelligenceSourcePage(
            sources: envelope.data, total: envelope.pagination.total,
            page: page, nextPage: envelope.pagination.nextPage)
    }

    func loadTimeliness(status: String = "", query: String = "", cursor: String? = nil) async throws -> ThreatIntelligenceTimelinessSnapshot
    {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 200, status.count <= 40, (cursor?.count ?? 0) <= 200 else {
            throw ThreatIntelligenceOperationsError.invalidRequest
        }
        var components = try components(path: "api/ti/timeliness")
        var items = [URLQueryItem(name: "scope", value: "global"), URLQueryItem(name: "limit", value: "50")]
        if !status.isEmpty { items.append(URLQueryItem(name: "status", value: status)) }
        if !clean.isEmpty { items.append(URLQueryItem(name: "q", value: clean)) }
        if let cursor, !cursor.isEmpty { items.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = items
        let snapshot: ThreatIntelligenceTimelinessSnapshot = try await get(components)
        guard snapshot.items.count <= 50, snapshot.page.total >= snapshot.items.count,
            Set(snapshot.items.map(\.id)).count == snapshot.items.count,
            snapshot.items.allSatisfy({ !$0.id.isEmpty }),
            snapshot.page.nextCursor == nil || snapshot.page.nextCursor != cursor
        else {
            throw ThreatIntelligenceOperationsError.invalidResponse
        }
        return snapshot
    }

    private func get<T: Decodable>(_ components: URLComponents) async throws -> T {
        guard let url = components.url, url.scheme?.lowercased() == "https", url.host != nil,
            url.user == nil, url.password == nil
        else {
            throw ThreatIntelligenceOperationsError.invalidBaseURL
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.userID, forHTTPHeaderField: "id")

        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse, response.url == url else {
            throw ThreatIntelligenceOperationsError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ThreatIntelligenceOperationsError.requestFailed(response.statusCode)
        }
        guard data.count <= 2_000_000,
            response.expectedContentLength <= 0 || response.expectedContentLength <= 2_000_000
        else {
            throw ThreatIntelligenceOperationsError.responseTooLarge
        }
        do { return try JSONDecoder().decode(T.self, from: data) } catch { throw ThreatIntelligenceOperationsError.invalidResponse }
    }

    private func components(path: String) throws -> URLComponents {
        guard let configured = URL(string: settings.websiteBaseURL), let host = configured.host else {
            throw ThreatIntelligenceOperationsError.invalidBaseURL
        }
        let tiBase: URL
        if host.lowercased() == "hanasand.com" {
            tiBase = URL(string: "https://ti.hanasand.com")!
        } else {
            tiBase = configured
        }
        guard var components = URLComponents(url: tiBase, resolvingAgainstBaseURL: false) else {
            throw ThreatIntelligenceOperationsError.invalidBaseURL
        }
        components.percentEncodedPath = "/" + path
        components.queryItems = nil
        components.fragment = nil
        guard components.scheme?.lowercased() == "https", components.host != nil else {
            throw ThreatIntelligenceOperationsError.invalidBaseURL
        }
        return components
    }

    private struct ProfileEnvelope: Decodable {
        struct Pagination: Decodable {
            let page: Int
            let total: Int
            let nextPage: Int?
        }
        let data: [ThreatIntelligenceOperationsPage.Profile]
        let pagination: Pagination
    }

    private struct SourceEnvelope: Decodable {
        struct Pagination: Decodable {
            let page: Int
            let total: Int
            let nextPage: Int?
        }
        let data: [ThreatIntelligenceSourcePage.Source]
        let pagination: Pagination
    }
}

private final class ThreatIntelligenceRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

enum ThreatIntelligenceOperationsError: LocalizedError, Equatable {
    case signInRequired
    case invalidCredentials
    case impersonationUnsupported
    case invalidBaseURL
    case invalidRequest
    case invalidResponse
    case responseTooLarge
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to review intelligence operations."
        case .invalidCredentials: "The signed-in session cannot be verified."
        case .impersonationUnsupported: "Return to your own account to review intelligence operations."
        case .invalidBaseURL: "Intelligence operations require a secure website address."
        case .invalidRequest: "The requested intelligence page or filter is invalid."
        case .invalidResponse: "The intelligence response is invalid. Refresh to try again."
        case .responseTooLarge: "The intelligence response exceeded its size limit. Narrow the search and retry."
        case .requestFailed(401): "Your session could not be verified. Sign in again."
        case .requestFailed(403): "Your account cannot access this intelligence view."
        case .requestFailed: "The intelligence request failed. Refresh to try again."
        }
    }
}
