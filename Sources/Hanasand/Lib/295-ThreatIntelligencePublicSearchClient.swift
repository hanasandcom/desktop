import Foundation

private final class ThreatIntelligencePublicSearchRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private enum ThreatIntelligencePublicSearchSession {
    static let redirectBlocker = ThreatIntelligencePublicSearchRedirectBlocker()
    static let shared: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: redirectBlocker, delegateQueue: nil)
    }()
}

enum ThreatIntelligencePublicSearchError: LocalizedError, Equatable {
    case invalidWebsiteURL
    case invalidQuery
    case invalidResponse
    case requestFailed(Int)

    var errorDescription: String? {
        switch self {
        case .invalidWebsiteURL: "Public threat intelligence requires a valid HTTPS website address."
        case .invalidQuery: "Enter a search between 2 and 200 characters."
        case .invalidResponse: "The public threat intelligence service returned an invalid response."
        case let .requestFailed(status): "Public threat intelligence search failed (HTTP \(status))."
        }
    }
}

struct ThreatIntelligencePublicSearchClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

    static let maximumResponseBytes = 2_000_000
    private let websiteBaseURL: URL
    private let send: Sender

    init(websiteBaseURL: URL, send: Sender? = nil) throws {
        guard Self.validWebsiteBase(websiteBaseURL) else { throw ThreatIntelligencePublicSearchError.invalidWebsiteURL }
        self.websiteBaseURL = websiteBaseURL
        self.send = send ?? { request in try await ThreatIntelligencePublicSearchSession.shared.data(for: request) }
    }

    func search(_ rawQuery: String, preferCached: Bool = true) async throws -> ThreatIntelSearchResult {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...200).contains(query.count) else { throw ThreatIntelligencePublicSearchError.invalidQuery }
        var components = URLComponents(url: websiteBaseURL, resolvingAgainstBaseURL: false)
        components?.path = "/api/ti/search"
        components?.queryItems = [
            URLQueryItem(name: "q", value: query),
            URLQueryItem(name: "cached", value: preferCached ? "true" : "false"),
        ]
        guard let url = components?.url, Self.sameOrigin(url, websiteBaseURL), url.path == "/api/ti/search" else {
            throw ThreatIntelligencePublicSearchError.invalidWebsiteURL
        }

        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")

        let (data, response) = try await send(request)
        guard data.count <= Self.maximumResponseBytes,
              let http = response as? HTTPURLResponse,
              let responseURL = http.url,
              Self.sameOrigin(responseURL, websiteBaseURL), responseURL.path == "/api/ti/search" else {
            throw ThreatIntelligencePublicSearchError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw ThreatIntelligencePublicSearchError.requestFailed(http.statusCode) }
        let projected = try Self.projectPublicPayload(data)
        let result: ThreatIntelSearchResult
        do { result = try JSONDecoder().decode(ThreatIntelSearchResult.self, from: projected) }
        catch { throw ThreatIntelligencePublicSearchError.invalidResponse }
        guard result.query.trimmingCharacters(in: .whitespacesAndNewlines).localizedCaseInsensitiveCompare(query) == .orderedSame,
              result.aliases.count <= 100, result.notes.count <= 100,
              result.candidates.count <= 100, result.sources.count <= 500,
              result.activity.count <= 500, result.techniques.count <= 500, result.targets.count <= 100 else {
            throw ThreatIntelligencePublicSearchError.invalidResponse
        }
        return result
    }

    private static func projectPublicPayload(_ data: Data) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ThreatIntelligencePublicSearchError.invalidResponse
        }
        var safe: [String: Any] = [:]
        for key in ["query", "status", "mode", "generatedAt", "refreshAfterSeconds", "confidence", "summary", "aliases", "notes", "targets", "ttps"] {
            if let value = root[key] { safe[key] = value }
        }
        if let rawSources = root["sources"] as? [[String: Any]] {
            safe["sources"] = rawSources.map { row in
                projected(row, keys: ["id", "name", "type", "provenance", "lastCollectedAt", "collectedAt", "url"])
            }
        }
        if let rawActivity = root["recentActivity"] as? [[String: Any]] {
            safe["recentActivity"] = rawActivity.map { row in
                projected(row, keys: ["title", "detail", "date", "sourceIds", "reviewState", "corroborationState", "url"])
            }
        }
        if let identity = root["actorIdentity"] as? [String: Any] {
            var safeIdentity = projected(identity, keys: ["catalogMatched", "activityEvidenceAvailable"])
            if let candidates = identity["candidates"] as? [[String: Any]] {
                safeIdentity["candidates"] = candidates.map { candidate in
                    projected(candidate, keys: ["canonicalName", "description", "associatedNames", "sourceUrl"])
                }
            }
            safe["actorIdentity"] = safeIdentity
        }
        return try JSONSerialization.data(withJSONObject: safe, options: [.fragmentsAllowed, .sortedKeys])
    }

    private static func projected(_ source: [String: Any], keys: [String]) -> [String: Any] {
        var result: [String: Any] = [:]
        for key in keys {
            guard let value = source[key] else { continue }
            if let text = value as? String {
                let safe = cleanPublicText(text)
                if !safe.isEmpty { result[key] = safe }
            } else if let values = value as? [String] {
                result[key] = values.map(cleanPublicText).filter { !$0.isEmpty }
            } else {
                result[key] = value
            }
        }
        return result
    }

    private static func cleanPublicText(_ value: String) -> String {
        String(value.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) })
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .prefix(10_000).description
    }

    private static func validWebsiteBase(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { return false }
        let domain = host == "hanasand.com" || host.hasSuffix(".hanasand.com")
        return domain && (url.path.isEmpty || url.path == "/")
    }

    private static func sameOrigin(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.scheme?.lowercased() == "https"
            && lhs.scheme?.lowercased() == rhs.scheme?.lowercased()
            && lhs.host?.lowercased() == rhs.host?.lowercased()
            && effectivePort(lhs) == effectivePort(rhs)
            && lhs.user == nil && lhs.password == nil
    }

    private static func effectivePort(_ url: URL) -> Int { url.port ?? 443 }
}
