import Foundation

enum TrafficRecentClient {
    static let pageSize = 50
    static let autoRefreshIntervalSeconds: Double = 30

    static func shouldAutoRefresh(page: Int, isLoading: Bool) -> Bool {
        page == 1 && !isLoading
    }

    static func domainsURL(apiBaseURL: URL) throws -> URL {
        try endpoint(apiBaseURL: apiBaseURL, path: "traffic/domains")
    }

    static func metricsURL(apiBaseURL: URL, domain: String) throws -> URL {
        guard domain.count <= 253,
              !domain.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 127 }),
              !domain.contains(where: { "/?#\\".contains($0) }) else {
            throw TrafficRecentError.invalidResponse
        }
        var components = URLComponents(url: try endpoint(apiBaseURL: apiBaseURL, path: "traffic/metrics"), resolvingAgainstBaseURL: false)
        if !domain.isEmpty { components?.queryItems = [URLQueryItem(name: "domain", value: domain)] }
        guard let url = components?.url else { throw TrafficRecentError.invalidResponse }
        return url
    }

    static func recordsURL(apiBaseURL: URL, domain: String, page: Int, limit: Int = pageSize) throws -> URL {
        guard (1...200).contains(limit), page > 0, page <= Int.max / limit,
              domain.count <= 253,
              !domain.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 127 }),
              !domain.contains(where: { "/?#\\".contains($0) }) else {
            throw TrafficRecentError.invalidResponse
        }
        var components = URLComponents(url: try endpoint(apiBaseURL: apiBaseURL, path: "traffic/records"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: String(limit)), URLQueryItem(name: "page", value: String(page))]
        if !domain.isEmpty { components?.queryItems?.append(URLQueryItem(name: "domain", value: domain)) }
        guard let url = components?.url else { throw TrafficRecentError.invalidResponse }
        return url
    }

    static func request(url: URL, userID: String, authToken: String, impersonationToken: String = "", timeoutInterval: TimeInterval = 30) throws -> URLRequest {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !token.isEmpty else { throw TrafficRecentError.signIn }
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw TrafficRecentError.insecureEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: timeoutInterval)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(user, forHTTPHeaderField: "id")
        let impersonation = impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !impersonation.isEmpty { request.setValue(impersonation, forHTTPHeaderField: "x-impersonation-token") }
        return request
    }

    static func decodePage(_ data: Data) throws -> TrafficRecentPage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            let normalized = raw.replacingOccurrences(of: " ", with: "T", range: raw.range(of: " "))
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = iso.date(from: normalized) { return date }
            iso.formatOptions = [.withInternetDateTime]
            if let date = iso.date(from: normalized) { return date }
            throw TrafficRecentError.invalidResponse
        }
        let page = try decoder.decode(TrafficRecentPage.self, from: data)
        guard page.total >= 0, page.result.count <= pageSize,
              Set(page.result.map(\.id)).count == page.result.count,
              page.result.allSatisfy({
                  !$0.id.isEmpty && $0.id.count <= 30 && $0.id.allSatisfy(\.isNumber)
                  && $0.domain.count <= 253 && $0.path.count <= 4096
                  && $0.method.count <= 20 && $0.userAgent.count <= 2048
                  && $0.referer.count <= 4096 && $0.requestTime.isFinite && $0.requestTime >= 0
                  && (100...599).contains($0.status)
                  && ($0.countryISO == nil || $0.countryISO?.count == 2)
              }) else { throw TrafficRecentError.invalidResponse }
        return page
    }

    static func decodeDomains(_ data: Data) throws -> [String] {
        let decoded = try JSONDecoder().decode(TrafficRecentDomains.self, from: data)
        guard decoded.domains.count <= 50,
              decoded.domains.allSatisfy({ !$0.isEmpty && $0.count <= 253 && !$0.contains(where: { "/?#\\".contains($0) }) }) else {
            throw TrafficRecentError.invalidResponse
        }
        return Array(Set(decoded.domains)).sorted()
    }

    static func fetch(_ request: URLRequest) async throws -> Data {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: TrafficRecentRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              request.url?.scheme?.lowercased() == "https",
              response.url?.scheme?.lowercased() == "https",
              response.url?.host == request.url?.host else { throw TrafficRecentError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw TrafficRecentError.httpStatus(http.statusCode) }
        return data
    }

    private static func endpoint(apiBaseURL: URL, path: String) throws -> URL {
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil, apiBaseURL.user == nil,
              apiBaseURL.password == nil, apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw TrafficRecentError.insecureEndpoint
        }
        return apiBaseURL.appendingAPIPath(path)
    }
}

private final class TrafficRecentRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
