import Foundation

struct CasesWorkspaceClient {
    private let settings: HanasandDesktopSettings
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(settings: HanasandDesktopSettings, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        guard !settings.userID.isEmpty, !settings.authToken.isEmpty else { throw CasesWorkspaceError.signInRequired }
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else {
            throw CasesWorkspaceError.impersonationUnsupported
        }
        guard settings.userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              settings.authToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil,
              let base = URL(string: settings.websiteBaseURL), base.scheme?.lowercased() == "https",
              base.host != nil, base.user == nil, base.password == nil, base.query == nil, base.fragment == nil else {
            throw CasesWorkspaceError.invalidEndpoint
        }
        self.settings = settings
        if let send { self.send = send }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: CasesWorkspaceRedirectBlocker(), delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    func loadMonitoringCases() async throws -> [MonitoringCase] {
        let data = try await request(path: "cases/monitoring", query: [URLQueryItem(name: "view", value: "summary")])
        let result: MonitoringCaseList
        do { result = try JSONDecoder().decode(MonitoringCaseList.self, from: data) }
        catch { throw CasesWorkspaceError.invalidResponse }
        guard result.items.count <= 10_000, Set(result.items.map(\.id)).count == result.items.count else {
            throw CasesWorkspaceError.invalidResponse
        }
        return result.items
    }

    func create(title: String, summary: String, severity: String, idempotencyKey: String) async throws -> String {
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let cleanSummary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanTitle.isEmpty, cleanTitle.utf8.count <= 200, cleanSummary.utf8.count <= 5_000,
              ["low", "medium", "high", "critical"].contains(severity),
              idempotencyKey.range(of: "^[A-Fa-f0-9-]{36}$", options: .regularExpression) != nil else {
            throw CasesWorkspaceError.invalidInput
        }
        var body: [String: Any] = [
            "sourceType": "manual", "title": cleanTitle, "summary": cleanSummary,
            "priority": severity, "idempotencyKey": idempotencyKey,
        ]
        var query: [URLQueryItem] = []
        if let organizationID { body["organizationId"] = organizationID; query.append(URLQueryItem(name: "organizationId", value: organizationID)) }
        let payload = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        let data = try await request(path: "v1/cases", method: "POST", query: query, body: payload, service: .threatIntelligence)
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let record = object["case"] as? [String: Any], let id = record["id"] as? String,
              IntelligenceCasesClient.validCaseID(id) else { throw CasesWorkspaceError.invalidResponse }
        return id
    }

    func merge(targetID: String, sourceIDs: [String]) async throws {
        let distinctSources = Array(Set(sourceIDs)).sorted()
        guard targetID.range(of: "^(HA|MON)-[1-9][0-9]*$", options: .regularExpression) != nil,
              !distinctSources.isEmpty, distinctSources.count <= 50,
              distinctSources.allSatisfy({ $0.range(of: "^(HA|MON)-[1-9][0-9]*$", options: .regularExpression) != nil && $0 != targetID }) else {
            throw CasesWorkspaceError.invalidInput
        }
        var query: [URLQueryItem] = []
        if let organizationID { query.append(URLQueryItem(name: "organizationId", value: organizationID)) }
        let body = try JSONSerialization.data(withJSONObject: ["targetId": targetID, "sourceIds": distinctSources], options: [.sortedKeys])
        _ = try await request(path: "cases/monitoring/merge", method: "POST", query: query, body: body)
    }

    private var organizationID: String? {
        let value = settings.selectedOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "personal" ? nil : value
    }

    private enum Service: Equatable { case api, threatIntelligence }

    private func request(path: String, method: String = "GET", query: [URLQueryItem] = [], body: Data? = nil,
                        service: Service = .api) async throws -> Data {
        guard let base = URL(string: settings.websiteBaseURL), base.scheme?.lowercased() == "https",
              let host = base.host?.lowercased() else { throw CasesWorkspaceError.invalidEndpoint }
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanPath.isEmpty, !cleanPath.contains(".."), cleanPath.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil else {
            throw CasesWorkspaceError.invalidEndpoint
        }
        let baseURL: URL
        if service == .threatIntelligence && host == "hanasand.com" {
            guard let tiURL = URL(string: "https://ti.hanasand.com") else { throw CasesWorkspaceError.invalidEndpoint }
            baseURL = tiURL.appendingAPIPath(cleanPath)
        } else {
            baseURL = settings.apiBaseURL.normalizedBaseURL.appendingAPIPath(cleanPath)
        }
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw CasesWorkspaceError.invalidEndpoint
        }
        components.queryItems = query.isEmpty ? nil : query
        components.fragment = nil
        guard let url = components.url, url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw CasesWorkspaceError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 25
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.userID, forHTTPHeaderField: "id")
        if let body { request.httpBody = body; request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let (data, response): (Data, URLResponse)
        do { (data, response) = try await send(request) }
        catch { throw CasesWorkspaceError.transport }
        guard let http = response as? HTTPURLResponse, http.url == url else { throw CasesWorkspaceError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw CasesWorkspaceError.requestFailed(http.statusCode) }
        guard data.count <= 8 * 1024 * 1024 else { throw CasesWorkspaceError.invalidResponse }
        return data
    }
}

enum CasesWorkspaceError: LocalizedError, Equatable {
    case signInRequired, impersonationUnsupported, invalidEndpoint, invalidResponse, invalidInput, transport
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view cases."
        case .impersonationUnsupported: "Return to your own account to manage cases."
        case .invalidEndpoint: "Cases require a secure Hanasand service address."
        case .invalidResponse: "The cases service returned data that could not be verified. Refresh and review."
        case .invalidInput: "Review the case details and selected monitoring cases, then try again."
        case .transport: "The case request did not complete. Refresh to check its outcome before retrying."
        case .requestFailed(401): "Sign in again to access cases."
        case .requestFailed(403): "Current organization access could not be verified."
        case .requestFailed(let status): "The case request failed (HTTP \(status))."
        }
    }
}

private final class CasesWorkspaceRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
