import Foundation

private func captureOrganizationWorkspaceResult<Value>(_ operation: () async throws -> Value) async -> Result<Value, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}

private final class OrganizationWorkspaceRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum OrganizationWorkspaceSession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: OrganizationWorkspaceRedirectBlocker(), delegateQueue: nil)
    }()
}

struct OrganizationWorkspaceClient {
    let baseURL: URL
    let organizationID: String
    let userID: String
    let authToken: String
    let isImpersonationClear: Bool
    var send: (URLRequest) async throws -> (Data, URLResponse) = { request in
        try await OrganizationWorkspaceSession.shared.data(for: request)
    }

    init(settings: HanasandDesktopSettings, organizationID: String,
         send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        let rawBase = settings.websiteBaseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let base = URL(string: rawBase), base.scheme?.lowercased() == "https", base.host != nil,
              base.user == nil, base.password == nil else { throw OrganizationWorkspaceError.invalidBaseURL }
        let user = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !token.isEmpty else { throw OrganizationWorkspaceError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else { throw OrganizationWorkspaceError.invalidCredentials }
        guard !organizationID.isEmpty, organizationID != "personal",
              settings.selectedOrganizationID == organizationID,
              settings.selectedOrganizationUserID == user else { throw OrganizationWorkspaceError.scopeChanged }
        self.baseURL = base
        self.organizationID = organizationID
        self.userID = user
        self.authToken = token
        self.isImpersonationClear = settings.impersonationToken.isEmpty && settings.impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if let send { self.send = send }
    }

    func loadSettings() async throws -> OrganizationWorkspaceSettingsPage {
        let page: OrganizationWorkspaceSettingsPage = try await request(path: "api/organizations/\(segment(organizationID))/settings")
        guard page.organization.id == organizationID else { throw OrganizationWorkspaceError.scopeChanged }
        return page
    }

    func loadRecords() async -> OrganizationWorkspaceRecordsLoad {
        async let eventResult = captureOrganizationWorkspaceResult { try await loadEvents() }
        async let caseResult = captureOrganizationWorkspaceResult { try await loadCases() }
        let (events, cases) = await (eventResult, caseResult)
        var warnings: [String] = []
        let eventRecords: [OrganizationWorkspaceRecord]?
        switch events {
        case let .success(value): eventRecords = value
        case let .failure(error):
            eventRecords = nil
            warnings.append("Events could not be loaded: \(error.localizedDescription)")
        }
        let caseRecords: [OrganizationWorkspaceRecord]?
        switch cases {
        case let .success((records, caseWarnings)):
            caseRecords = records
            warnings.append(contentsOf: caseWarnings)
        case let .failure(error):
            caseRecords = nil
            warnings.append("Cases could not be loaded: \(error.localizedDescription)")
        }
        return OrganizationWorkspaceRecordsLoad(events: eventRecords, cases: caseRecords, warnings: warnings)
    }

    private func loadEvents() async throws -> [OrganizationWorkspaceRecord] {
        let alerts: ThreatFindingPage = try await request(path: "api/findings/alerts", query: [
            URLQueryItem(name: "tenantId", value: organizationID), URLQueryItem(name: "organizationId", value: organizationID), URLQueryItem(name: "limit", value: "50")
        ])
        try alerts.validate(tenantID: organizationID, organizationID: organizationID, requestedCursor: nil)

        return alerts.alerts.map { OrganizationWorkspaceRecord(id: $0.id, title: $0.title, status: $0.reviewState, severity: $0.severity, updatedAt: $0.observedAt, createdAt: "", organizationId: organizationID) }
    }

    private func loadCases() async throws -> (records: [OrganizationWorkspaceRecord], warnings: [String]) {
        let cases: OrganizationWorkspaceRecordPage = try await request(path: "api/cases", query: [
            URLQueryItem(name: "organizationId", value: organizationID), URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "limit", value: "50")
        ])
        guard cases.organizationId == nil || cases.organizationId == organizationID,
              cases.records.allSatisfy({ $0.organizationId == nil || $0.organizationId == organizationID }) else {
            throw OrganizationWorkspaceError.scopeChanged
        }
        return (cases.records, cases.warnings)
    }

    func loadActivity(includeInvites: Bool = true) async throws -> OrganizationWorkspaceActivityPage {
        async let members = try? request(path: "api/organizations/\(segment(organizationID))/members") as [String: JSONValue]
        async let watchlists = try? request(path: "api/organizations/\(segment(organizationID))/watchlists", query: [URLQueryItem(name: "includeArchived", value: "true")]) as [String: JSONValue]
        async let destinations = try? request(path: "api/organizations/\(segment(organizationID))/webhooks") as [String: JSONValue]
        async let deliveries = try? request(path: "api/findings/webhooks/deliveries", query: [URLQueryItem(name: "organizationId", value: organizationID)]) as [String: JSONValue]
        let (membersPayload, watchlistsPayload, destinationsPayload, deliveriesPayload) = await (members, watchlists, destinations, deliveries)
        let invitesPayload: [String: JSONValue]? = includeInvites
            ? try? await request(path: "api/organizations/\(segment(organizationID))/invites")
            : nil
        var payloads: [(String, [String: JSONValue]?)] = [
            ("members", membersPayload), ("watchlists", watchlistsPayload),
            ("destinations", destinationsPayload), ("deliveries", deliveriesPayload)
        ]
        if includeInvites { payloads.append(("invites", invitesPayload)) }
        var rows: [OrganizationWorkspaceActivityEntry] = []
        var warnings: [String] = []
        for (source, payload) in payloads {
            guard let payload else { warnings.append("Could not load organization \(source) activity."); continue }
            let arrayKeys: [String]
            switch source {
            case "members": arrayKeys = ["members"]
            case "invites": arrayKeys = ["invites"]
            case "watchlists": arrayKeys = ["watchlistItems", "watchlists", "items"]
            case "destinations": arrayKeys = ["destinations", "webhooks"]
            default: arrayKeys = ["deliveries", "items", "results"]
            }
            guard let objects = arrayKeys.compactMap({ payload[$0]?.objectArray }).first else {
                warnings.append("Organization \(source) activity returned an invalid response."); continue
            }
            rows += objects.compactMap { activityEntry($0, source: source, organizationID: organizationID) }
        }
        return OrganizationWorkspaceActivityPage(entries: rows.sorted { $0.occurredAt > $1.occurredAt }, warnings: warnings)
    }

    func updateSettings(_ draft: OrganizationWorkspaceSettings,
                        contextIsCurrent: @MainActor () -> Bool = { true }) async throws -> OrganizationWorkspaceSettingsReceipt {
        guard isImpersonationClear else { throw OrganizationWorkspaceError.impersonationUnsupported }
        guard OrganizationWorkspacePolicy.valid(draft) else { throw OrganizationWorkspaceError.invalidSettings }
        let fresh = try await loadSettings()
        guard OrganizationWorkspacePolicy.canEdit(settings: fresh, selectedOrganizationID: organizationID,
            signedInUserID: userID, isAuthenticated: true, isImpersonating: !isImpersonationClear) else {
            throw OrganizationWorkspaceError.permissionChanged
        }
        guard await contextIsCurrent() else { throw OrganizationWorkspaceError.scopeChanged }
        let body = try JSONEncoder().encode(SettingsWrite(
            name: draft.name.trimmingCharacters(in: .whitespacesAndNewlines), slug: draft.slug,
            defaultWebhookPolicy: draft.defaultWebhookPolicy, alertVisibilityPolicy: draft.alertVisibilityPolicy,
            lifecycleStatus: draft.lifecycleStatus, retentionDays: draft.retentionDays
        ))
        let receipt: OrganizationWorkspaceSettingsReceipt = try await request(
            path: "api/organizations/\(segment(organizationID))/settings", method: "PUT", body: body
        )
        guard receipt.organization?.id == organizationID,
              receipt.organization?.name == draft.name.trimmingCharacters(in: .whitespacesAndNewlines),
              receipt.settingsMutationReceipt?.schemaVersion == "organization.lifecycle_settings_mutation_receipt.v1",
              receipt.settingsMutationReceipt?.organizationId == organizationID else { throw OrganizationWorkspaceError.unconfirmedMutation }
        return receipt
    }

    private func request<T: Decodable>(path: String, query: [URLQueryItem] = [], method: String = "GET", body: Data? = nil) async throws -> T {
        guard let url = try endpointURL(path) else { throw OrganizationWorkspaceError.invalidResponse }
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw OrganizationWorkspaceError.invalidResponse }
        components.queryItems = query.isEmpty ? nil : query
        guard let requestURL = components.url, requestURL.scheme == "https", requestURL.host == baseURL.host else { throw OrganizationWorkspaceError.invalidBaseURL }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse, http.url?.scheme == "https", http.url?.host == baseURL.host else { throw OrganizationWorkspaceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(OrganizationWorkspaceAPIError.self, from: data).error.message) ?? "Organization request failed."
            throw OrganizationWorkspaceError.requestFailed(http.statusCode, message)
        }
        do { return try JSONDecoder().decode(T.self, from: data) }
        catch { throw OrganizationWorkspaceError.invalidResponse }
    }

    private func segment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    }

    private func endpointURL(_ path: String) throws -> URL? {
        guard !path.hasPrefix("/"), !path.split(separator: "/").contains(".."),
              var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else { return nil }
        let basePath = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let pathCharacterSet = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~%")
        let encodedPath = path.split(separator: "/").map { String($0).addingPercentEncoding(withAllowedCharacters: pathCharacterSet) ?? "" }.joined(separator: "/")
        components.percentEncodedPath = "/" + [basePath, encodedPath].filter { !$0.isEmpty }.joined(separator: "/")
        return components.url
    }

    private struct SettingsWrite: Encodable {
        let name, slug, defaultWebhookPolicy, alertVisibilityPolicy, lifecycleStatus: String
        let retentionDays: Int
    }
    private struct OrganizationWorkspaceAPIError: Decodable { struct Detail: Decodable { let message: String }; let error: Detail }
}

private extension JSONValue {
    var objectArray: [[String: JSONValue]]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap { if case .object(let object) = $0 { return object }; return nil }
    }
}

private func activityEntry(_ row: [String: JSONValue], source: String, organizationID: String) -> OrganizationWorkspaceActivityEntry? {
    func text(_ keys: String...) -> String? {
        for key in keys {
            guard let value = row[key] else { continue }
            if case .string(let string) = value, !string.isEmpty { return string }
            if case .number(let number) = value { return number.rounded() == number ? String(Int(number)) : String(number) }
        }
        return nil
    }
    let rowOrganization = text("organizationId", "organization_id", "orgId", "tenantId", "tenant_id")
    if let rowOrganization, rowOrganization != organizationID { return nil }
    guard let subjectID = text("id", "userId", "user_id", "inviteId", "requestId") else { return nil }
    let status = text("status", "lifecycleStatus", "reviewState") ?? "unknown"
    let occurredAt = text("attemptedAt", "updatedAt", "updated_at", "createdAt", "created_at", "joinedAt", "joined_at", "archivedAt", "archived_at") ?? ""
    let title: String
    let detail: String
    let kind: OrganizationWorkspaceActivityKind
    let path: String
    var query = ["organizationId": organizationID]
    var metadata: [String] = ["Status · \(status)"]
    switch source {
    case "members":
        kind = .member; title = text("name", "email", "userId") ?? "Organization member"
        let role = text("role") ?? "member"; let email = text("email")
        detail = [role, status].joined(separator: " · ")
        if let email { metadata.append("Email · \(email)") }
        path = "/organizations/team"; query["memberId"] = subjectID; query["focus"] = "members"
    case "invites":
        kind = .invite; title = text("email") ?? "Organization invitation"
        let role = text("role") ?? "member"; detail = "\(role) · \(status)"
        if let expires = text("expiresAt", "expires_at") { metadata.append("Expires · \(expires)") }
        path = "/organizations/team"; query["inviteId"] = subjectID; query["focus"] = "invites"
    case "watchlists":
        kind = .watchlist; title = text("value", "name") ?? "Watchlist term"
        detail = "\(text("kind") ?? "term") · \(status)"
        if let notes = text("notes") { metadata.append("Notes · \(notes)") }
        path = "/watchlists"; query["watchlistId"] = subjectID
    case "destinations":
        kind = .destination; title = text("name") ?? "Webhook destination"
        detail = "\(text("kind", "type") ?? "webhook") · \(status)"
        if let hint = text("endpointHint", "endpoint_hint") { metadata.append("Endpoint · \(hint)") }
        path = "/integrations"; query["destinationId"] = subjectID
    default:
        kind = .delivery; title = text("deliveryKind", "delivery_kind") == "test" || text("dryRun") == "true" ? "Destination tested" : "Event delivery"
        detail = "\(status)\(text("alertId", "alert_id").map { " · Event \($0)" } ?? "")"
        if let destination = text("destinationId", "destination_id") { metadata.append("Destination · \(destination)") }
        if let alert = text("alertId", "alert_id") { metadata.append("Event · \(alert)"); query["alertId"] = alert }
        path = "/dashboard/delivery-history"
    }
    return OrganizationWorkspaceActivityEntry(id: "\(source)-\(subjectID)", kind: kind, occurredAt: occurredAt,
        title: title, detail: detail, status: status, subjectID: subjectID, contextPath: path, contextQuery: query, metadata: metadata)
}


enum OrganizationWorkspaceError: LocalizedError {
    case invalidBaseURL, signInRequired, invalidCredentials, scopeChanged, impersonationUnsupported
    case permissionChanged, invalidSettings, unconfirmedMutation, invalidResponse
    case requestFailed(Int, String)
    var errorDescription: String? {
        switch self {
        case .invalidBaseURL: return "Organization workspace requires a secure website URL."
        case .signInRequired: return "Sign in to open the organization workspace."
        case .invalidCredentials: return "The current account credentials are invalid. Sign in again."
        case .scopeChanged: return "Organization selection changed. Refresh before continuing."
        case .impersonationUnsupported: return "Return to your own account before changing organization settings."
        case .permissionChanged: return "Owner or admin access changed. Refresh before saving."
        case .invalidSettings: return "Review the setting values before saving."
        case .unconfirmedMutation: return "The server did not confirm the settings change. Refresh and review the current values."
        case .invalidResponse: return "The organization service returned an invalid response."
        case let .requestFailed(status, message): return "Organization request returned HTTP \(status): \(message)"
        }
    }
}
