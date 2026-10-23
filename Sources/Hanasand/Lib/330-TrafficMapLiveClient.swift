import Foundation

enum TrafficMapLiveClient {
    static func requestURL(apiBaseURL: URL, domain: String, after: String?) throws -> URL {
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw TrafficMapLiveError.invalidEndpoint
        }
        guard domain.count <= 253,
              !domain.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.contains($0) || $0.value == 127 }),
              !domain.contains(where: { "/?#\\".contains($0) }) else {
            throw TrafficMapLiveError.invalidRequest
        }
        if let after {
            guard after.range(of: "^[1-9][0-9]{0,15}$", options: .regularExpression) != nil,
                  let value = UInt64(after), value <= 9_007_199_254_740_991 else {
                throw TrafficMapLiveError.invalidRequest
            }
        }
        var components = URLComponents(url: apiBaseURL.appendingAPIPath("traffic/live"), resolvingAgainstBaseURL: false)
        var query: [URLQueryItem] = []
        if !domain.isEmpty { query.append(URLQueryItem(name: "domain", value: domain)) }
        if let after { query.append(URLQueryItem(name: "after", value: after)) }
        if !query.isEmpty { components?.queryItems = query }
        guard let url = components?.url, url.host == apiBaseURL.host, url.scheme == "https" else {
            throw TrafficMapLiveError.invalidEndpoint
        }
        return url
    }

    static func request(apiBaseURL: URL, userID: String, authToken: String, impersonationToken: String = "", domain: String, after: String?) throws -> URLRequest {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !token.isEmpty else { throw TrafficMapLiveError.signInRequired }
        let url = try requestURL(apiBaseURL: apiBaseURL, domain: domain, after: after)
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(user, forHTTPHeaderField: "id")
        let impersonation = impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines)
        if !impersonation.isEmpty {
            request.setValue(impersonation, forHTTPHeaderField: "x-impersonation-token")
        }
        return request
    }

    static func decodeBatch(_ data: Data, after: String = "0") throws -> [TrafficMapLiveBatch] {
        guard after.range(of: "^(0|[1-9][0-9]{0,15})$", options: .regularExpression) != nil,
              let cursor = UInt64(after), cursor <= 9_007_199_254_740_991 else {
            throw TrafficMapLiveError.invalidRequest
        }
        let batches: [TrafficMapLiveBatch]
        do { batches = try JSONDecoder().decode([TrafficMapLiveBatch].self, from: data) }
        catch { throw TrafficMapLiveError.invalidEvent }
        guard batches.count <= 250, Set(batches.map(\.iso)).count == batches.count else {
            throw TrafficMapLiveError.invalidEvent
        }
        for batch in batches { try batch.validate() }
        guard batches.reduce(0, { $0 + $1.count }) <= 1000 else {
            throw TrafficMapLiveError.invalidEvent
        }
        return batches.filter { (UInt64($0.maxID) ?? 0) > cursor }
    }

    static func isValidTimestamp(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 100 else { return false }
        var timestamp = value.replacingOccurrences(of: " ", with: "T", range: value.range(of: " "))
        if let range = timestamp.range(of: "[+-][0-9]{2}$", options: .regularExpression) {
            timestamp.replaceSubrange(range, with: String(timestamp[range]) + ":00")
        }
        guard timestamp.range(of: "(?:Z|[+-][0-9]{2}:[0-9]{2})$", options: [.regularExpression, .caseInsensitive]) != nil else {
            return false
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: timestamp) != nil || {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: timestamp) != nil
        }()
    }

    @MainActor
    static func listen(
        request: URLRequest,
        expectedHost: String,
        afterCursor: String,
        onReady: @MainActor () -> Void,
        onBatch: @MainActor ([TrafficMapLiveBatch]) -> Void
    ) async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 60
        let session = URLSession(configuration: configuration, delegate: TrafficMapLiveRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }

        let (bytes, response): (URLSession.AsyncBytes, URLResponse)
        do { (bytes, response) = try await session.bytes(for: request) }
        catch is CancellationError { throw CancellationError() }
        catch { throw TrafficMapLiveError.disconnected }
        guard let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == "https", response.url?.host == expectedHost else {
            throw TrafficMapLiveError.invalidEvent
        }
        guard (200..<300).contains(http.statusCode) else {
            if http.statusCode == 401 { throw TrafficMapLiveError.unauthorized }
            if http.statusCode == 403 { throw TrafficMapLiveError.forbidden }
            throw TrafficMapLiveError.requestFailed(http.statusCode)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.lowercased().hasPrefix("text/event-stream") == true else {
            throw TrafficMapLiveError.invalidEvent
        }

        var event = "message"
        var dataLines: [String] = []
        var eventSize = 0
        guard let initialCursor = UInt64(afterCursor), initialCursor <= 9_007_199_254_740_991 else {
            throw TrafficMapLiveError.invalidRequest
        }
        var cursor = initialCursor
        let readyDecoder = JSONDecoder()
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.utf8.count <= 32_768 else { throw TrafficMapLiveError.invalidEvent }
            if line.isEmpty {
                if !dataLines.isEmpty {
                    let payload = Data(dataLines.joined(separator: "\n").utf8)
                    guard payload.count <= 65_536 else { throw TrafficMapLiveError.invalidEvent }
                    switch event {
                    case "ready":
                        guard let value = try? readyDecoder.decode(TrafficMapLiveReady.self, from: payload), value.status == "connected" else {
                            throw TrafficMapLiveError.invalidEvent
                        }
                        onReady()
                    case "traffic":
                        let batches = try decodeBatch(payload, after: String(cursor))
                        if !batches.isEmpty {
                            cursor = max(cursor, batches.compactMap { UInt64($0.maxID) }.max() ?? cursor)
                            onBatch(batches)
                        }
                    case "traffic-error":
                        throw TrafficMapLiveError.serverError
                    default:
                        break
                    }
                }
                event = "message"
                dataLines.removeAll(keepingCapacity: true)
                eventSize = 0
                continue
            }
            if line.hasPrefix(":") { continue }
            let separator = line.firstIndex(of: ":")
            let field = separator.map { String(line[..<$0]) } ?? line
            var value = separator.map { String(line[line.index(after: $0)...]) } ?? ""
            if value.first == " " { value.removeFirst() }
            switch field {
            case "event":
                guard value.count <= 100 else { throw TrafficMapLiveError.invalidEvent }
                event = value
            case "data":
                eventSize += value.utf8.count + 1
                guard eventSize <= 65_536 else { throw TrafficMapLiveError.invalidEvent }
                dataLines.append(value)
            default:
                continue
            }
        }
        try Task.checkCancellation()
        throw TrafficMapLiveError.disconnected
    }
}

private struct TrafficMapLiveReady: Decodable {
    let status: String
}

private final class TrafficMapLiveRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession, task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}
