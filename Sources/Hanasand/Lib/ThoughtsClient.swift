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

    /// Looks for an exact-title match without changing saved content. The legacy
    /// endpoint returns matches from all workspaces, so only the configured scope
    /// is exposed to the caller.
    func findExactTitle(_ markdown: String) async throws -> [DashboardThought] {
        let content = try Self.validatedMarkdown(markdown)
        let body = try JSONEncoder().encode(ThoughtMutation(title: content))
        let request = makeRequest(url: apiBaseURL.appendingAPIPath("thought/title"), method: "POST", body: body)
        let data: Data
        let response: URLResponse
        do { (data, response) = try await send(request) }
        catch { throw ThoughtsClientError.lookupUnavailable }

        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == apiBaseURL.host else {
            throw ThoughtsClientError.invalidResponse
        }
        if http.statusCode == 404 { return [] }
        guard http.statusCode == 200 else { throw ThoughtsClientError.requestFailed(http.statusCode) }
        guard data.count <= 2_000_000 else { throw ThoughtsClientError.invalidResponse }
        let rows: [ThoughtLookupRow]
        do { rows = try JSONDecoder().decode([ThoughtLookupRow].self, from: data) }
        catch { throw ThoughtsClientError.invalidResponse }

        return rows.compactMap { row in
            guard row.organizationIDWasPresent,
                  row.organizationID == (organizationID.isEmpty ? nil : organizationID),
                  row.title == content else { return nil }
            return DashboardThought(id: row.id, title: row.title, createdAt: row.createdAt,
                                    createdBy: row.createdBy, updatedAt: row.updatedAt)
        }
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

    func delete(id: String) async throws {
        guard id.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            throw ThoughtsClientError.invalidRequest
        }
        let url = apiBaseURL.appendingAPIPath("thought/\(id)")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await send(makeRequest(url: url, method: "DELETE")) }
        catch { throw ThoughtsClientError.uncertainMutation }
        try validate(response, data: data, expectedStatus: 200)
        do {
            let receipt = try JSONDecoder().decode(ThoughtDeletionReceipt.self, from: data)
            guard receipt.deleted, receipt.id == id else { throw ThoughtsClientError.unconfirmedMutation }
        } catch let error as ThoughtsClientError { throw error }
        catch { throw ThoughtsClientError.unconfirmedMutation }
    }
}

private struct ThoughtMutation: Encodable {
    let title: String
}

private struct ThoughtUpdateReceipt: Decodable {
    struct Result: Decodable { let rows: [DashboardThought] }
    let result: Result
}

private struct ThoughtDeletionReceipt: Decodable {
    let deleted: Bool
    let id: String
}

enum ThoughtsClientError: LocalizedError, Equatable {
    case impersonationUnsupported
    case invalidRequest
    case invalidMarkdown
    case invalidResponse
    case lookupUnavailable
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
        case .lookupUnavailable: "Existing thoughts could not be checked. No thought was created."
        case .requestFailed(409): "A thought with this text already exists."
        case .requestFailed(401): "Sign in again to manage thoughts."
        case .requestFailed(403): "Your account cannot edit thoughts in this workspace."
        case .requestFailed(let status): "The Thoughts request failed (HTTP \(status))."
        case .uncertainMutation, .unconfirmedMutation: "The save could not be confirmed. Refresh Thoughts before trying again."
        }
    }
}

/// Small view-independent gate so the create action requires a current lookup
/// and an explicit review for the same draft and account/workspace context.
struct ThoughtCreateReviewGate: Equatable {
    private(set) var checkedMarkdown: String?
    private(set) var checkedScope: String?
    private(set) var reviewedMarkdown: String?
    private(set) var reviewedScope: String?

    mutating func recordLookup(markdown: String, scope: String) {
        checkedMarkdown = markdown
        checkedScope = scope
        reviewedMarkdown = nil
        reviewedScope = nil
    }

    mutating func beginReview(markdown: String, scope: String) -> Bool {
        guard hasCurrentLookup(markdown: markdown, scope: scope) else { return false }
        reviewedMarkdown = markdown
        reviewedScope = scope
        return true
    }

    func hasCurrentLookup(markdown: String, scope: String) -> Bool {
        checkedMarkdown == markdown && checkedScope == scope
    }

    func mayConfirm(markdown: String, scope: String) -> Bool {
        reviewedMarkdown == markdown && reviewedScope == scope &&
            checkedMarkdown == markdown && checkedScope == scope
    }

    mutating func cancelReview() {
        reviewedMarkdown = nil
        reviewedScope = nil
    }

    mutating func invalidate() {
        checkedMarkdown = nil
        checkedScope = nil
        cancelReview()
    }
}

private struct ThoughtLookupRow: Decodable {
    let id: String
    let title: String
    let createdAt: String?
    let createdBy: String?
    let updatedAt: String?
    let organizationID: String?
    let organizationIDWasPresent: Bool

    enum CodingKeys: String, CodingKey {
        case id, title
        case createdAt = "created_at"
        case createdBy = "created_by"
        case updatedAt = "updated_at"
        case organizationID = "organization_id"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        if let stringID = try? values.decode(String.self, forKey: .id) {
            id = stringID
        } else {
            id = String(try values.decode(Int64.self, forKey: .id))
        }
        title = try values.decode(String.self, forKey: .title)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        createdBy = try values.decodeIfPresent(String.self, forKey: .createdBy)
        updatedAt = try values.decodeIfPresent(String.self, forKey: .updatedAt)
        organizationIDWasPresent = values.contains(.organizationID)
        organizationID = try values.decodeIfPresent(String.self, forKey: .organizationID)
    }
}

struct ThoughtMutationSafety: Equatable {
    private(set) var requiresRefresh = false
    private(set) var isReviewReady = false
    private(set) var intent: ThoughtMutationIntent?
    private(set) var generation: UInt64 = 0

    var mayRetry: Bool { !requiresRefresh }
    var mayAcknowledgeReview: Bool { requiresRefresh && isReviewReady }

    mutating func recordFailure(_ error: Error, action: String = "update", id: String? = nil, markdown: String? = nil) {
        if (error as? ThoughtsClientError)?.isUncertain == true {
            generation &+= 1
            requiresRefresh = true
            isReviewReady = false
            intent = ThoughtMutationIntent(action: action, id: id, markdown: markdown)
        }
    }

    mutating func beginRefresh(userID: String, organizationID: String, loadID: UUID) -> ThoughtsRefreshTicket {
        if requiresRefresh { isReviewReady = false }
        return ThoughtsRefreshTicket(generation: generation, userID: userID, organizationID: organizationID, loadID: loadID)
    }

    func matchesCurrentRefresh(_ ticket: ThoughtsRefreshTicket, userID: String, organizationID: String,
                               loadID: UUID, isThoughtsPath: Bool) -> Bool {
        isThoughtsPath && !ticket.userID.isEmpty && ticket.generation == generation && ticket.userID == userID &&
            ticket.organizationID == organizationID && ticket.loadID == loadID
    }

    mutating func recordSuccessfulRefresh(_ ticket: ThoughtsRefreshTicket, userID: String,
                                         organizationID: String, loadID: UUID, isThoughtsPath: Bool) {
        guard matchesCurrentRefresh(ticket, userID: userID, organizationID: organizationID,
                                   loadID: loadID, isThoughtsPath: isThoughtsPath) else { return }
        isReviewReady = true
    }

    mutating func acknowledgeReviewedRefresh() {
        guard mayAcknowledgeReview else { return }
        requiresRefresh = false
        isReviewReady = false
        intent = nil
    }
}

struct ThoughtMutationIntent: Equatable {
    let action: String
    let id: String?
    let markdown: String?
}

struct ThoughtsRefreshTicket: Equatable {
    let generation: UInt64
    let userID: String
    let organizationID: String
    let loadID: UUID
}
