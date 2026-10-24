import CoreFoundation
import Foundation

private final class BrowserUsageRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct BrowserUsageClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)
    static let defaultAPIBaseURL = URL(string: "https://browsers.hanasand.com/api")!
    static let responseByteLimit = 256 * 1_024

    private let url: URL
    private let userID: String
    private let token: String
    private let send: Sender

    static func loadGlobalStats(apiBaseURL: URL = defaultAPIBaseURL, send: Sender? = nil) async throws -> BrowserGlobalStats {
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw BrowserGlobalStatsError.invalidEndpoint
        }
        let url = apiBaseURL.appendingAPIPath("browser/stats")
        guard url.scheme?.lowercased() == "https", url.host == apiBaseURL.host,
              url.port == apiBaseURL.port, url.user == nil, url.password == nil else {
            throw BrowserGlobalStatsError.invalidEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let sender = send ?? Self.sendBoundedStatsRequest
        let (data, response) = try await sender(request)
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == url.host,
              (response.url?.port ?? 443) == (url.port ?? 443) else {
            throw BrowserGlobalStatsError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw BrowserGlobalStatsError.requestFailed(http.statusCode) }
        guard data.count <= Self.responseByteLimit else { throw BrowserGlobalStatsError.responseTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(root.keys) == Set(["runs24h", "darkweb_runs24h"]),
              let runs24h = Self.nonnegativeInteger(root["runs24h"]),
              let darkwebRuns24h = Self.nonnegativeInteger(root["darkweb_runs24h"]) else {
            throw BrowserGlobalStatsError.invalidResponse
        }
        return BrowserGlobalStats(runs24h: runs24h, darkwebRuns24h: darkwebRuns24h)
    }

    init(apiBaseURL: URL = defaultAPIBaseURL, userID: String, token: String, send: Sender? = nil) throws {
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw BrowserUsageError.invalidEndpoint
        }
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !credential.isEmpty else { throw BrowserUsageError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw BrowserUsageError.invalidCredentials
        }
        self.url = apiBaseURL.appendingAPIPath("browser/runs")
        self.userID = user
        self.token = credential
        self.send = send ?? Self.sendBoundedRequest
    }

    func load() async throws -> BrowserUsage {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == url.host,
              (response.url?.port ?? 443) == (url.port ?? 443) else {
            throw BrowserUsageError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw BrowserUsageError.requestFailed(http.statusCode) }
        guard data.count <= Self.responseByteLimit else { throw BrowserUsageError.responseTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let quota = root["quota"] as? [String: Any],
              let plan = quota["plan"] as? String, !plan.isEmpty, plan.utf8.count <= 80,
              let runsToday = Self.nonnegativeInteger(quota["used"]),
              let activeRuns = Self.nonnegativeInteger(quota["active"]),
              let dailyLimit = Self.optionalInteger(quota["limit"]),
              let concurrentLimit = Self.optionalInteger(quota["concurrentLimit"]),
              let paid = quota["paid"] as? Bool,
              let advancedAnalysis = quota["advancedAnalysis"] as? Bool,
              let sessionSeconds = Self.nonnegativeInteger(quota["sessionSeconds"]), sessionSeconds > 0 else {
            throw BrowserUsageError.invalidResponse
        }
        return BrowserUsage(plan: plan, runsToday: runsToday, activeRuns: activeRuns,
                            dailyLimit: dailyLimit, concurrentLimit: concurrentLimit,
                            paid: paid, advancedAnalysis: advancedAnalysis)
    }

    private static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.isFinite, double >= 0, double.rounded(.towardZero) == double,
              let integer = Int(exactly: double) else { return nil }
        return integer
    }

    private static func optionalInteger(_ value: Any?) -> Int?? {
        guard let value else { return nil }
        if value is NSNull { return .some(nil) }
        guard let integer = nonnegativeInteger(value) else { return nil }
        return .some(integer)
    }

    private static func sendBoundedRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: BrowserUsageRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        if let length = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > responseByteLimit {
            throw BrowserUsageError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(responseByteLimit, 64 * 1_024))
        for try await byte in bytes {
            guard data.count < responseByteLimit else { throw BrowserUsageError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }

    private static func sendBoundedStatsRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: BrowserUsageRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        if let length = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > responseByteLimit {
            throw BrowserGlobalStatsError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(responseByteLimit, 64 * 1_024))
        for try await byte in bytes {
            guard data.count < responseByteLimit else { throw BrowserGlobalStatsError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}
