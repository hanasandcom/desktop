import Foundation
import CoreFoundation

private final class DashboardOverviewRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct DashboardMonitoringOverviewClient {
    private let settings: HanasandDesktopSettings
    private let send: (URLRequest) async throws -> (Data, URLResponse)

    init(settings: HanasandDesktopSettings, send: ((URLRequest) async throws -> (Data, URLResponse))? = nil) throws {
        guard !settings.userID.isEmpty, !settings.authToken.isEmpty else { throw DashboardMonitoringOverviewError.signInRequired }
        guard settings.userID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              settings.authToken.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw DashboardMonitoringOverviewError.invalidCredentials
        }
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else {
            throw DashboardMonitoringOverviewError.impersonationUnsupported
        }
        let organizationID = settings.selectedOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !organizationID.isEmpty, organizationID != "personal", settings.selectedOrganizationUserID != settings.userID {
            throw DashboardMonitoringOverviewError.scopeChanged
        }
        guard Self.validHTTPS(settings.websiteBaseURL.normalizedBaseURL) else { throw DashboardMonitoringOverviewError.invalidEndpoint }
        self.settings = settings
        if let send { self.send = send }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpShouldSetCookies = false
            configuration.httpCookieStorage = nil
            configuration.urlCache = nil
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            let session = URLSession(configuration: configuration, delegate: DashboardOverviewRedirectBlocker(), delegateQueue: nil)
            self.send = { request in try await session.data(for: request) }
        }
    }

    func load() async throws -> DashboardMonitoringOverview {
        let organizationID = currentOrganizationID
        var query: [URLQueryItem] = []
        if let organizationID { query.append(URLQueryItem(name: "organizationId", value: organizationID)) }
        let request = try makeRequest(path: "api/findings/product", query: query)
        let (data, _) = try await perform(request)
        let snapshot: DashboardMonitoringOverview
        do { snapshot = try JSONDecoder().decode(DashboardMonitoringOverview.self, from: data) }
        catch { throw DashboardMonitoringOverviewError.invalidResponse }
        guard snapshot.schemaVersion == "dwm.product.v1", !snapshot.tenantId.isEmpty,
              organizationID.map({ snapshot.tenantId == $0 }) ?? (snapshot.tenantId == settings.userID) else {
            throw DashboardMonitoringOverviewError.invalidResponse
        }
        guard settings.selectedOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines) == (organizationID ?? "") else {
            throw DashboardMonitoringOverviewError.scopeChanged
        }
        return snapshot
    }

    func loadOpenCaseCount() async -> Result<Int, DashboardMonitoringOverviewError> {
        do {
            var query = [URLQueryItem(name: "summary", value: "true"), URLQueryItem(name: "openOnly", value: "true")]
            if let organizationID = currentOrganizationID { query.append(URLQueryItem(name: "organizationId", value: organizationID)) }
            let request = try makeRequest(path: "api/cases", query: query)
            let (data, _) = try await perform(request)
            guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let total = payload["total"] as? NSNumber,
                  CFGetTypeID(total) != CFBooleanGetTypeID(), total.doubleValue.isFinite,
                  total.doubleValue >= 0, total.doubleValue <= Double(Int.max),
                  total.doubleValue.rounded(.towardZero) == total.doubleValue else {
                throw DashboardMonitoringOverviewError.invalidResponse
            }
            return .success(total.intValue)
        } catch let error as DashboardMonitoringOverviewError { return .failure(error) }
        catch { return .failure(.invalidResponse) }
    }

    private var currentOrganizationID: String? {
        let value = settings.selectedOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty || value == "personal" ? nil : value
    }

    private func makeRequest(path: String, query: [URLQueryItem]) throws -> URLRequest {
        let cleanPath = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !cleanPath.isEmpty, !cleanPath.contains(".."), cleanPath.range(of: "^[A-Za-z0-9._/-]+$", options: .regularExpression) != nil else {
            throw DashboardMonitoringOverviewError.invalidEndpoint
        }
        let base = settings.websiteBaseURL.normalizedBaseURL
        guard var components = URLComponents(url: base.appendingAPIPath(cleanPath), resolvingAgainstBaseURL: false) else {
            throw DashboardMonitoringOverviewError.invalidEndpoint
        }
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, Self.validRequestURL(url) else { throw DashboardMonitoringOverviewError.invalidEndpoint }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(settings.authToken)", forHTTPHeaderField: "Authorization")
        request.setValue(settings.userID, forHTTPHeaderField: "id")
        return request
    }

    private func perform(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let data: Data
        let response: URLResponse
        do { (data, response) = try await send(request) }
        catch { throw DashboardMonitoringOverviewError.invalidResponse }
        guard let http = response as? HTTPURLResponse, http.url == request.url, data.count <= 8 * 1024 * 1024 else {
            throw DashboardMonitoringOverviewError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw DashboardMonitoringOverviewError.requestFailed(http.statusCode) }
        return (data, http)
    }

    private static func validHTTPS(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    private static func validRequestURL(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.fragment == nil
    }
}
