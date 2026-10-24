import Foundation
import CoreFoundation

struct SandboxHistoryRun: Identifiable, Equatable {
    let id: String
    let resultID: String
    let target: String
    let network: String
    let status: String
    let startedAt: String
    let providerResults: [SandboxHistoryProviderResult]

    var displayTarget: String { target.isEmpty ? "Untitled target" : target }
}

struct SandboxHistoryProviderResult: Identifiable, Equatable {
    let id: String
    let status: String
    let label: String
}

struct SandboxHistoryPage: Equatable {
    let runs: [SandboxHistoryRun]
    let nextOffset: Int?
}

enum SandboxHistoryLimits {
    static let pageSize = 50
    static let responseBytes = 1 * 1024 * 1024
    static let reportResponseBytes = 1 * 1024 * 1024
    static let maximumReportEntries = 500
    static let reportTextLength = 8_000
    static let maximumPages = 200
    static let identifierLength = 128
    static let targetLength = 2_000
    static let fieldLength = 100
    static let maximumProviderResults = 16
    static let providerLabelLength = 160
}

enum SandboxHistoryError: LocalizedError, Equatable {
    case signInRequired
    case ownAccountRequired
    case invalidBaseURL
    case invalidCredentials
    case invalidOffset
    case invalidResponse
    case responseTooLarge
    case redirectRejected
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .signInRequired: "Sign in to view saved Sandbox runs."
        case .ownAccountRequired: "Return to your own account to view saved Sandbox runs."
        case .invalidBaseURL: "Saved Sandbox runs require a valid HTTPS API address."
        case .invalidCredentials: "The current account credentials are invalid. Sign in again."
        case .invalidOffset: "The Sandbox history page could not be loaded. Refresh and try again."
        case .invalidResponse: "The Sandbox history service returned an invalid response."
        case .responseTooLarge: "The Sandbox history response exceeded its size limit."
        case .redirectRejected: "The Sandbox report redirected to an unexpected address."
        case .requestFailed(401): "Sign in again to view saved Sandbox runs."
        case .requestFailed(403): "Current account does not have access to these Sandbox runs."
        case .requestFailed: "Saved Sandbox runs are unavailable. Refresh to try again."
        }
    }
}

struct SandboxHistoryReport: Equatable {
    let target: String
    let entries: [SandboxHistoryReportEntry]
}

struct SandboxHistoryReportEntry: Equatable {
    let kind: String
    let title: String
    let url: String
    let detail: String
}

struct SandboxHistoryReportClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)
    static let defaultAPIBaseURL = URL(string: "https://browsers.hanasand.com/api")!
    private let baseURL: URL
    private let userID: String
    private let token: String
    private let send: Sender

    init(apiBaseURL: URL = defaultAPIBaseURL, userID: String, token: String,
         impersonationToken: String = "", impersonatingUserID: String = "", send: Sender? = nil) throws {
        guard impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SandboxHistoryError.ownAccountRequired
        }
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil, apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw SandboxHistoryError.invalidBaseURL
        }
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw SandboxHistoryError.invalidCredentials
        }
        self.baseURL = apiBaseURL
        self.userID = user
        self.token = credential
        self.send = send ?? Self.sendBoundedRequest
    }

    func loadReport(resultID: String) async throws -> SandboxHistoryReport {
        guard resultID.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil else {
            throw SandboxHistoryError.invalidResponse
        }
        let components = URLComponents(url: baseURL.appendingAPIPath("browser/results/\(resultID)"), resolvingAgainstBaseURL: false)
        guard let url = components?.url, url.scheme?.lowercased() == "https", url.host == baseURL.host,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw SandboxHistoryError.invalidBaseURL
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")

        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == baseURL.host else {
            throw SandboxHistoryError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw SandboxHistoryError.requestFailed(http.statusCode) }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > SandboxHistoryLimits.reportResponseBytes {
            throw SandboxHistoryError.responseTooLarge
        }
        guard data.count <= SandboxHistoryLimits.reportResponseBytes else { throw SandboxHistoryError.responseTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let target = root["target"] as? String, target.utf8.count <= SandboxHistoryLimits.targetLength,
              let captures = root["captures"] as? [Any], let events = root["evidenceEvents"] as? [Any] else {
            throw SandboxHistoryError.invalidResponse
        }
        let rawEntries = captures + events
        guard rawEntries.count <= SandboxHistoryLimits.maximumReportEntries else { throw SandboxHistoryError.invalidResponse }
        let entries = try rawEntries.map { value -> SandboxHistoryReportEntry in
            guard let item = value as? [String: Any] else { throw SandboxHistoryError.invalidResponse }
            func bounded(_ key: String) -> String {
                guard let value = item[key] as? String, value.utf8.count <= SandboxHistoryLimits.reportTextLength else { return "" }
                return value
            }
            for key in ["type", "title", "url", "text", "message"] where item[key] != nil {
                guard item[key] is String, bounded(key).utf8.count <= SandboxHistoryLimits.reportTextLength else {
                    throw SandboxHistoryError.invalidResponse
                }
            }
            return SandboxHistoryReportEntry(kind: bounded("type").isEmpty ? "Evidence" : bounded("type"),
                                             title: bounded("title"), url: bounded("url"),
                                             detail: bounded("text").isEmpty ? bounded("message") : bounded("text"))
        }
        return SandboxHistoryReport(target: target, entries: entries)
    }

    private static func sendBoundedRequest(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let blocker = SandboxHistoryRedirectBlocker()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: blocker, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        if let length = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > SandboxHistoryLimits.reportResponseBytes { throw SandboxHistoryError.responseTooLarge }
        var data = Data()
        for try await byte in bytes {
            guard data.count < SandboxHistoryLimits.reportResponseBytes else { throw SandboxHistoryError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}

private final class SandboxHistoryRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
