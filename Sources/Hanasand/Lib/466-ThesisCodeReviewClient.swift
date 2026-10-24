import Foundation

private final class ThesisCodeReviewRedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let from = response.url, let to = request.url,
              from.scheme?.lowercased() == "https", to.scheme?.lowercased() == "https",
              from.host == to.host, Self.port(from) == Self.port(to) else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }

    private static func port(_ url: URL) -> Int { url.port ?? 443 }
}

struct ThesisCodeReviewClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)
    static let responseLimit = 8_000_000

    private let websiteBaseURL: URL
    private let origin: String
    private let userID: String
    private let token: String
    private let canMutate: Bool
    private let send: Sender

    init(settings: HanasandDesktopSettings, send: Sender? = nil) throws {
        let userID = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty, !token.isEmpty else { throw ThesisCodeReviewError.signInRequired }
        guard userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw ThesisCodeReviewError.invalidIdentity
        }
        guard let base = URL(string: settings.websiteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme?.lowercased() == "https", base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil, base.port == nil || base.port == 443 else {
            throw ThesisCodeReviewError.invalidEndpoint
        }
        websiteBaseURL = base
        origin = "https://\(base.host!)"
        self.userID = userID
        self.token = token
        canMutate = settings.impersonationToken.isEmpty && settings.impersonatingUserID.isEmpty
        if let send {
            self.send = send
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: ThesisCodeReviewRedirectGuard(), delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    static func endpoint(websiteBaseURL: String) throws -> URL {
        guard let base = URL(string: websiteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              base.scheme?.lowercased() == "https", base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil, base.port == nil || base.port == 443 else {
            throw ThesisCodeReviewError.invalidEndpoint
        }
        let endpoint = base.appendingAPIPath("api/thesis/code")
        guard endpoint.scheme?.lowercased() == "https", endpoint.host == base.host,
              endpoint.port == base.port else { throw ThesisCodeReviewError.invalidEndpoint }
        return endpoint
    }

    func inventory(since: String? = nil) async throws -> ThesisCodeInventory? {
        let query = since.map { [URLQueryItem(name: "since", value: $0)] } ?? []
        let (data, response) = try await request(query: query)
        let http = try checked(response)
        if http.statusCode == 204 { return nil }
        guard (200..<300).contains(http.statusCode) else { throw failure(http.statusCode, data: data) }
        do { return try JSONDecoder().decode(ThesisCodeInventory.self, from: data).validated() }
        catch let error as ThesisCodeReviewError { throw error }
        catch { throw ThesisCodeReviewError.invalidResponse }
    }

    func source(id: String, before: String? = nil) async throws -> ThesisCodeSource {
        guard !id.isEmpty, id.utf8.count <= 2_000,
              before.map({ UUID(uuidString: $0) != nil }) ?? true else { throw ThesisCodeReviewError.invalidInput }
        var query = [URLQueryItem(name: "id", value: id)]
        if let before { query.append(URLQueryItem(name: "before", value: before)) }
        let (data, response) = try await request(query: query)
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(http.statusCode, data: data) }
        do { return try JSONDecoder().decode(ThesisCodeSource.self, from: data).validated(expectedID: id) }
        catch let error as ThesisCodeReviewError { throw error }
        catch { throw ThesisCodeReviewError.invalidResponse }
    }

    func review(_ item: ThesisCodeNode, approved: Bool, eventID: String = UUID().uuidString.lowercased(), canReview: Bool) async throws -> ThesisCodeReviewEvent {
        guard canMutate, canReview else { throw ThesisCodeReviewError.readOnly }
        guard item.isValid, UUID(uuidString: eventID) != nil,
              eventID.range(of: "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$", options: .regularExpression) != nil else {
            throw ThesisCodeReviewError.invalidInput
        }
        let body = try JSONSerialization.data(withJSONObject: [
            "id": item.id,
            "sha256": item.sha256,
            "reviewHash": item.reviewHash,
            "approved": approved,
            "eventId": eventID,
        ], options: [.sortedKeys])
        let (data, response) = try await request(method: "POST", body: body)
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(http.statusCode, data: data) }
        do {
            let receipt = try JSONDecoder().decode(ThesisCodeReviewReceipt.self, from: data)
            return try receipt.validated(item: item, approved: approved, eventID: eventID).event
        } catch let error as ThesisCodeReviewError { throw error }
        catch { throw ThesisCodeReviewError.invalidResponse }
    }

    private func request(query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> (Data, URLResponse) {
        var url = try Self.endpoint(websiteBaseURL: websiteBaseURL.absoluteString)
        if !query.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = query
            guard let queried = components.url else { throw ThesisCodeReviewError.invalidEndpoint }
            url = queried
        }
        guard url.scheme?.lowercased() == "https", url.host == websiteBaseURL.host,
              (url.port ?? 443) == (websiteBaseURL.port ?? 443) else { throw ThesisCodeReviewError.invalidEndpoint }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(origin, forHTTPHeaderField: "Origin")
        }
        let (data, response) = try await send(request)
        guard data.count <= Self.responseLimit else { throw ThesisCodeReviewError.responseTooLarge }
        return (data, response)
    }

    private func checked(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse, let url = http.url,
              url.scheme?.lowercased() == "https", url.host == websiteBaseURL.host,
              (url.port ?? 443) == (websiteBaseURL.port ?? 443) else {
            throw ThesisCodeReviewError.invalidEndpoint
        }
        return http
    }

    private func failure(_ status: Int, data: Data) -> ThesisCodeReviewError {
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = object?["error"] as? String
        return .requestFailed(status, message)
    }
}
