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

    func loadEventScope() async -> OrganizationWorkspaceEventScopeLoad {
        async let eventsResult = captureOrganizationWorkspaceResult { try await loadThreatFindings() }
        async let casesResult = captureOrganizationWorkspaceResult { try await loadCaseScope() }
        async let termsResult = captureOrganizationWorkspaceResult { try await loadScopedPayload(path: "api/organizations/\(segment(organizationID))/watchlists/alert-terms") }
        async let visibilityResult = captureOrganizationWorkspaceResult { try await loadScopedPayload(path: "api/organizations/\(segment(organizationID))/alert-case-visibility") }
        async let destinationsResult = captureOrganizationWorkspaceResult { try await loadScopedPayload(path: "api/organizations/\(segment(organizationID))/webhooks") }
        async let deliveriesResult = captureOrganizationWorkspaceResult { try await loadScopedPayload(path: "api/findings/webhooks/deliveries", query: [URLQueryItem(name: "organizationId", value: organizationID)]) }
        async let watchlistsResult = captureOrganizationWorkspaceResult { try await loadScopedPayload(path: "api/organizations/\(segment(organizationID))/watchlists", query: [URLQueryItem(name: "includeArchived", value: "true")]) }
        async let membersResult = captureOrganizationWorkspaceResult { try await loadScopedPayload(path: "api/organizations/\(segment(organizationID))/members") }

        let (events, cases, terms, visibility, destinations, deliveries, watchlists, members) = await (
            eventsResult, casesResult, termsResult, visibilityResult, destinationsResult,
            deliveriesResult, watchlistsResult, membersResult
        )
        var warnings: [String] = []

        let eventRecords: [ThreatFinding]?
        switch events {
        case let .success(page): eventRecords = page.alerts
        case let .failure(error): eventRecords = nil; warnings.append("Events could not be loaded: \(error.localizedDescription)")
        }
        let caseRecords: [OrganizationWorkspaceRecord]?
        let caseDetails: [[String: JSONValue]]?
        switch cases {
        case let .success(value): caseRecords = value.records; caseDetails = value.details; warnings.append(contentsOf: value.warnings)
        case let .failure(error): caseRecords = nil; caseDetails = nil; warnings.append("Cases could not be loaded: \(error.localizedDescription)")
        }

        let termsPayload = scopedPayloadResult(terms, source: "watchlist terms", warnings: &warnings)
        let visibilityPayload = scopedPayloadResult(visibility, source: "event visibility", warnings: &warnings)
        let destinationsPayload = scopedPayloadResult(destinations, source: "destinations", warnings: &warnings)
        let deliveriesPayload = scopedPayloadResult(deliveries, source: "delivery attempts", warnings: &warnings)
        let watchlistsPayload = scopedPayloadResult(watchlists, source: "watchlists", warnings: &warnings)
        let membersPayload = scopedPayloadResult(members, source: "organization members", warnings: &warnings)

        let termsRows: [OrganizationWorkspaceScopeRow]? = termsPayload.flatMap { payload in
            let export = payload["alertTermsExport"]?.objectValue
            guard let rows = scopedObjects(firstArray(payload["activeTerms"], export?["activeTerms"], payload["terms"]), source: "Watchlist terms", warnings: &warnings) else { return nil }
            return rows
                .enumerated().map { scopeTermRow($0.element, index: $0.offset) }
        }
        let visibilityRows = visibilityPayload.map { makeVisibilityRows($0) }
        let destinationRecords = destinationsPayload.flatMap { payload in
            scopedObjects(firstArray(payload["destinations"], payload["webhooks"]), source: "Destinations", warnings: &warnings)
        }
        let savedDestinationRows = destinationRecords?.enumerated().map { scopeDestinationRow($0.element, index: $0.offset) }
        let watchlistRows = watchlistsPayload.flatMap { payload in
            scopedObjects(firstArray(payload["watchlistItems"], payload["watchlists"], payload["items"]), source: "Watchlists", warnings: &warnings)
        }
        let memberRows = membersPayload.flatMap { payload in
            scopedObjects(firstArray(payload["members"]), source: "Organization members", warnings: &warnings)
        }
        let deliveryRows = deliveriesPayload.flatMap { payload in
            scopedObjects(firstArray(payload["deliveries"], payload["items"], payload["results"]), source: "Delivery attempts", warnings: &warnings)
        }

        if termsPayload != nil && termsRows == nil { warnings.append("Watchlist terms returned an invalid response.") }
        if destinationsPayload != nil && savedDestinationRows == nil { warnings.append("Destinations returned an invalid response.") }
        if watchlistsPayload != nil && watchlistRows == nil { warnings.append("Watchlists returned an invalid response.") }
        if membersPayload != nil && memberRows == nil { warnings.append("Organization members returned an invalid response.") }
        if deliveriesPayload != nil && deliveryRows == nil { warnings.append("Delivery attempts returned an invalid response.") }

        let destinationValues = destinationRecords ?? []
        let watchlistRecords = watchlistRows ?? []
        let destinationRows = savedDestinationRows.map { saved in
            saved + scopeWatchlistDestinationRows(watchlists: watchlistRecords, destinations: destinationValues)
        }
        let deliveryRecords = deliveryRows ?? []
        let eventRows = eventRecords?.map { finding in
            scopeEventRow(finding, organizationID: organizationID, deliveries: deliveryRecords)
        }
        let caseRows = caseRecords?.map { record in
            let raw = caseDetails?.first(where: { scopeText($0, "id", "caseId") == record.id }) ?? [:]
            return scopeCaseRow(record, raw: raw, members: memberRows ?? [], deliveries: deliveryRecords, organizationID: organizationID)
        }
        let configuredDestinations = configuredDestinationCount(destinations: destinationValues, watchlists: watchlistRecords)
        let failedDeliveries = deliveryRecords.filter { row in
            scopeText(row, "status")?.lowercased() == "failed" || scopeText(row, "error") != nil
        }.enumerated().map { scopeDeliveryFailureRow($0.element, index: $0.offset, destinations: destinationValues, organizationID: organizationID) }

        let scope = OrganizationWorkspaceEventScope(
            terms: termsRows, events: eventRows, cases: caseRows, visibility: visibilityRows,
            destinations: destinationRows, failures: deliveryRows == nil ? nil : failedDeliveries,
            termCount: termsRows?.count, eventCount: eventRecords?.count, caseCount: caseRecords?.count,
            destinationCount: destinationRows.map { _ in configuredDestinations },
            failureCount: deliveryRows.map { rows in rows.filter { scopeText($0, "status")?.lowercased() == "failed" || scopeText($0, "error") != nil }.count }
        )
        return OrganizationWorkspaceEventScopeLoad(
            eventRecords: eventRecords?.map { OrganizationWorkspaceRecord(id: $0.id, title: $0.title, status: $0.reviewState,
                severity: $0.severity, updatedAt: $0.observedAt, createdAt: "", organizationId: organizationID) },
            caseRecords: caseRecords, scope: scope, warnings: warnings
        )
    }

    private func loadEvents() async throws -> [OrganizationWorkspaceRecord] {
        let alerts = try await loadThreatFindings()
        return alerts.alerts.map { OrganizationWorkspaceRecord(id: $0.id, title: $0.title, status: $0.reviewState, severity: $0.severity, updatedAt: $0.observedAt, createdAt: "", organizationId: organizationID) }
    }

    private func loadThreatFindings() async throws -> ThreatFindingPage {
        let alerts: ThreatFindingPage = try await request(path: "api/findings/alerts", query: [
            URLQueryItem(name: "tenantId", value: organizationID), URLQueryItem(name: "organizationId", value: organizationID), URLQueryItem(name: "limit", value: "50")
        ])
        try alerts.validate(tenantID: organizationID, organizationID: organizationID, requestedCursor: nil)
        return alerts
    }

    private func loadCaseScope() async throws -> (records: [OrganizationWorkspaceRecord], details: [[String: JSONValue]], warnings: [String]) {
        let payload: [String: JSONValue] = try await request(path: "api/cases", query: [
            URLQueryItem(name: "organizationId", value: organizationID), URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "limit", value: "50")
        ])
        try validateScopeIdentity(payload, organizationID: organizationID)
        guard let details = firstArray(payload["cases"], payload["items"], payload["results"]) else {
            throw OrganizationWorkspaceError.invalidResponse
        }
        let filtered = try details.map { try safeObject($0, organizationID: organizationID, requireOrganization: false) }
        let records: [OrganizationWorkspaceRecord] = filtered.compactMap { row -> OrganizationWorkspaceRecord? in
            guard let id = scopeText(row, "id", "caseId") else { return nil }
            return OrganizationWorkspaceRecord(id: id, title: scopeText(row, "title", "name") ?? id,
                status: scopeText(row, "status", "state") ?? "unknown", severity: scopeText(row, "severity", "priority") ?? "",
                updatedAt: scopeText(row, "updatedAt", "updated_at") ?? "", createdAt: scopeText(row, "createdAt", "created_at") ?? "",
                organizationId: organizationID)
        }
        return (records, filtered, payload["warnings"]?.stringArray ?? [])
    }

    private func loadScopedPayload(path: String, query: [URLQueryItem] = []) async throws -> [String: JSONValue] {
        let payload: [String: JSONValue] = try await request(path: path, query: query)
        try validateScopeIdentity(payload, organizationID: organizationID)
        return payload
    }

    private func scopedPayloadResult(_ result: Result<[String: JSONValue], Error>, source: String,
                                     warnings: inout [String]) -> [String: JSONValue]? {
        switch result {
        case let .success(payload): return payload
        case let .failure(error): warnings.append("\(source.capitalized) could not be loaded: \(error.localizedDescription)"); return nil
        }
    }

    private func scopedObjects(_ values: [JSONValue]?, source: String,
                               warnings: inout [String]) -> [[String: JSONValue]]? {
        guard let values else {
            warnings.append("\(source) returned an invalid response.")
            return nil
        }
        do { return try values.map { try safeObject($0, organizationID: organizationID) } }
        catch {
            warnings.append("\(source) included records outside the selected organization; those records were not shown.")
            return nil
        }
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

struct OrganizationWorkspaceScopeRow: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let updatedAt: String
    let contextPath: String?
    let contextQuery: [String: String]
}

struct OrganizationWorkspaceEventScope: Equatable {
    let terms: [OrganizationWorkspaceScopeRow]?
    let events: [OrganizationWorkspaceScopeRow]?
    let cases: [OrganizationWorkspaceScopeRow]?
    let visibility: [OrganizationWorkspaceScopeRow]?
    let destinations: [OrganizationWorkspaceScopeRow]?
    let failures: [OrganizationWorkspaceScopeRow]?
    let termCount: Int?
    let eventCount: Int?
    let caseCount: Int?
    let destinationCount: Int?
    let failureCount: Int?
}

struct OrganizationWorkspaceEventScopeLoad {
    let eventRecords: [OrganizationWorkspaceRecord]?
    let caseRecords: [OrganizationWorkspaceRecord]?
    let scope: OrganizationWorkspaceEventScope
    let warnings: [String]
}

private func validateScopeIdentity(_ payload: [String: JSONValue], organizationID: String) throws {
    let organization = payload["organization"]?.objectValue
    let nested = ["alertTermsExport", "alertCaseVisibility", "caseVisibility"].compactMap { payload[$0]?.objectValue }
    let ids = ([scopeText(payload, "organizationId", "organization_id", "orgId", "org_id", "tenantId", "tenant_id"),
                organization.flatMap { scopeText($0, "id", "organizationId", "organization_id") }]
        + nested.map { scopeText($0, "organizationId", "organization_id", "orgId", "org_id", "tenantId", "tenant_id") })
        .compactMap { $0 }
    guard ids.allSatisfy({ $0 == organizationID }) else { throw OrganizationWorkspaceError.scopeChanged }
}

private func safeObject(_ value: JSONValue, organizationID: String, requireOrganization: Bool = false) throws -> [String: JSONValue] {
    guard let object = value.objectValue else { throw OrganizationWorkspaceError.invalidResponse }
    let rowOrganization = scopeText(object, "organizationId", "organization_id", "orgId", "org_id", "tenantId", "tenant_id")
    if let rowOrganization, rowOrganization != organizationID { throw OrganizationWorkspaceError.scopeChanged }
    if requireOrganization && rowOrganization == nil { throw OrganizationWorkspaceError.scopeChanged }
    return object
}

private func firstArray(_ values: JSONValue?...) -> [JSONValue]? {
    for value in values {
        if let value, case .array(let rows) = value { return rows }
    }
    return nil
}

private func scopeText(_ object: [String: JSONValue], _ keys: String...) -> String? {
    for key in keys {
        guard let value = object[key] else { continue }
        switch value {
        case .string(let text): if !text.isEmpty { return text }
        case .number(let number): return number.rounded() == number ? String(Int(number)) : String(number)
        case .bool(let value): return value ? "true" : "false"
        default: continue
        }
    }
    return nil
}

private func safeOrganizationDisplay(_ input: String, limit: Int = 240) -> String {
    input
        .replacingOccurrences(of: #"https://(?:canary\.)?discord(?:app)?\.com/api/webhooks/[^\s\"'<>]+"#, with: "[webhook redacted]", options: .regularExpression)
        .replacingOccurrences(of: #"\b[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{6,}\.[A-Za-z0-9_-]{20,}\b"#, with: "[token redacted]", options: .regularExpression)
        .replacingOccurrences(of: #"(?i)\b(token|secret|webhookUrl|authorization|apiKey)[\"']?\s*[:=]\s*(?:\"[^\"]*\"|'[^']*'|[^\s,}\]]+)"#, with: "$1: [redacted]", options: .regularExpression)
        .components(separatedBy: .controlCharacters).joined(separator: " ")
        .components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        .prefix(limit).description
}

private func scopeTermRow(_ row: [String: JSONValue], index: Int) -> OrganizationWorkspaceScopeRow {
    let title = safeOrganizationDisplay(scopeText(row, "term", "value") ?? "Watchlist term")
    let kind = safeOrganizationDisplay(scopeText(row, "kind", "family") ?? "term", limit: 80)
    let match = scopeText(row, "matchReason")
    let detail = [kind, match.map { "Match: \(safeOrganizationDisplay($0))" }].compactMap { $0 }.joined(separator: " · ")
    var query: [String: String] = [:]
    if let watchlistID = scopeText(row, "watchlistItemId", "watchlistId") { query["watchlistId"] = watchlistID }
    return OrganizationWorkspaceScopeRow(id: scopeText(row, "watchlistItemId", "watchlistId", "alertGenerationRef") ?? "term-\(index)",
        title: title, detail: detail, updatedAt: "", contextPath: "/organizations/watchlists", contextQuery: query)
}

private func scopeEventRow(_ finding: ThreatFinding, organizationID: String,
                           deliveries: [[String: JSONValue]]) -> OrganizationWorkspaceScopeRow {
    let reason = matchingDelivery(finding.id, deliveries: deliveries).flatMap(deliveryMatchReason)
    let detail = [finding.severity, finding.reviewState, finding.matchedTerm.isEmpty ? nil : "Term: \(safeOrganizationDisplay(finding.matchedTerm))",
                  reason.map { "Match: \(safeOrganizationDisplay($0))" }].compactMap { $0 }.joined(separator: " · ")
    return OrganizationWorkspaceScopeRow(id: finding.id, title: safeOrganizationDisplay(finding.title), detail: detail,
        updatedAt: finding.observedAt, contextPath: "/ti/workbench",
        contextQuery: ["organizationId": organizationID, "alertId": finding.id])
}

private func scopeCaseRow(_ record: OrganizationWorkspaceRecord, raw: [String: JSONValue], members: [[String: JSONValue]],
                          deliveries: [[String: JSONValue]], organizationID: String) -> OrganizationWorkspaceScopeRow {
    let ownerID = scopeText(raw, "assignedOwner", "assigned_owner", "ownerId", "owner_id")
    let owner = ownerID.flatMap { id in
        members.first(where: { scopeText($0, "userId", "user_id", "id", "email") == id })
            .flatMap { scopeText($0, "name", "email", "userId", "user_id") }
    } ?? ownerID
    let reason = matchingDelivery(record.id, deliveries: deliveries).flatMap(deliveryMatchReason)
    let detail = [safeOrganizationDisplay(record.status, limit: 80), owner.map { "Owner: \(safeOrganizationDisplay($0))" },
                  reason.map { "Match: \(safeOrganizationDisplay($0))" }].compactMap { $0 }.joined(separator: " · ")
    let safeID = record.id.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
    return OrganizationWorkspaceScopeRow(id: record.id, title: safeOrganizationDisplay(record.title), detail: detail,
        updatedAt: safeOrganizationDisplay(record.updatedAt.isEmpty ? record.createdAt : record.updatedAt, limit: 80), contextPath: "/cases/\(safeID)",
        contextQuery: ["organizationId": organizationID])
}

private func makeVisibilityRows(_ payload: [String: JSONValue]) -> [OrganizationWorkspaceScopeRow] {
    let value = payload["alertCaseVisibility"]?.objectValue ?? payload["caseVisibility"]?.objectValue ?? payload
    let visibility = value["visibility"]?.objectValue ?? value
    let rows: [(String, String?)] = [
        ("Event visibility", scopeText(visibility, "alertReadAllowed", "allowed")),
        ("Case assignment", scopeText(visibility, "caseAssignmentAllowed", "canAssignCase")),
        ("Case route", scopeText(value, "caseRoute") ?? scopeText(value["caseWorkflow"]?.objectValue ?? [:], "casePathTemplate", "route")),
    ]
    return rows.map { label, raw in
        OrganizationWorkspaceScopeRow(id: label, title: label, detail: raw.map { safeOrganizationDisplay($0) } ?? "Not available",
            updatedAt: "", contextPath: nil, contextQuery: [:])
    }
}

private func scopeDestinationRow(_ row: [String: JSONValue], index: Int) -> OrganizationWorkspaceScopeRow {
    let title = safeOrganizationDisplay(scopeText(row, "name") ?? "Webhook destination")
    let status = scopeText(row, "status") ?? "unknown"
    let configured = scopeBool(row, "deliveryReady") || ["active", "configured"].contains(status.lowercased())
        || scopeText(row, "endpointHash", "endpointHint", "endpoint_hash", "endpoint_hint") != nil
    let state = configured ? "Destination configured" : "Destination pending"
    return OrganizationWorkspaceScopeRow(id: scopeText(row, "id") ?? "destination-\(index)", title: title,
        detail: "\(safeOrganizationDisplay(status, limit: 80)) · \(state)", updatedAt: "",
        contextPath: "/integrations", contextQuery: [:])
}

private func scopeDeliveryFailureRow(_ row: [String: JSONValue], index: Int, destinations: [[String: JSONValue]],
                                    organizationID: String) -> OrganizationWorkspaceScopeRow {
    let destinationID = scopeText(row, "destinationId", "webhookDestinationId", "destination_id")
    let destinationName = destinationID.flatMap { id in destinations.first(where: { scopeText($0, "id") == id }).flatMap { scopeText($0, "name") } }
    let subject = scopeText(row, "alertId", "caseId")
    let status = safeOrganizationDisplay(scopeText(row, "status") ?? "failed", limit: 80)
    let title = destinationName.map { "\(safeOrganizationDisplay($0)) delivery" } ?? "Delivery attempt"
    let date = safeOrganizationDisplay(scopeText(row, "attemptedAt", "updatedAt", "createdAt") ?? "", limit: 80)
    let subjectDetail = subject.map { "Record \(safeOrganizationDisplay($0, limit: 120))" }
    return OrganizationWorkspaceScopeRow(id: scopeText(row, "id", "requestId") ?? "delivery-\(index)", title: title,
        detail: ([status] + [subjectDetail]).compactMap { $0 }.joined(separator: " · "), updatedAt: date,
        contextPath: "/dashboard/delivery-history", contextQuery: ["organizationId": organizationID])
}

private func matchingDelivery(_ recordID: String, deliveries: [[String: JSONValue]]) -> [String: JSONValue]? {
    deliveries.first { row in ["alertId", "alert_id", "caseId", "case_id"].contains { scopeText(row, $0) == recordID } }
}

private func deliveryMatchReason(_ delivery: [String: JSONValue]) -> String? {
    let preview = delivery["sanitizedPayloadPreview"]?.objectValue ?? delivery["payloadPreview"]?.objectValue
    if let reason = scopeText(preview?["context"]?.objectValue ?? [:], "matchReason") { return reason }
    let embeds = firstArray(delivery["payload"]?.objectValue?["embeds"])
    guard let embed = embeds?.first?.objectValue,
          let fields = firstArray(embed["fields"]) else { return nil }
    return fields.compactMap(\.objectValue).first(where: { scopeText($0, "name")?.caseInsensitiveCompare("Match reason") == .orderedSame })
        .flatMap { scopeText($0, "value") }
}

private func scopeWatchlistDestinationRows(watchlists: [[String: JSONValue]], destinations: [[String: JSONValue]]) -> [OrganizationWorkspaceScopeRow] {
    watchlists.enumerated().compactMap { index, item in
        let destinationID = scopeText(item, "webhookDestinationId")
        let hash = scopeText(item, "webhookEndpointHash")
        let hint = scopeText(item, "webhookEndpointHint")
        let configured = scopeBool(item, "webhookUrlConfigured") || destinationID != nil || hash != nil || hint != nil
        guard configured else { return nil }
        let alreadyListed = destinations.contains { destination in
            (destinationID != nil && destinationID == scopeText(destination, "id"))
                || (hash != nil && hash == scopeText(destination, "endpointHash", "endpoint_hash"))
                || (hint != nil && hint == scopeText(destination, "endpointHint", "endpoint_hint"))
        }
        guard !alreadyListed else { return nil }
        let id = scopeText(item, "id") ?? "watchlist-\(index)"
        let title = safeOrganizationDisplay(scopeText(item, "value", "name") ?? "Watchlist destination")
        let status = safeOrganizationDisplay(scopeText(item, "status") ?? "active", limit: 80)
        return OrganizationWorkspaceScopeRow(id: "watchlist-\(id)", title: title,
            detail: "\(status) · Destination configured · Watchlist route", updatedAt: "",
            contextPath: "/organizations/watchlists", contextQuery: ["watchlistId": id])
    }
}

private func configuredDestinationCount(destinations: [[String: JSONValue]], watchlists: [[String: JSONValue]]) -> Int {
    let savedCount = destinations.filter { row in
        scopeBool(row, "deliveryReady") || ["active", "configured"].contains((scopeText(row, "status") ?? "").lowercased())
            || scopeText(row, "endpointHash", "endpointHint", "endpoint_hash", "endpoint_hint") != nil
    }.count
    return savedCount + scopeWatchlistDestinationRows(watchlists: watchlists, destinations: destinations).count
}

private func scopeBool(_ object: [String: JSONValue], _ key: String) -> Bool {
    guard let value = object[key], case .bool(let result) = value else { return false }
    return result
}

private extension JSONValue {
    var objectValue: [String: JSONValue]? { if case .object(let object) = self { return object }; return nil }
    var stringArray: [String]? {
        guard case .array(let values) = self else { return nil }
        return values.compactMap { if case .string(let value) = $0 { return value }; return nil }
    }
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
