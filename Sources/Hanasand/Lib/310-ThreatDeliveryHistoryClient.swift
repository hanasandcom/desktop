import Foundation

struct ThreatDeliveryHistoryClient {
    private let settings: HanasandDesktopSettings
    private let organizationID: String
    private let send: (URLRequest) async throws -> (Data, URLResponse)
    private static let responseLimit = 2_000_000

    init(settings: HanasandDesktopSettings,
         send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        guard !settings.userID.isEmpty, !settings.authToken.isEmpty else {
            throw ThreatDeliveryHistoryError.signInRequired
        }
        guard settings.userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              settings.authToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw ThreatDeliveryHistoryError.invalidCredentials
        }
        let organizationID = settings.selectedOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard ThreatDeliveryHistory.validID(organizationID), organizationID != "personal",
              organizationID != settings.userID,
              settings.selectedOrganizationUserID == settings.userID else {
            throw ThreatDeliveryHistoryError.organizationRequired
        }
        guard settings.impersonationToken.isEmpty && settings.impersonatingUserID.isEmpty else {
            throw ThreatDeliveryHistoryError.impersonationUnsupported
        }
        guard let base = URL(string: settings.apiBaseURL), base.scheme?.lowercased() == "https",
              base.host != nil, base.user == nil, base.password == nil,
              base.query == nil, base.fragment == nil,
              let site = URL(string: settings.websiteBaseURL), site.scheme?.lowercased() == "https",
              site.host != nil, site.user == nil, site.password == nil, site.query == nil, site.fragment == nil else {
            throw ThreatDeliveryHistoryError.invalidBaseURL
        }
        self.settings = settings
        self.organizationID = organizationID
        let transport = try send ?? Self.ephemeralSender()
        self.send = { request in
            let (data, response) = try await transport(request)
            guard data.count <= Self.responseLimit else { throw ThreatDeliveryHistoryError.invalidResponse }
            return (data, response)
        }
    }

    func load() async throws -> ThreatDeliveryHistory {
        let historyURL = try apiURL(path: "dwm/webhook-deliveries", query: [URLQueryItem(name: "orgId", value: organizationID)])
        let (data, response) = try await request(historyURL)
        let http = try checked(response)
        guard (200..<300).contains(http.statusCode) else { throw ThreatDeliveryHistoryError.requestFailed(http.statusCode) }
        guard data.count <= Self.responseLimit else { throw ThreatDeliveryHistoryError.invalidResponse }
        let root = try jsonObject(data)
        let envelope: Envelope
        do { envelope = try JSONDecoder().decode(Envelope.self, from: data) }
        catch { throw ThreatDeliveryHistoryError.invalidResponse }
        guard envelope.visibility.allowed,
              envelope.deliveries.count <= 100,
              Set(envelope.deliveries.map(\.id)).count == envelope.deliveries.count,
              envelope.deliveries.allSatisfy({
                  $0.orgId == organizationID && ThreatDeliveryHistory.validID($0.id)
                      && ThreatDeliveryHistory.validID($0.alertId) && ThreatDeliveryHistory.validID($0.orgId)
              }) else { throw ThreatDeliveryHistoryError.organizationScopeChanged }

        var page = ThreatDeliveryHistory(deliveries: envelope.deliveries, organizationID: organizationID)
        let rawReadiness = root["deliveryReadinessConsumer"] as? [String: Any] ?? [:]
        let retry = root["deliveryRetryRequest"] as? [String: Any] ?? [:]
        let retryAccess = retry["access"] as? [String: Any] ?? [:]
        let canRetryAccess = retryAccess["canRetry"] as? Bool == true
        let readinessAccess = rawReadiness["access"] as? [String: Any] ?? [:]
        let canManage: Bool
        var integration: IntegrationPage?
        do {
            integration = try await IntegrationClient(apiBaseURL: URL(string: settings.apiBaseURL)!, userID: settings.userID,
                token: settings.authToken, organizationID: organizationID, send: send).load()
            canManage = integration?.destinationAdminProof.access?.canManage == true
                && readinessAccess["canRetry"] as? Bool == true
        } catch {
            canManage = false
        }

        var findings: [ThreatDeliveryHistory.Finding] = []
        var cursor: String?
        var findingsComplete = false
        for _ in 0..<20 {
            let url = try findingsURL(cursor: cursor)
            let (findingData, findingResponse) = try await request(url)
            let findingHTTP = try checked(findingResponse)
            guard (200..<300).contains(findingHTTP.statusCode), findingData.count <= Self.responseLimit else { break }
            let decoded: ThreatFindingPage
            do { decoded = try JSONDecoder().decode(ThreatFindingPage.self, from: findingData) }
            catch { break }
            try decoded.validate(tenantID: organizationID, organizationID: organizationID, requestedCursor: cursor)
            guard let findingRoot = try? jsonObject(findingData), let rawAlerts = findingRoot["alerts"] as? [[String: Any]], rawAlerts.count == decoded.alerts.count else { break }
            for (finding, raw) in zip(decoded.alerts, rawAlerts) {
                guard finding.organizationID == organizationID, finding.tenantID == organizationID else { throw ThreatDeliveryHistoryError.organizationScopeChanged }
                findings.append(.init(id: finding.id, title: finding.title, actor: finding.actor, matchedTerm: finding.matchedTerm,
                    reviewState: finding.reviewState, deliveryState: finding.deliveryState, caseID: finding.caseID,
                    organizationID: organizationID, full: raw))
            }
            guard findings.count <= 1000 else { throw ThreatDeliveryHistoryError.invalidResponse }
            cursor = decoded.nextCursor
            if cursor == nil { findingsComplete = true; break }
        }
        page.findings = findings
        let liveEnabled = rawReadiness["liveDeliveryEnabled"] as? Bool == true
        let findingsValid = findingsComplete
        page.canTest = canManage && findingsValid
        page.canSend = canManage && findingsValid && liveEnabled
        page.canRetry = canManage && canRetryAccess && liveEnabled
        page.liveDeliveryEnabled = liveEnabled
        page.notice = integration == nil ? "Workspace permissions could not be verified. History is read-only."
            : !findingsValid ? "Findings could not be loaded. Refresh before sending."
            : !canManage ? "Delivery actions are unavailable for this account or membership."
            : !liveEnabled ? "Live delivery is disabled. Dry-run tests remain available." : ""
        for entry in (retry["entries"] as? [[String: Any]] ?? []) {
            guard entry["orgId"] as? String == organizationID,
                  let live = entry["liveRequest"] as? [String: Any], live["canSend"] as? Bool == true,
                  live["externalSendEnabled"] as? Bool == true,
                  !((live["blockers"] as? [[String: Any]] ?? []).contains { $0["blocking"] as? Bool == true }) else { continue }
            guard let id = entry["deliveryId"] as? String, let alertID = entry["alertId"] as? String,
                  let index = page.deliveries.firstIndex(where: { $0.id == id && $0.alertId == alertID }),
                  page.deliveries[index].status == .failed, !page.deliveries[index].dryRun else { continue }
            page.deliveries[index].retryEligible = page.canRetry && retryAccess["canRetry"] as? Bool == true
        }
        return page
    }

    func perform(_ action: ThreatDeliveryAction, finding: ThreatDeliveryHistory.Finding? = nil,
                 attempt: ThreatDeliveryHistory.Attempt? = nil) async throws -> [ThreatDeliveryHistory.Attempt] {
        let page = try await load()
        let payload = try Self.actionPayload(action, page: page, finding: finding, attempt: attempt)
        let body = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        guard body.count <= Self.responseLimit else { throw ThreatDeliveryHistoryError.invalidResponse }
        let url = try apiURL(path: "dwm/webhook-deliveries")
        var request = makeRequest(url, method: "POST")
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await send(request) }
        catch { throw ThreatDeliveryHistoryError.uncertainResult }
        return try Self.validatedReceipts(data: data, response: response, action: action,
            organizationID: organizationID, alertID: finding?.id ?? attempt?.alertId, maximumBytes: Self.responseLimit)
    }

    static func actionPayload(_ action: ThreatDeliveryAction, page: ThreatDeliveryHistory,
                              finding: ThreatDeliveryHistory.Finding? = nil,
                              attempt: ThreatDeliveryHistory.Attempt? = nil) throws -> [String: Any] {
        guard ThreatDeliveryHistory.validID(page.organizationID) else { throw ThreatDeliveryHistoryError.actionUnavailable }
        var payload: [String: Any] = ["orgId": page.organizationID, "organizationId": page.organizationID, "tenantId": page.organizationID]
        switch action {
        case .test, .send:
            guard let finding, ThreatDeliveryHistory.actionAllowed(action, page: page, finding: finding),
                  let currentFinding = page.findings.first(where: { $0.id == finding.id }) else { throw ThreatDeliveryHistoryError.actionUnavailable }
            payload["alertId"] = currentFinding.id
            payload["alert"] = currentFinding.full
            payload["dryRun"] = action == .test
            payload["live"] = action == .send
        case .retry:
            guard let attempt, ThreatDeliveryHistory.actionAllowed(action, page: page, attempt: attempt) else { throw ThreatDeliveryHistoryError.actionUnavailable }
            payload["deliveryId"] = attempt.id
        }
        return payload
    }

    static func validatedReceipts(data: Data, response: URLResponse, action: ThreatDeliveryAction,
                                  organizationID: String, alertID: String?, maximumBytes: Int = 2_000_000) throws -> [ThreatDeliveryHistory.Attempt] {
        guard data.count <= maximumBytes, let http = response as? HTTPURLResponse,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawReceipts = root["deliveries"] as? [[String: Any]], rawReceipts.count <= 100 else {
            throw ThreatDeliveryHistoryError.uncertainResult
        }
        let receipts: [ThreatDeliveryHistory.Attempt]
        do { receipts = try rawReceipts.map { try JSONDecoder().decode(ThreatDeliveryHistory.Attempt.self, from: JSONSerialization.data(withJSONObject: $0)) } }
        catch { throw ThreatDeliveryHistoryError.uncertainResult }
        guard Set(receipts.map(\.id)).count == receipts.count,
              receipts.allSatisfy({ ThreatDeliveryHistory.validID($0.id) && ThreatDeliveryHistory.validID($0.orgId)
                && ThreatDeliveryHistory.validID($0.alertId) && $0.orgId == organizationID
                && $0.alertId == alertID && (action != .test || $0.dryRun) }) else {
            throw ThreatDeliveryHistoryError.uncertainResult
        }
        guard !receipts.isEmpty else {
            if http.statusCode >= 500 { throw ThreatDeliveryHistoryError.uncertainResult }
            throw ThreatDeliveryHistoryError.requestFailed(http.statusCode)
        }
        return receipts
    }

    private func findingsURL(cursor: String?) throws -> URL {
        let site = settings.websiteBaseURL.normalizedBaseURL
        var components = URLComponents(url: site.appendingAPIPath("api/findings/alerts"), resolvingAgainstBaseURL: false)!
        var query = [URLQueryItem(name: "tenantId", value: organizationID), URLQueryItem(name: "organizationId", value: organizationID), URLQueryItem(name: "limit", value: "50")]
        if let cursor { query.append(URLQueryItem(name: "cursor", value: cursor)) }
        components.queryItems = query
        guard let url = components.url, url.scheme == "https", url.host == site.host else { throw ThreatDeliveryHistoryError.invalidBaseURL }
        return url
    }

    private func apiURL(path: String, query: [URLQueryItem] = []) throws -> URL {
        var components = URLComponents(url: settings.apiBaseURL.normalizedBaseURL, resolvingAgainstBaseURL: false)!
        let prefix = components.percentEncodedPath.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.percentEncodedPath = "/" + [prefix, path].filter { !$0.isEmpty }.joined(separator: "/")
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, url.scheme == "https", url.host == URL(string: settings.apiBaseURL)!.host else { throw ThreatDeliveryHistoryError.invalidBaseURL }
        return url
    }

    private func request(_ url: URL) async throws -> (Data, URLResponse) {
        do { return try await send(makeRequest(url, method: "GET")) }
        catch { throw ThreatDeliveryHistoryError.requestFailed(0) }
    }
    private func makeRequest(_ url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.userID, forHTTPHeaderField: "id")
        return request
    }
    private func checked(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw ThreatDeliveryHistoryError.invalidResponse }
        return http
    }
    private func jsonObject(_ data: Data) throws -> [String: Any] {
        guard data.count <= Self.responseLimit, let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw ThreatDeliveryHistoryError.invalidResponse }
        return object
    }
    private static func ephemeralSender() throws -> (URLRequest) async throws -> (Data, URLResponse) {
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirectDelegate(), delegateQueue: nil)
        return { request in try await session.data(for: request) }
    }
    private struct Envelope: Decodable {
        struct Visibility: Decodable { let allowed: Bool }
        let deliveries: [ThreatDeliveryHistory.Attempt]
        let visibility: Visibility
    }
}

private final class NoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}

enum ThreatDeliveryAction: Equatable { case test, send, retry }

enum ThreatDeliveryHistoryError: LocalizedError, Equatable {
    case signInRequired, invalidCredentials, organizationRequired, impersonationUnsupported
    case invalidBaseURL, invalidResponse, organizationScopeChanged, actionUnavailable, uncertainResult
    case requestFailed(Int)
    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to review delivery history."
        case .invalidCredentials: "The signed-in session cannot be verified."
        case .organizationRequired: "Select an organization to review delivery history."
        case .impersonationUnsupported: "Return to your own account to review delivery history."
        case .invalidBaseURL: "Delivery history requires a secure API address."
        case .invalidResponse: "The delivery history response is invalid."
        case .organizationScopeChanged: "Delivery history did not match the selected organization. Refresh before continuing."
        case .actionUnavailable: "This delivery action is no longer available. Refresh and review the latest history."
        case .uncertainResult: "The delivery result is unknown. Refresh and review its history before any further action."
        case .requestFailed(let status) where status == 401: "Your session could not be verified. Sign in again."
        case .requestFailed(let status) where status == 403 || status == 404: "Delivery history is not available for this organization membership."
        case .requestFailed: "Delivery history is unavailable. Refresh to try again."
        }
    }
}
