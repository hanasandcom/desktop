import Foundation

private final class ThesisRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = response.url, let to = request.url,
              to.scheme?.lowercased() == "https", to.host == from.host, to.port == from.port else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

struct ThesisClient {
    private let baseURL: URL
    private let userID: String
    private let token: String
    private let canMutate: Bool
    private var send: (URLRequest) async throws -> (Data, URLResponse)

    init(settings: HanasandDesktopSettings, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let userID = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty, !token.isEmpty else { throw ThesisClientError.signInRequired }
        guard userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw ThesisClientError.invalidIdentity
        }
        guard let url = URL(string: settings.apiBaseURL), url.scheme?.lowercased() == "https",
              url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw ThesisClientError.invalidBaseURL
        }
        self.baseURL = settings.apiBaseURL.normalizedBaseURL
        self.userID = userID
        self.token = token
        self.canMutate = settings.impersonationToken.isEmpty && settings.impersonatingUserID.isEmpty
        if let send { self.send = send }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let delegate = ThesisRedirectGuard()
            let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    func loadAccess() async throws -> ThesisAccess {
        let (data, response) = try await request(path: "thesis/access")
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(http.statusCode, data: data) }
        do {
            let access = try JSONDecoder().decode(ThesisAccess.self, from: data)
            guard access.member else { throw ThesisClientError.requestFailed(403, "Hanasand organization membership is required.") }
            return access
        } catch let error as ThesisClientError { throw error }
        catch { throw ThesisClientError.invalidResponse }
    }

    func load() async throws -> ThesisDocument {
        let (data, response) = try await request(path: "thesis")
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(http.statusCode, data: data) }
        return try decodeDocument(data)
    }

    func save(_ document: ThesisDocument, access: ThesisAccess) async throws -> ThesisDocument {
        guard canMutate, access.member, access.canEdit else { throw ThesisClientError.readOnly }
        let value = try document.validated()
        let body = try JSONEncoder().encode(value)
        let (data, response) = try await request(path: "thesis", method: "PUT", body: body)
        let http = try checked(response)
        guard http.statusCode != 409 else { throw ThesisClientError.conflict(try decodeDocument(data)) }
        guard (200..<300).contains(http.statusCode) else { throw failure(http.statusCode, data: data) }
        let saved = try decodeDocument(data)
        guard saved.title == value.title, saved.body == value.body, saved.revision >= value.revision else { throw ThesisClientError.invalidResponse }
        return saved
    }

    func history(before revision: Int? = nil) async throws -> [ThesisHistoryEntry] {
        if let revision, revision < 0 { throw ThesisClientError.invalidResponse }
        var path = "thesis/history"
        if let revision { path += "?before=\(revision)" }
        let (data, response) = try await request(path: path)
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(http.statusCode, data: data) }
        guard let items = try? JSONDecoder().decode([ThesisHistoryEntry].self, from: data), items.count <= 50,
              Set(items.map(\.revision)).count == items.count,
              items.allSatisfy({ $0.revision >= 0 && !$0.title.isEmpty && Self.validTimestamp($0.savedAt) }) else {
            throw ThesisClientError.invalidResponse
        }
        return items
    }

    func version(_ revision: Int) async throws -> ThesisDocument {
        guard revision >= 0 else { throw ThesisClientError.invalidResponse }
        let (data, response) = try await request(path: "thesis/history/\(revision)")
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(http.statusCode, data: data) }
        let document = try decodeDocument(data)
        guard document.revision == revision else { throw ThesisClientError.invalidResponse }
        return document
    }

    private func request(path: String, method: String = "GET", body: Data? = nil) async throws -> (Data, URLResponse) {
        let pieces = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard let route = pieces.first, !route.isEmpty else { throw ThesisClientError.invalidBaseURL }
        var url = baseURL.appendingAPIPath(String(route))
        if pieces.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = String(pieces[1])
            guard let queriedURL = components.url else { throw ThesisClientError.invalidBaseURL }
            url = queriedURL
        }
        guard url.scheme == "https", url.host == baseURL.host, url.port == baseURL.port else { throw ThesisClientError.invalidBaseURL }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        return try await send(request)
    }

    private func checked(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw ThesisClientError.invalidResponse }
        return http
    }

    private func decodeDocument(_ data: Data) throws -> ThesisDocument {
        guard data.count <= ThesisDocument.bodyLimit * 4 + 8192 else { throw ThesisClientError.invalidResponse }
        do { return try JSONDecoder().decode(ThesisDocument.self, from: data).validated() }
        catch { throw ThesisClientError.invalidResponse }
    }

    private func failure(_ status: Int, data: Data) -> ThesisClientError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = object?["error"] as? String
        return .requestFailed(status, message)
    }

    private static func validTimestamp(_ value: String) -> Bool {
        let formatter = ISO8601DateFormatter()
        if formatter.date(from: value) != nil { return true }
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) != nil
    }
}
