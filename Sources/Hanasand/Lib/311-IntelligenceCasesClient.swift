import Foundation

struct IntelligenceCasesClient {
    private let settings: HanasandDesktopSettings
    private let organizationIDOverride: String?
    private let send: (URLRequest) async throws -> (Data, URLResponse)
    private static let responseLimit = 8 * 1024 * 1024

    init(settings: HanasandDesktopSettings, organizationIDOverride: String? = nil,
         send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        guard !settings.userID.isEmpty, !settings.authToken.isEmpty else { throw IntelligenceCasesError.signInRequired }
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else { throw IntelligenceCasesError.impersonationUnsupported }
        guard settings.userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              settings.authToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw IntelligenceCasesError.signInRequired
        }
        guard let base = URL(string: settings.websiteBaseURL), base.scheme?.lowercased() == "https", base.host != nil,
              base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
            throw IntelligenceCasesError.invalidURL
        }
        self.settings = settings
        if let organizationIDOverride {
            guard organizationIDOverride.range(of: "^[A-Za-z0-9._:-]{1,128}$", options: .regularExpression) != nil else {
                throw IntelligenceCasesError.invalidResponse
            }
        }
        self.organizationIDOverride = organizationIDOverride
        if let send { self.send = send }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: IntelligenceCasesRedirectBlocker(), delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    var organizationID: String? {
        if let organizationIDOverride { return organizationIDOverride }
        let value = settings.selectedOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "personal" ? nil : value
    }

    func load(cursor: String? = nil) async throws -> IntelligenceCasePage {
        guard (cursor?.count ?? 0) <= 500 else { throw IntelligenceCasesError.invalidResponse }
        var components = try components(path: "/v1/cases")
        var query = [URLQueryItem(name: "tenantId", value: organizationID ?? settings.userID)]
        if let organizationID { query.append(URLQueryItem(name: "organizationId", value: organizationID)) }
        if let cursor, !cursor.isEmpty { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        else { query.append(URLQueryItem(name: "page", value: "1")) }
        components.queryItems = query
        let (data, response) = try await request(components, method: "GET")
        let page: IntelligenceCasePage
        do { page = try JSONDecoder().decode(IntelligenceCasePage.self, from: data) }
        catch { throw IntelligenceCasesError.invalidResponse }
        guard page.items.count <= 100,
              Set(page.items.map(\.id)).count == page.items.count,
              page.items.allSatisfy({ organizationID == nil || $0.organizationID.isEmpty || $0.organizationID == organizationID }),
              page.total.map({ $0 >= page.items.count }) ?? true,
              page.nextCursor == nil || page.nextCursor != cursor,
              response.statusCode == 200 else { throw IntelligenceCasesError.invalidResponse }
        return page
    }

    func detail(caseID: String) async throws -> IntelligenceCaseDetailEnvelope {
        guard Self.validCaseID(caseID) else { throw IntelligenceCasesError.invalidResponse }
        var components = try components(path: "/v1/cases/\(caseID.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")")
        components.queryItems = scopeQuery(alertID: nil)
        let (data, _) = try await request(components, method: "GET")
        let detail: IntelligenceCaseDetailEnvelope
        do { detail = try JSONDecoder().decode(IntelligenceCaseDetailEnvelope.self, from: data) }
        catch { throw IntelligenceCasesError.invalidResponse }
        guard detail.caseRecord.id == caseID,
              organizationID == nil || detail.caseRecord.organizationID.isEmpty || detail.caseRecord.organizationID == organizationID,
              detail.timeline.count <= 10_000, detail.evidence.count <= 10_000,
              Set(detail.actions.map(\.id)).count == detail.actions.count else { throw IntelligenceCasesError.invalidResponse }
        return detail
    }

    func perform(_ action: IntelligenceCaseAction, caseRecord: IntelligenceCaseRow, alertID: String?, note: String, assignedOwner: String,
                 currentSettings: HanasandDesktopSettings) async throws {
        guard currentSettings == settings else { throw IntelligenceCasesError.scopeChanged }
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty,
              action.enabled, action.method.uppercased() == "PATCH", Self.validCaseID(caseRecord.id),
              note.utf8.count <= 5000, assignedOwner.utf8.count <= 320,
              !action.requiresRationale || !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IntelligenceCasesError.scopeChanged
        }
        var components = try components(path: "/v1/cases/\(caseRecord.id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "")")
        components.queryItems = scopeQuery(alertID: alertID ?? caseRecord.raw["alertId"]?.stringValue)
        var body: [String: Any] = [
            "tenantId": organizationID ?? settings.userID,
            "action": action.id,
            "actor": "desktop",
            "note": note.trimmingCharacters(in: .whitespacesAndNewlines),
            "idempotencyKey": "desktop-case:\(caseRecord.id):\(action.id):\(caseRecord.updatedAt.isEmpty ? caseRecord.createdAt : caseRecord.updatedAt):\(UUID().uuidString.lowercased())",
        ]
        if let organizationID { body["organizationId"] = organizationID }
        if !assignedOwner.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { body["assignedOwner"] = assignedOwner.trimmingCharacters(in: .whitespacesAndNewlines) }
        if action.id == "confirm_resolution", let resolutionID = caseRecord.raw["resolution"]?["id"]?.stringValue { body["confirmResolutionId"] = resolutionID }
        let data = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let (responseData, response) = try await request(components, method: "PATCH", body: data, uncertainOnFailure: true)
        guard (200..<300).contains(response.statusCode),
              let object = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
              let updated = object["case"] as? [String: Any], updated["id"] as? String == caseRecord.id else {
            throw IntelligenceCasesError.mutationOutcomeUnknown
        }
    }

    private func scopeQuery(alertID: String?) -> [URLQueryItem] {
        var values = [URLQueryItem(name: "tenantId", value: organizationID ?? settings.userID)]
        if let organizationID { values.append(URLQueryItem(name: "organizationId", value: organizationID)) }
        if let alertID, !alertID.isEmpty { values.append(URLQueryItem(name: "alertId", value: alertID)) }
        return values
    }

    private func components(path: String) throws -> URLComponents {
        guard let base = URL(string: settings.websiteBaseURL), base.scheme?.lowercased() == "https", let host = base.host,
              base.user == nil, base.password == nil,
              let serviceBase = host.lowercased() == "hanasand.com" ? URL(string: "https://ti.hanasand.com") : base,
              var components = URLComponents(url: serviceBase, resolvingAgainstBaseURL: false) else { throw IntelligenceCasesError.invalidURL }
        components.percentEncodedPath = path
        components.queryItems = nil
        components.fragment = nil
        guard let url = components.url, url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else { throw IntelligenceCasesError.invalidURL }
        return components
    }

    private func request(_ components: URLComponents, method: String, body: Data? = nil, uncertainOnFailure: Bool = false) async throws -> (Data, HTTPURLResponse) {
        guard let url = components.url else { throw IntelligenceCasesError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.userID, forHTTPHeaderField: "id")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let data: Data
        let raw: URLResponse
        do { (data, raw) = try await send(request) }
        catch { throw uncertainOnFailure ? IntelligenceCasesError.mutationOutcomeUnknown : IntelligenceCasesError.invalidResponse }
        guard let response = raw as? HTTPURLResponse, response.url == url else {
            throw uncertainOnFailure ? IntelligenceCasesError.mutationOutcomeUnknown : IntelligenceCasesError.invalidResponse
        }
        guard data.count <= Self.responseLimit, response.expectedContentLength <= 0 || response.expectedContentLength <= Self.responseLimit else {
            throw uncertainOnFailure ? IntelligenceCasesError.mutationOutcomeUnknown : IntelligenceCasesError.responseTooLarge
        }
        guard (200..<300).contains(response.statusCode) else {
            if uncertainOnFailure && response.statusCode >= 500 { throw IntelligenceCasesError.mutationOutcomeUnknown }
            throw IntelligenceCasesError.requestFailed(response.statusCode)
        }
        return (data, response)
    }

    static func validCaseID(_ value: String) -> Bool { !value.isEmpty && value.utf8.count <= 200 && value.range(of: "^[A-Za-z0-9][A-Za-z0-9._:-]*$", options: .regularExpression) != nil }
}

private final class IntelligenceCasesRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
