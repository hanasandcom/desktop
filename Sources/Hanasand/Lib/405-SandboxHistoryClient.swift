import CoreFoundation
import Foundation

private final class SandboxHistoryRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum SandboxHistorySession {
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: SandboxHistoryRedirectBlocker(), delegateQueue: nil)
    }()

    static func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await shared.bytes(for: request)
        if let http = response as? HTTPURLResponse,
           let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > SandboxHistoryLimits.responseBytes {
            throw SandboxHistoryError.responseTooLarge
        }
        var data = Data()
        data.reserveCapacity(min(SandboxHistoryLimits.responseBytes, 64 * 1024))
        for try await byte in bytes {
            guard data.count < SandboxHistoryLimits.responseBytes else { throw SandboxHistoryError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}

struct SandboxHistoryClient {
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
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw SandboxHistoryError.invalidBaseURL
        }
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let credential = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !credential.isEmpty else { throw SandboxHistoryError.signInRequired }
        guard user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              credential.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw SandboxHistoryError.invalidCredentials
        }
        self.baseURL = apiBaseURL
        self.userID = user
        self.token = credential
        self.send = send ?? SandboxHistorySession.send
    }

    func loadPage(offset: Int = 0) async throws -> SandboxHistoryPage {
        guard offset >= 0, offset.isMultiple(of: SandboxHistoryLimits.pageSize),
              offset <= SandboxHistoryLimits.pageSize * SandboxHistoryLimits.maximumPages else {
            throw SandboxHistoryError.invalidOffset
        }
        var components = URLComponents(url: baseURL.appendingAPIPath("browser/runs"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "history", value: "all"), URLQueryItem(name: "offset", value: String(offset))]
        guard let url = components?.url else { throw SandboxHistoryError.invalidBaseURL }
        guard url.scheme?.lowercased() == "https", url.host == baseURL.host, url.user == nil, url.password == nil else {
            throw SandboxHistoryError.invalidBaseURL
        }
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
              response.url?.scheme?.lowercased() == "https", response.url?.host == baseURL.host else {
            throw SandboxHistoryError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw SandboxHistoryError.requestFailed(http.statusCode) }
        guard data.count <= SandboxHistoryLimits.responseBytes else { throw SandboxHistoryError.responseTooLarge }
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rawRuns = root["runs"] as? [Any], rawRuns.count <= SandboxHistoryLimits.pageSize else {
            throw SandboxHistoryError.invalidResponse
        }

        var runs: [SandboxHistoryRun] = []
        var seen = Set<String>()
        for row in rawRuns {
            guard let object = row as? [String: Any],
                  let run = Self.decodeRun(object), seen.insert(run.id).inserted else { continue }
            runs.append(run)
        }
        let nextOffset: Int?
        if root["nextOffset"] is NSNull || root["nextOffset"] == nil {
            nextOffset = nil
        } else if let number = root["nextOffset"] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  Double(number.intValue) == number.doubleValue,
                  number.intValue == offset + SandboxHistoryLimits.pageSize,
                  number.intValue <= SandboxHistoryLimits.pageSize * SandboxHistoryLimits.maximumPages,
                  number.intValue.isMultiple(of: SandboxHistoryLimits.pageSize) {
            nextOffset = number.intValue
        } else {
            throw SandboxHistoryError.invalidResponse
        }
        return SandboxHistoryPage(runs: runs, nextOffset: nextOffset)
    }

    private static func decodeRun(_ object: [String: Any]) -> SandboxHistoryRun? {
        guard let id = object["id"] as? String,
              let resultID = object["resultId"] as? String,
              let target = object["target"] as? String,
              let network = object["network"] as? String,
              let status = object["status"] as? String,
              let startedAt = object["startedAt"] as? String,
              validIdentifier(id), validIdentifier(resultID),
              target.utf8.count <= SandboxHistoryLimits.targetLength,
              network.utf8.count <= SandboxHistoryLimits.fieldLength,
              status.utf8.count <= SandboxHistoryLimits.fieldLength,
              startedAt.utf8.count <= SandboxHistoryLimits.fieldLength else { return nil }
        return SandboxHistoryRun(id: id, resultID: resultID, target: target, network: network, status: status, startedAt: startedAt)
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= SandboxHistoryLimits.identifierLength
            && value.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil
    }
}
