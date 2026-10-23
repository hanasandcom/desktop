import Foundation

enum IntegrationClientError: LocalizedError {
    case signInRequired
    case invalidAPIURL
    case invalidWorkspace
    case readOnly
    case invalidResponse
    case requestFailed(Int, String?)
    case uncertainResult
    case invalidDraft(String)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to manage integrations."
        case .invalidAPIURL: "Integrations require a valid HTTPS API address."
        case .invalidWorkspace: "Choose a valid workspace."
        case .readOnly: "This workspace is read-only. Refresh to review its permissions."
        case .invalidResponse: "The integrations service returned an invalid response."
        case let .requestFailed(status, message): message ?? "Integrations request failed (HTTP \(status))."
        case .uncertainResult: "The result could not be confirmed. Refresh and review before trying again."
        case let .invalidDraft(message): message
        }
    }
}

struct IntegrationClient {
    let apiBaseURL: URL
    let userID: String
    let token: String
    let organizationID: String
    let impersonationToken: String
    let impersonatingUserID: String
    var send: (URLRequest) async throws -> (Data, URLResponse)

    init(apiBaseURL: URL, userID: String, token: String, organizationID: String = "", impersonationToken: String = "", impersonatingUserID: String = "", send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !userID.isEmpty, !token.isEmpty else { throw IntegrationClientError.signInRequired }
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil, apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil,
              userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else { throw IntegrationClientError.invalidAPIURL }
        let scope = organizationID.isEmpty || organizationID == "personal" ? userID : organizationID
        guard Self.validID(scope) else { throw IntegrationClientError.invalidWorkspace }
        self.apiBaseURL = apiBaseURL
        self.userID = userID
        self.token = token
        self.organizationID = scope
        self.impersonationToken = impersonationToken
        self.impersonatingUserID = impersonatingUserID
        self.send = try send ?? Self.ephemeralSender()
    }

    var canMutate: Bool { impersonationToken.isEmpty && impersonatingUserID.isEmpty }

    func load() async throws -> IntegrationPage {
        let scope = try authorizedScope()
        async let pageResponse = request(path: "dwm/webhook-destinations", queryItems: [URLQueryItem(name: "orgId", value: scope)])
        async let organizationResponse: (Data, URLResponse)? = scope == userID ? nil : try? await request(path: "organizations/\(scope.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? scope)")
        let (data, response) = try await pageResponse
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode, data: data) }
        let page: IntegrationPage
        do {
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            page = try decoder.decode(IntegrationPage.self, from: data)
        } catch { throw IntegrationClientError.invalidResponse }
        guard page.destinations.allSatisfy({ $0.orgId == scope && Self.validID($0.id) }),
              page.destinationAdminProof.access?.canManage != nil else { throw IntegrationClientError.invalidResponse }
        if scope != userID {
            guard let (orgData, orgResponse) = await organizationResponse,
                  let orgHTTP = orgResponse as? HTTPURLResponse, (200..<300).contains(orgHTTP.statusCode),
                  let organization = Self.organizationState(from: orgData), organization.id == scope,
                  let lifecycle = organization.lifecycle, ["active", "archived", "deleted"].contains(lifecycle),
                  let deletion = organization.privacyDeletionInProgress else { throw IntegrationClientError.readOnly }
            guard lifecycle == "active", !deletion else { throw IntegrationClientError.readOnly }
        }
        return page
    }

    func save(page: IntegrationPage, draft: IntegrationDraft) async throws {
        try authorize(page: page, id: draft.id, action: .edit)
        try Self.validate(draft)
        let payload: [String: Any] = ["orgId": organizationID, "name": draft.name.trimmingCharacters(in: .whitespacesAndNewlines), "kind": draft.kind.rawValue,
                                      "endpointUrl": draft.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines), "status": "active"]
        var data = try JSONSerialization.data(withJSONObject: payload)
        if draft.id != nil && draft.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            data = try JSONSerialization.data(withJSONObject: ["orgId": organizationID, "name": draft.name.trimmingCharacters(in: .whitespacesAndNewlines), "kind": draft.kind.rawValue])
        }
        let path = "dwm/webhook-destinations" + (draft.id.map { "/\($0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0)" } ?? "")
        let (responseData, response) = try await request(path: path, method: draft.id == nil ? "POST" : "PUT", body: data)
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode, data: responseData, writing: true) }
        guard let destination = try? JSONDecoder().decode(DestinationEnvelope.self, from: responseData).destination,
              destination.orgId == organizationID, destination.id == draft.id ?? destination.id else { throw IntegrationClientError.uncertainResult }
    }

    func archive(page: IntegrationPage, destination: IntegrationDestination) async throws {
        try authorize(page: page, id: destination.id, action: .remove)
        let (data, response) = try await request(path: "dwm/webhook-destinations/\(destination.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? destination.id)", method: "DELETE")
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw failure(status: http.statusCode, data: data, writing: true) }
        guard let result = try? JSONDecoder().decode(DestinationEnvelope.self, from: data).destination,
              result.id == destination.id, result.orgId == organizationID, result.status == "archived" else { throw IntegrationClientError.uncertainResult }
    }

    func test(page: IntegrationPage, destination: IntegrationDestination) async throws -> (Bool, String) {
        try authorize(page: page, id: destination.id, action: .test)
        let body = try JSONSerialization.data(withJSONObject: ["dryRun": false, "live": true])
        let (data, response) = try await request(path: "dwm/webhook-destinations/\(destination.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? destination.id)/test", method: "POST", body: body)
        let http = try checked(response)
        guard let result = try? JSONDecoder().decode(DeliveryEnvelope.self, from: data).delivery,
              result.destinationId == destination.id, result.orgId == organizationID,
              ["delivered", "dry_run", "failed", "skipped"].contains(result.status),
              http.statusCode == 202 || http.statusCode == 502 else {
            if !(200..<300).contains(http.statusCode) && http.statusCode != 502 { throw failure(status: http.statusCode, data: data, writing: true) }
            throw IntegrationClientError.uncertainResult
        }
        let delivered = http.statusCode == 202 && result.status == "delivered" && !result.dryRun && result.error == nil
        if delivered { return (true, "Example message sent.") }
        if result.status == "dry_run" || result.dryRun { return (false, "Dry run recorded. No example message was sent.") }
        if result.status == "skipped" { return (false, "Test skipped. No example message was sent.") }
        return (false, "Test failed. Review the destination before trying again.")
    }

    private enum Action { case edit, remove, test }
    private func authorize(page: IntegrationPage, id: String?, action: Action) throws {
        guard canMutate, page.destinationAdminProof.access?.canManage == true else { throw IntegrationClientError.readOnly }
        if let id {
            guard let item = page.destinations.first(where: { $0.id == id && $0.orgId == organizationID }),
                  let access = page.destinationLifecycle.first(where: { $0.destinationId == id })?.access else { throw IntegrationClientError.readOnly }
            switch action {
            case .edit: guard access.canUpdate == true, item.status != "archived" else { throw IntegrationClientError.readOnly }
            case .remove: guard access.canDisable == true, item.status == "active" else { throw IntegrationClientError.readOnly }
            case .test:
                guard access.canTest == true, item.status == "active",
                      let test = page.destinationTests.first(where: { $0.destinationId == id }), test.access?.canTest == true,
                      !(test.blockers ?? []).contains(where: { $0.blocking == true }) else { throw IntegrationClientError.readOnly }
            }
        }
    }

    private func authorizedScope() throws -> String {
        guard Self.validID(organizationID) else { throw IntegrationClientError.invalidWorkspace }
        return organizationID
    }

    private func request(path: String, method: String = "GET", body: Data? = nil, queryItems: [URLQueryItem] = []) async throws -> (Data, URLResponse) {
        var url = apiBaseURL
        for component in path.split(separator: "/") where !component.isEmpty { url.appendPathComponent(String(component)) }
        if !queryItems.isEmpty, var components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            components.queryItems = queryItems
            guard let queried = components.url else { throw IntegrationClientError.invalidAPIURL }
            url = queried
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if !impersonationToken.isEmpty { request.setValue(impersonationToken, forHTTPHeaderField: "x-impersonation-token") }
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do { return try await send(request) }
        catch { if method == "GET" { throw IntegrationClientError.requestFailed(0, "Integrations are unavailable. Refresh to try again.") }; throw IntegrationClientError.uncertainResult }
    }

    private func checked(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let response = response as? HTTPURLResponse else { throw IntegrationClientError.invalidResponse }
        return response
    }

    private func failure(status: Int, data: Data, writing: Bool = false) -> IntegrationClientError {
        if writing && status >= 500 { return .uncertainResult }
        let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let raw = message?["error"] as? String
        let safe = raw?.replacingOccurrences(of: #"https?://[^\s\"'<>]+"#, with: "[destination URL]", options: .regularExpression).prefix(400)
        return .requestFailed(status, safe.map(String.init))
    }

    private static func validID(_ value: String) -> Bool {
        value.range(of: "^[A-Za-z0-9_.:@-]{1,200}$", options: .regularExpression) != nil && value != "." && value != ".."
    }

    private static func organizationState(from data: Data) -> (id: String, lifecycle: String?, privacyDeletionInProgress: Bool?)? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let organization = root["organization"] as? [String: Any],
              let id = organization["id"] as? String else { return nil }
        let lifecycle = organization["lifecycleStatus"] as? String
        let privacy: Bool?
        if let direct = organization["privacyDeletionInProgress"] {
            privacy = direct as? Bool
        } else if let settings = organization["settings"] as? [String: Any],
                  let metadata = settings["auditSafeMetadata"] as? [String: Any] {
            privacy = truthy(metadata["privacyDeletionRunId"])
        } else {
            privacy = nil
        }
        return (id, lifecycle, privacy)
    }

    private static func truthy(_ value: Any?) -> Bool {
        guard let value, !(value is NSNull) else { return false }
        if let boolean = value as? Bool { return boolean }
        if let number = value as? NSNumber { return number.doubleValue != 0 }
        if let string = value as? String { return !string.isEmpty }
        return true
    }

    static func validate(_ draft: IntegrationDraft) throws {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 120 else { throw IntegrationClientError.invalidDraft("Enter a name of 120 characters or fewer.") }
        let raw = draft.endpointURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if draft.id != nil && raw.isEmpty { return }
        guard raw.count <= 2048, let url = URLComponents(string: raw), url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil, url.fragment == nil else {
            throw IntegrationClientError.invalidDraft("Enter a valid HTTPS destination URL.")
        }
        if draft.kind == .discord {
            let host = (url.host ?? "").lowercased()
            guard ["discord.com", "discordapp.com"].contains(where: { host == $0 || host.hasSuffix(".\($0)") }),
                  url.path.range(of: #"^/api/webhooks/[^/]+/[^/]+"#, options: .regularExpression) != nil else {
                throw IntegrationClientError.invalidDraft("Enter a valid HTTPS Discord webhook URL.")
            }
        }
    }

    private struct DestinationEnvelope: Decodable { let destination: IntegrationDestination }
    private struct DeliveryEnvelope: Decodable { let delivery: IntegrationDelivery }
    private struct IntegrationDelivery: Decodable { let destinationId: String; let orgId: String; let status: String; let dryRun: Bool; let error: String? }

    private static func ephemeralSender() throws -> (URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
        return { request in try await session.data(for: request) }
    }
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
