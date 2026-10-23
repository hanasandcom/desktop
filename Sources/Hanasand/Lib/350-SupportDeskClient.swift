import Foundation

struct SupportDeskClient {
    static let defaultBaseURL = URL(string: "https://support.hanasand.com/api")!
    let baseURL: URL
    let siteBaseURL: URL
    let userID: String
    let token: String
    let organizationID: String
    let impersonationToken: String
    let impersonatingUserID: String
    var send: (URLRequest) async throws -> (Data, URLResponse)

    init(baseURL: URL = Self.defaultBaseURL, siteBaseURL: URL, userID: String, token: String,
         organizationID: String = "", impersonationToken: String = "", impersonatingUserID: String = "",
         send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let auth = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !auth.isEmpty else { throw SupportDeskClientError.signInRequired }
        guard Self.validBase(baseURL), Self.validBase(siteBaseURL),
              user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              auth.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw SupportDeskClientError.invalidServiceURL
        }
        self.baseURL = baseURL; self.siteBaseURL = siteBaseURL
        self.userID = user; self.token = auth; self.organizationID = organizationID
        self.impersonationToken = impersonationToken; self.impersonatingUserID = impersonatingUserID
        self.send = try send ?? Self.urlSessionSender()
    }

    var scope: String {
        [Self.normalized(baseURL), Self.normalized(siteBaseURL), userID, token, impersonationToken,
         impersonatingUserID, organizationID].joined(separator: "\n")
    }

    var canMutate: Bool { impersonationToken.isEmpty && impersonatingUserID.isEmpty }

    func load(filters: SupportDeskFilters) async throws -> SupportDeskSnapshot {
        let query = try Self.filterQuery(filters)
        let (data, response) = try await request(path: "support/tickets\(query)")
        return try decodeSnapshot(data, response: response)
    }

    func loadForCurrentUser(filters: SupportDeskFilters) async throws -> SupportDeskSnapshot {
        let snapshot: SupportDeskSnapshot
        do { snapshot = try await load(filters: filters) }
        catch SupportDeskClientError.requestFailed(403, _) { return try await loadOwnTickets() }
        return snapshot.isSupport ? snapshot : try await loadOwnTickets()
    }

    func loadOwnTickets() async throws -> SupportDeskSnapshot {
        let (data, response) = try await request(path: "support/my-tickets")
        let snapshot = try decodeSnapshot(data, response: response)
        guard !snapshot.isSupport,
              snapshot.tickets.allSatisfy({ $0.userID == userID }) else { throw SupportDeskClientError.invalidResponse }
        return snapshot
    }

    private func decodeSnapshot(_ data: Data, response: URLResponse) throws -> SupportDeskSnapshot {
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode, data: data) }
        let page: SupportDeskQueue
        do { page = try JSONDecoder().decode(SupportDeskQueue.self, from: data) }
        catch { throw SupportDeskClientError.invalidResponse }
        guard page.tickets.count <= 100, page.tickets.allSatisfy({ Self.validUUID($0.id) && !$0.subject.isEmpty && !$0.status.isEmpty && !$0.updatedAt.isEmpty }) else {
            throw SupportDeskClientError.invalidResponse
        }
        return SupportDeskSnapshot(scope: scope, isSupport: page.isSupport, realtime: page.realtime, tickets: page.tickets)
    }

    func createTicket(subject: String, message: String) async throws -> String {
        guard canMutate else { throw SupportDeskClientError.readOnly }
        let cleanSubject = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanMessage = message.trimmingCharacters(in: .whitespacesAndNewlines)
        guard cleanSubject.count <= 160, !cleanMessage.isEmpty, cleanMessage.count <= 10_000 else {
            throw SupportDeskClientError.invalidDraft("Enter a subject under 160 characters and a message under 10,000 characters.")
        }
        let payload = try Self.json(["subject": cleanSubject.isEmpty ? "Support question" : cleanSubject, "message": cleanMessage])
        let (data, response) = try await request(path: "support/tickets", method: "POST", body: payload, writing: true)
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode, data: data, writing: true) }
        guard let result = try? JSONDecoder().decode(SupportDeskCreateReceipt.self, from: data), Self.validUUID(result.id) else {
            throw SupportDeskClientError.uncertainResult
        }
        return result.id
    }

    func messages(ticketID: String) async throws -> [SupportDeskMessage] {
        let id = try Self.ticketComponent(ticketID)
        let (data, response) = try await request(path: "support/tickets/\(id)/messages")
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode, data: data) }
        let envelope: SupportDeskMessages
        do { envelope = try JSONDecoder().decode(SupportDeskMessages.self, from: data) }
        catch { throw SupportDeskClientError.invalidResponse }
        guard envelope.messages.allSatisfy({ Self.validUUID($0.id) && !$0.body.isEmpty && !$0.createdAt.isEmpty }) else { throw SupportDeskClientError.invalidResponse }
        return envelope.messages
    }

    func ownMessages(snapshot: SupportDeskSnapshot, ticket: SupportDeskTicket) async throws -> [SupportDeskMessage] {
        try authorizeOwn(snapshot: snapshot, ticket: ticket)
        return try await messages(ticketID: ticket.id)
    }

    @discardableResult
    func reply(snapshot: SupportDeskSnapshot, ticket: SupportDeskTicket, body: String, requestID: String) async throws -> String {
        if snapshot.isSupport { try authorize(snapshot: snapshot, ticket: ticket) }
        else { try authorizeOwn(snapshot: snapshot, ticket: ticket) }
        let message = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ticket.status != "closed", !message.isEmpty, message.count <= 10_000, Self.validUUID(requestID) else {
            throw SupportDeskClientError.invalidDraft("Reopen the conversation and enter a message under 10,000 characters.")
        }
        let id = try Self.ticketComponent(ticket.id)
        let payload = try Self.json(["message": message, "requestId": requestID])
        let (data, response) = try await request(path: "support/tickets/\(id)/messages", method: "POST", body: payload, writing: true)
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode, data: data, writing: true) }
        guard let result = try? JSONDecoder().decode(SupportDeskReplyReceipt.self, from: data), result.ok, Self.validUUID(result.messageId) else {
            throw SupportDeskClientError.uncertainResult
        }
        return result.messageId
    }

    func setStatus(snapshot: SupportDeskSnapshot, ticket: SupportDeskTicket, status: String) async throws {
        try authorize(snapshot: snapshot, ticket: ticket)
        guard snapshot.isSupport else { throw SupportDeskClientError.readOnly }
        guard status == "open" || status == "closed" else { throw SupportDeskClientError.invalidDraft("Choose an open or resolved conversation.") }
        let id = try Self.ticketComponent(ticket.id)
        let payload = try Self.json(["status": status])
        let (data, response) = try await request(path: "support/tickets/\(id)/status", method: "POST", body: payload, writing: true)
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode, data: data, writing: true) }
        guard let result = try? JSONDecoder().decode(SupportDeskStatusReceipt.self, from: data), result.ok,
              result.ticket.id == ticket.id, result.ticket.status == status else { throw SupportDeskClientError.uncertainResult }
    }

    func changeAccount(snapshot: SupportDeskSnapshot, ticket: SupportDeskTicket, field: SupportDeskAccountField, value: String) async throws {
        try authorize(snapshot: snapshot, ticket: ticket)
        guard snapshot.isSupport else { throw SupportDeskClientError.readOnly }
        guard let userID = ticket.userID, !userID.isEmpty, ticket.channel == "human" else { throw SupportDeskClientError.readOnly }
        try Self.validateAccountChange(field: field, value: value)
        let id = try Self.ticketComponent(ticket.id)
        let payload = try Self.json([field.rawValue: value])
        let method = field == .email ? "PUT" : "POST"
        let (data, response) = try await request(path: "support/tickets/\(id)/account/\(field.rawValue)", method: method, body: payload, writing: true)
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode, data: data, writing: true) }
        guard (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool == true else { throw SupportDeskClientError.uncertainResult }
    }

    func submitFeedback(snapshot: SupportDeskSnapshot, ticket: SupportDeskTicket, rating: Int, comment: String) async throws {
        try authorizeOwn(snapshot: snapshot, ticket: ticket)
        guard ticket.status == "closed", ticket.feedbackRating == nil,
              let resolutionVersion = ticket.resolutionVersion,
              (1...5).contains(rating), comment.count <= 2_000 else {
            throw SupportDeskClientError.invalidDraft("Choose 1–5 stars and keep feedback under 2,000 characters for a resolved conversation.")
        }
        let cleanComment = rating <= 3 ? comment.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let payload = try JSONSerialization.data(withJSONObject: ["rating": rating, "comment": cleanComment, "resolutionVersion": resolutionVersion])
        let id = try Self.ticketComponent(ticket.id)
        let (data, response) = try await request(path: "support/tickets/\(id)/feedback", method: "POST", body: payload, writing: true)
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode, data: data, writing: true) }
        guard (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool == true else { throw SupportDeskClientError.uncertainResult }
    }

    private func authorize(snapshot: SupportDeskSnapshot, ticket: SupportDeskTicket) throws {
        guard canMutate, snapshot.isSupport, snapshot.scope == scope,
              snapshot.tickets.contains(where: { $0 == ticket }) else { throw SupportDeskClientError.readOnly }
    }

    private func authorizeOwn(snapshot: SupportDeskSnapshot, ticket: SupportDeskTicket) throws {
        guard canMutate, !snapshot.isSupport, snapshot.scope == scope, ticket.userID == userID,
              snapshot.tickets.contains(where: { $0 == ticket }) else { throw SupportDeskClientError.readOnly }
    }

    private func request(path: String, method: String = "GET", body: Data? = nil, writing: Bool = false) async throws -> (Data, URLResponse) {
        let pieces = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        var url = baseURL
        for component in pieces[0].split(separator: "/") where !component.isEmpty { url.appendPathComponent(String(component)) }
        if pieces.count == 2, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.percentEncodedQuery = String(pieces[1])
            guard let queried = components.url else { throw SupportDeskClientError.invalidServiceURL }
            url = queried
        }
        guard url.scheme == "https", url.host == baseURL.host, url.user == nil, url.password == nil, url.fragment == nil else { throw SupportDeskClientError.invalidServiceURL }
        if Task.isCancelled { throw SupportDeskClientError.requestFailed(0, "Support request cancelled.") }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method; request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData; request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if !impersonationToken.isEmpty { request.setValue(impersonationToken, forHTTPHeaderField: "x-impersonation-token") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await send(request)
            if Task.isCancelled { throw writing ? SupportDeskClientError.uncertainResult : SupportDeskClientError.requestFailed(0, "Support request cancelled.") }
            guard response.url?.host == baseURL.host, response.url?.scheme == "https" else { throw SupportDeskClientError.invalidServiceURL }
            return (data, response)
        } catch let error as SupportDeskClientError { throw error }
        catch { throw writing ? SupportDeskClientError.uncertainResult : SupportDeskClientError.requestFailed(0, "Support is unavailable. Refresh to try again.") }
    }

    private func checked(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else { throw SupportDeskClientError.invalidResponse }
        return response
    }

    private func failure(status: Int, data _: Data, writing: Bool = false) -> SupportDeskClientError {
        if writing && status >= 500 { return .uncertainResult }
        if status == 401 { return .requestFailed(status, "Sign in again to use Support.") }
        if status == 403 { return .requestFailed(status, "Support access could not be verified. Refresh before changing this conversation.") }
        if status == 409 { return writing ? .uncertainResult : .requestFailed(status, "This conversation changed. Refresh and review it before trying again.") }
        return .requestFailed(status, "Support request failed (HTTP \(status)).")
    }

    static func filterQuery(_ filters: SupportDeskFilters) throws -> String {
        let search = filters.search.trimmingCharacters(in: .whitespacesAndNewlines)
        guard search.count <= 160, validDate(filters.from), validDate(filters.to),
              filters.from.isEmpty || filters.to.isEmpty || filters.from <= filters.to else {
            throw SupportDeskClientError.invalidDraft("Check the search and date filters.")
        }
        var items: [URLQueryItem] = []
        if !search.isEmpty { items.append(URLQueryItem(name: "search", value: search)) }
        if !filters.from.isEmpty { items.append(URLQueryItem(name: "from", value: filters.from)) }
        if !filters.to.isEmpty { items.append(URLQueryItem(name: "to", value: filters.to)) }
        if filters.stars != .all { items.append(URLQueryItem(name: "stars", value: filters.stars.rawValue)) }
        if filters.feedback != .all { items.append(URLQueryItem(name: "feedback", value: filters.feedback.rawValue)) }
        guard !items.isEmpty else { return "" }
        var components = URLComponents(); components.queryItems = items
        return "?\(components.percentEncodedQuery ?? "")"
    }

    static func validDate(_ value: String) -> Bool {
        guard !value.isEmpty else { return true }
        guard value.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil,
              let date = ISO8601DateFormatter().date(from: "\(value)T00:00:00Z") else { return false }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0) == value
    }

    static func validateAccountChange(field: SupportDeskAccountField, value: String) throws {
        if field == .password {
            guard value.count >= 16, value.count <= 1024 else { throw SupportDeskClientError.invalidDraft("Use a password of 16–1,024 characters.") }
        } else {
            guard value.count <= 254, value.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#, options: .regularExpression) != nil else {
                throw SupportDeskClientError.invalidDraft("Enter a valid email address.")
            }
        }
    }

    private static func ticketComponent(_ value: String) throws -> String {
        guard validUUID(value) else { throw SupportDeskClientError.invalidTicket }
        return value.lowercased()
    }
    private static func validUUID(_ value: String) -> Bool { UUID(uuidString: value) != nil }
    private static func validBase(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }
    private static func normalized(_ url: URL) -> String { url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
    private static func json(_ value: [String: String]) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private static func urlSessionSender() throws -> (URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let delegate = SupportDeskRedirectBlocker()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        return { request in try await session.data(for: request) }
    }
}

enum SupportDeskAccountField: String { case password, email }

private struct SupportDeskQueue: Decodable { let isSupport: Bool; let realtime: Bool; let tickets: [SupportDeskTicket] }
private struct SupportDeskCreateReceipt: Decodable { let id: String }
private struct SupportDeskMessages: Decodable { let messages: [SupportDeskMessage] }
private struct SupportDeskReplyReceipt: Decodable { let ok: Bool; let messageId: String }
private struct SupportDeskStatusReceipt: Decodable { let ok: Bool; let ticket: TicketStatus }
private struct TicketStatus: Decodable { let id: String; let status: String }

private final class SupportDeskRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
