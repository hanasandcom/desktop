import Foundation

private final class NativeTIDarkwebRedirectBlocker: NSObject, URLSessionTaskDelegate {
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

private enum NativeTIDarkwebSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: NativeTIDarkwebRedirectBlocker(), delegateQueue: nil)
    }()
}

struct NativeTIDarkwebIndexClient {
    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum ClientError: LocalizedError, Equatable {
        case invalidEndpoint
        case invalidRequest
        case invalidResponse
        case responseTooLarge
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint: return "The dark web index endpoint is invalid."
            case .invalidRequest: return "One or more dark web index filters are too long."
            case .invalidResponse: return "The dark web index returned an invalid response."
            case .responseTooLarge: return "The dark web index response is larger than expected."
            case .httpStatus(let status): return "The dark web index returned HTTP \(status)."
            }
        }
    }

    private let websiteBaseURL: String
    private let send: Sender

    init(websiteBaseURL: String, send: @escaping Sender = { request in
        try await NativeTIDarkwebSession.shared.data(for: request)
    }) {
        self.websiteBaseURL = websiteBaseURL
        self.send = send
    }

    init(settings: HanasandDesktopSettings, send: @escaping Sender = { request in
        try await NativeTIDarkwebSession.shared.data(for: request)
    }) {
        self.init(websiteBaseURL: settings.websiteBaseURL, send: send)
    }

    func loadStatus() async throws -> NativeTIDarkwebStatusResponse {
        try await get("api/ti/darkweb/status")
    }

    func search(filters: NativeTIDarkwebFilters, limit: Int = 50) async throws -> NativeTIDarkwebSearchResponse {
        let values = [filters.query, filters.category, filters.legalTriage, filters.network, filters.reviewState]
        guard values.allSatisfy({ $0.trimmingCharacters(in: .whitespacesAndNewlines).count <= 256 }),
              (1...100).contains(limit) else { throw ClientError.invalidRequest }
        return try await get("api/ti/darkweb/search", queryItems: filters.queryItems(limit: limit))
    }

    private func get<T: Decodable>(_ path: String, queryItems: [URLQueryItem] = []) async throws -> T {
        guard let base = URL(string: websiteBaseURL), base.scheme?.lowercased() == "https",
              let host = base.host, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil,
              var components = URLComponents(url: base, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidEndpoint
        }
        components.percentEncodedPath = "/" + path
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        components.fragment = nil
        guard let url = components.url, url.scheme?.lowercased() == "https", url.host?.lowercased() == host.lowercased(),
              url.path == "/\(path)" else { throw ClientError.invalidEndpoint }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await send(request)
        guard data.count <= 4 * 1024 * 1024,
              let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https",
              response.url?.host?.lowercased() == host.lowercased(), response.url?.path == url.path else {
            if data.count > 4 * 1024 * 1024 { throw ClientError.responseTooLarge }
            throw ClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.httpStatus(http.statusCode) }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw ClientError.invalidResponse }
    }
}
