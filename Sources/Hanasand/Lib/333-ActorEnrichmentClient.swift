import Foundation

struct ActorEnrichmentClient {
    private let settings: HanasandDesktopSettings
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(settings: HanasandDesktopSettings, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        guard !settings.userID.isEmpty, !settings.authToken.isEmpty,
            settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty,
            settings.userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
            settings.authToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil
        else { throw ThreatIntelligenceOperationsError.invalidCredentials }
        guard let base = URL(string: settings.websiteBaseURL), base.scheme?.lowercased() == "https",
            base.host != nil, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil
        else { throw ThreatIntelligenceOperationsError.invalidBaseURL }
        self.settings = settings
        if let send { self.send = send }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.httpShouldSetCookies = false
            config.httpCookieStorage = nil
            config.urlCache = nil
            config.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: config, delegate: ActorEnrichmentRedirectBlocker(), delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    func loadOverview(query: String = "") async throws -> ActorEnrichmentOverview {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 100 else { throw ThreatIntelligenceOperationsError.invalidRequest }
        var url = try endpoint("v1/intel/actor-enrichment/overview")
        url.queryItems = [URLQueryItem(name: "tenantId", value: "default")]
        if !clean.isEmpty { url.queryItems?.append(URLQueryItem(name: "q", value: clean)) }
        return try await get(url)
    }

    func loadRuns(cursor: String? = nil, limit: Int = 20) async throws -> ActorEnrichmentRunPage {
        guard (1...100).contains(limit), cursor.map({ $0.count <= 500 }) ?? true else {
            throw ThreatIntelligenceOperationsError.invalidRequest
        }
        var url = try endpoint("v1/intel/actor-enrichment/status")
        url.queryItems = [URLQueryItem(name: "limit", value: String(limit))]
        if let cursor, !cursor.isEmpty { url.queryItems?.append(URLQueryItem(name: "cursor", value: cursor)) }
        return try await get(url)
    }

    /// Requests one explicit enrichment pass for the default tenant. The service validates authorization.
    func queueRun() async throws {
        guard let url = try endpoint("v1/intel/actor-enrichment/runs").url else {
            throw ThreatIntelligenceOperationsError.invalidBaseURL
        }
        var request = authenticatedRequest(url, method: "POST")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["tenantId": "default"])
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse, response.url == url else {
            throw ThreatIntelligenceOperationsError.mutationOutcomeUnknown
        }
        guard response.statusCode == 202 else {
            if (200..<300).contains(response.statusCode) { throw ThreatIntelligenceOperationsError.invalidResponse }
            throw ThreatIntelligenceOperationsError.requestFailed(response.statusCode)
        }
        guard data.count <= 64_000,
            let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            body["accepted"] as? Bool == true, body["status"] as? String == "queued"
        else { throw ThreatIntelligenceOperationsError.mutationOutcomeUnknown }
    }

    private func get<T: Decodable>(_ components: URLComponents) async throws -> T {
        guard let url = components.url else { throw ThreatIntelligenceOperationsError.invalidBaseURL }
        var request = authenticatedRequest(url, method: "GET")
        request.timeoutInterval = 20
        let (data, response) = try await send(request)
        guard let response = response as? HTTPURLResponse, response.url == url else {
            throw ThreatIntelligenceOperationsError.invalidResponse
        }
        guard (200..<300).contains(response.statusCode) else {
            throw ThreatIntelligenceOperationsError.requestFailed(response.statusCode)
        }
        guard data.count <= 2_000_000,
            response.expectedContentLength <= 0 || response.expectedContentLength <= 2_000_000
        else { throw ThreatIntelligenceOperationsError.responseTooLarge }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ThreatIntelligenceOperationsError.invalidResponse }
    }

    private func authenticatedRequest(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.userID, forHTTPHeaderField: "id")
        return request
    }

    private func endpoint(_ path: String) throws -> URLComponents {
        guard let base = URL(string: settings.websiteBaseURL), let host = base.host else {
            throw ThreatIntelligenceOperationsError.invalidBaseURL
        }
        let root = host.lowercased() == "hanasand.com" ? URL(string: "https://ti.hanasand.com")! : base
        guard var parts = URLComponents(url: root, resolvingAgainstBaseURL: false) else {
            throw ThreatIntelligenceOperationsError.invalidBaseURL
        }
        parts.percentEncodedPath = "/" + path
        parts.queryItems = nil
        parts.fragment = nil
        return parts
    }
}

private final class ActorEnrichmentRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
