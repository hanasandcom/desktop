import Foundation

private final class AccountActivityRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum AccountActivityTransport {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: AccountActivityRedirectBlocker(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest, limit: Int) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await shared.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > limit {
            throw AccountActivityClientError.invalidResponse
        }
        var data = Data()
        data.reserveCapacity(min(limit, 64 * 1024))
        for try await byte in bytes {
            guard data.count < limit else { throw AccountActivityClientError.invalidResponse }
            data.append(byte)
        }
        return (data, response)
    }
}

enum AccountActivityClientError: LocalizedError, Equatable {
    case signInRequired
    case invalidBaseURL
    case impersonationUnsupported
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view account activity."
        case .invalidBaseURL: "Account activity requires a valid HTTPS API address."
        case .impersonationUnsupported: "Return to your own account to view account activity."
        case .invalidResponse: "The account activity service returned an invalid response."
        case let .requestFailed(status): "Account activity request failed (HTTP \(status))."
        }
    }
}

struct AccountActivityClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)
    static let responseByteLimit = 512 * 1024
    private let endpoint: URL
    private let userID: String
    private let token: String
    private let send: Sender

    init(apiBaseURL: URL, userID: String, token: String, impersonationToken: String = "",
         impersonatingUserID: String = "", send: Sender? = nil) throws {
        let cleanUserID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw AccountActivityClientError.impersonationUnsupported
        }
        guard !cleanUserID.isEmpty, !cleanToken.isEmpty else { throw AccountActivityClientError.signInRequired }
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil,
              cleanUserID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              cleanToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw AccountActivityClientError.invalidBaseURL
        }
        let escapedID = cleanUserID.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-._~"))) ?? ""
        let endpoint = apiBaseURL.appendingAPIPath("user/\(escapedID)/profile-stats")
        guard endpoint.scheme?.lowercased() == "https", endpoint.host == apiBaseURL.host,
              endpoint.user == nil, endpoint.password == nil else {
            throw AccountActivityClientError.invalidBaseURL
        }
        self.endpoint = endpoint
        self.userID = cleanUserID
        self.token = cleanToken
        self.send = send ?? { request in try await AccountActivityTransport.send(request, limit: Self.responseByteLimit) }
    }

    func load() async throws -> AccountActivityStats {
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == endpoint.host else {
            throw AccountActivityClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw AccountActivityClientError.requestFailed(http.statusCode) }
        guard data.count <= Self.responseByteLimit else { throw AccountActivityClientError.invalidResponse }
        do { return try JSONDecoder().decode(AccountActivityStats.self, from: data) }
        catch { throw AccountActivityClientError.invalidResponse }
    }
}
