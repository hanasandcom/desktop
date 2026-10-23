import Foundation

private final class LogErrorsRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum LogErrorsTransport {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: LogErrorsRedirectBlocker(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > limit {
            throw LogErrorsClientError.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in bytes {
            guard data.count < limit else { throw LogErrorsClientError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
}

struct LogErrorsClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)
    static let pageSize = 150
    static let responseBytes = 4 * 1024 * 1024

    private let apiBaseURL: URL
    private let userID: String
    private let token: String
    private let send: Sender

    init(apiBaseURL: URL, userID: String, token: String, impersonationToken: String = "",
         impersonatingUserID: String = "", send: Sender? = nil) throws {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LogErrorsClientError.impersonationUnsupported
        }
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw LogErrorsClientError.insecureEndpoint
        }
        guard !user.isEmpty, !credential.isEmpty else { throw LogErrorsClientError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw LogErrorsClientError.insecureEndpoint
        }
        self.apiBaseURL = apiBaseURL
        self.userID = user
        self.token = credential
        self.send = send ?? { request in try await LogErrorsTransport.send(request, limit: Self.responseBytes) }
    }

    func load(filters: LogErrorsFilters) async throws -> LogErrorsEnvelope {
        let url = try Self.requestURL(apiBaseURL: apiBaseURL, filters: filters)
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == apiBaseURL.host else {
            throw LogErrorsClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw LogErrorsClientError.requestFailed(http.statusCode) }
        guard data.count <= Self.responseBytes else { throw LogErrorsClientError.invalidResponse }
        let envelope: LogErrorsEnvelope
        do { envelope = try JSONDecoder().decode(LogErrorsEnvelope.self, from: data) }
        catch { throw LogErrorsClientError.invalidResponse }
        try envelope.validate()
        return envelope
    }

    static func requestURL(apiBaseURL: URL, filters: LogErrorsFilters) throws -> URL {
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw LogErrorsClientError.insecureEndpoint
        }
        let surface = filters.surface.trimmingCharacters(in: .whitespacesAndNewlines)
        let code = filters.errorCode.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = filters.query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard surface.utf8.count <= 120, code.utf8.count <= 120, query.utf8.count <= 120,
              ![surface, code, query].contains(where: { $0.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) }),
              filters.statusCode == nil || (400...599).contains(filters.statusCode!) else {
            throw LogErrorsClientError.invalidFilters
        }
        var components = URLComponents(url: apiBaseURL.appendingAPIPath("logs/errors"), resolvingAgainstBaseURL: false)
        var queryItems = [URLQueryItem(name: "limit", value: String(pageSize))]
        if !surface.isEmpty { queryItems.append(URLQueryItem(name: "surface", value: surface)) }
        if let statusCode = filters.statusCode { queryItems.append(URLQueryItem(name: "status", value: String(statusCode))) }
        if !code.isEmpty { queryItems.append(URLQueryItem(name: "code", value: code)) }
        if !query.isEmpty { queryItems.append(URLQueryItem(name: "q", value: query)) }
        if filters.includeExpected { queryItems.append(URLQueryItem(name: "includeExpected", value: "1")) }
        components?.queryItems = queryItems
        guard let url = components?.url, url.scheme?.lowercased() == "https", url.host == apiBaseURL.host else {
            throw LogErrorsClientError.insecureEndpoint
        }
        return url
    }
}

enum LogErrorsClientError: LocalizedError, Equatable {
    case signInRequired
    case impersonationUnsupported
    case insecureEndpoint
    case invalidFilters
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to review application errors."
        case .impersonationUnsupported: "Error history is available only in your own account."
        case .insecureEndpoint: "Error history requires a valid HTTPS API address."
        case .invalidFilters: "Choose valid error filters."
        case .invalidResponse: "The error service returned an invalid response."
        case .requestFailed(401): "Sign in again to review application errors."
        case .requestFailed(403): "Active Hanasand owner or editor access is required to review errors."
        case .requestFailed: "Error history is unavailable. Refresh to try again."
        }
    }
}
