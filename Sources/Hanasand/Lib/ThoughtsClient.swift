import Foundation

private final class ThoughtsRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct ThoughtsClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

    private let apiBaseURL: URL
    private let userID: String
    private let token: String
    private let organizationID: String
    private let send: Sender
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: ThoughtsRedirectBlocker(), delegateQueue: nil)
    }()

    init(apiBaseURL: URL, userID: String, token: String, organizationID: String = "",
         impersonationToken: String = "", impersonatingUserID: String = "", send: Sender? = nil) throws {
        guard impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ThoughtsClientError.impersonationUnsupported
        }
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw ThoughtsClientError.invalidRequest
        }
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil,
              organizationID.isEmpty || organizationID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            throw ThoughtsClientError.invalidRequest
        }
        self.apiBaseURL = apiBaseURL
        self.userID = user
        self.token = credential
        self.organizationID = organizationID
        self.send = send ?? { try await Self.session.data(for: $0) }
    }

    func load() async throws -> [DashboardThought] {
        let url = try Self.requestURL(apiBaseURL: apiBaseURL, organizationID: organizationID)
        let (data, response) = try await send(makeRequest(url: url, method: "GET"))
        try validate(response, data: data, expectedStatus: 200)
        do { return try JSONDecoder().decode([DashboardThought].self, from: data) }
        catch { throw ThoughtsClientError.invalidResponse }
    }

    func create(markdown: String) async throws -> DashboardThought {
        let content = try Self.validatedMarkdown(markdown)
        let data = try JSONEncoder().encode(ThoughtMutation(title: content))
        let (responseData, response): (Data, URLResponse)
        do { (responseData, response) = try await send(makeRequest(url: apiBaseURL.appendingAPIPath("thoughts"), method: "POST", body: data)) }
        catch { throw ThoughtsClientError.uncertainMutation }
        try validate(response, data: responseData, expectedStatus: 201)
        do {
            let receipt = try JSONDecoder().decode(DashboardThought.self, from: responseData)
            guard receipt.title == content else { throw ThoughtsClientError.unconfirmedMutation }
            return receipt
        } catch let error as ThoughtsClientError { throw error }
        catch { throw ThoughtsClientError.unconfirmedMutation }
    }

    func update(id: String, markdown: String) async throws -> DashboardThought {
        guard id.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else { throw ThoughtsClientError.invalidRequest }
        let content = try Self.validatedMarkdown(markdown)
        let data = try JSONEncoder().encode(ThoughtMutation(title: content))
        let (responseData, response): (Data, URLResponse)
        do { (responseData, response) = try await send(makeRequest(url: apiBaseURL.appendingAPIPath("thought/\(id)"), method: "PUT", body: data)) }
        catch { throw ThoughtsClientError.uncertainMutation }
        try validate(response, data: responseData, expectedStatus: 201)
        do {
            let receipt = try JSONDecoder().decode(ThoughtUpdateReceipt.self, from: responseData)
            guard let row = receipt.result.rows.first(where: { $0.id == id }), row.title == content else {
                throw ThoughtsClientError.unconfirmedMutation
            }
            return row
        } catch let error as ThoughtsClientError { throw error }
        catch { throw ThoughtsClientError.unconfirmedMutation }
    }

    static func requestURL(apiBaseURL: URL, organizationID: String) throws -> URL {
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil,
              organizationID.isEmpty || organizationID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            throw ThoughtsClientError.invalidRequest
        }
        var components = URLComponents(url: apiBaseURL.appendingAPIPath("thoughts"), resolvingAgainstBaseURL: false)
        components?.queryItems = organizationID.isEmpty
            ? [URLQueryItem(name: "workspace", value: "true")]
            : [URLQueryItem(name: "organizationId", value: organizationID)]
        guard let url = components?.url, url.host == apiBaseURL.host else { throw ThoughtsClientError.invalidRequest }
        return url
    }

    private static func validatedMarkdown(_ markdown: String) throws -> String {
        guard !markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              markdown.utf8.count <= 100_000,
              !markdown.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && $0 != "\n" && $0 != "\r" && $0 != "\t" }) else {
            throw ThoughtsClientError.invalidMarkdown
        }
        return markdown
    }

    private func makeRequest(url: URL, method: String, body: Data? = nil) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if !organizationID.isEmpty {
            request.setValue(organizationID, forHTTPHeaderField: "x-organization-id")
        }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return request
    }

    private func validate(_ response: URLResponse, data: Data, expectedStatus: Int) throws {
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == apiBaseURL.host else {
            throw ThoughtsClientError.uncertainMutation
        }
        guard http.statusCode == expectedStatus else { throw ThoughtsClientError.requestFailed(http.statusCode) }
        guard data.count <= 2_000_000 else {
            throw expectedStatus == 200 ? ThoughtsClientError.invalidResponse : ThoughtsClientError.unconfirmedMutation
        }
    }
}

private struct ThoughtMutation: Encodable {
    let title: String
}

private struct ThoughtUpdateReceipt: Decodable {
    struct Result: Decodable { let rows: [DashboardThought] }
    let result: Result
}

enum ThoughtsClientError: LocalizedError, Equatable {
    case impersonationUnsupported
    case invalidRequest
    case invalidMarkdown
    case invalidResponse
    case requestFailed(Int)
    case uncertainMutation
    case unconfirmedMutation

    var isUncertain: Bool {
        switch self {
        case .uncertainMutation, .unconfirmedMutation: true
        case .requestFailed(let status): status >= 500
        default: false
        }
    }

    var errorDescription: String? {
        switch self {
        case .impersonationUnsupported: "Thoughts are unavailable while impersonating another account."
        case .invalidRequest: "The Thoughts request is invalid."
        case .invalidMarkdown: "Write some Markdown before saving."
        case .invalidResponse: "The Thoughts service returned an invalid response."
        case .requestFailed(409): "A thought with this text already exists."
        case .requestFailed(401): "Sign in again to manage thoughts."
        case .requestFailed(403): "Your account cannot edit thoughts in this workspace."
        case .requestFailed(let status): "The Thoughts request failed (HTTP \(status))."
        case .uncertainMutation, .unconfirmedMutation: "The save could not be confirmed. Refresh Thoughts before trying again."
        }
    }
}

struct ThoughtMutationSafety: Equatable {
    private(set) var requiresRefresh = false
    static let ready = ThoughtMutationSafety()

    var mayRetry: Bool { !requiresRefresh }

    mutating func recordFailure(_ error: Error) {
        if (error as? ThoughtsClientError)?.isUncertain == true { requiresRefresh = true }
    }
}
