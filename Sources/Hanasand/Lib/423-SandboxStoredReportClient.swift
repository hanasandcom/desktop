import Foundation

private final class SandboxStoredReportRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

struct SandboxStoredReportClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)
    static let defaultAPIBaseURL = URL(string: "https://browsers.hanasand.com/api")!

    private let apiBaseURL: URL
    private let userID: String
    private let authToken: String
    private let sender: Sender

    init(apiBaseURL: URL = defaultAPIBaseURL, userID: String = "", authToken: String = "",
         impersonationToken: String = "", impersonatingUserID: String = "", sender: Sender? = nil) throws {
        guard impersonationToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              impersonatingUserID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw SandboxStoredReportError.ownAccountRequired
        }
        guard apiBaseURL.scheme?.lowercased() == "https", apiBaseURL.host != nil,
              apiBaseURL.user == nil, apiBaseURL.password == nil,
              apiBaseURL.query == nil, apiBaseURL.fragment == nil else {
            throw SandboxStoredReportError.invalidBaseURL
        }
        self.apiBaseURL = apiBaseURL
        self.userID = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        self.authToken = authToken.trimmingCharacters(in: .whitespacesAndNewlines)
        self.sender = sender ?? Self.sendBounded
    }

    func load(resultID: String? = nil, runID: String? = nil, reportToken: String? = nil,
              selectedRunID: String? = nil) async throws -> SandboxStoredReport {
        let result = resultID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let run = runID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let selectedRun = selectedRunID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let token = reportToken?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard (!result.isEmpty && Self.validUUID(result) && run.isEmpty)
                || (result.isEmpty && Self.validIdentifier(run) && selectedRun.isEmpty) else {
            throw SandboxStoredReportError.invalidRoute
        }
        guard selectedRun.isEmpty || Self.validIdentifier(selectedRun) else { throw SandboxStoredReportError.invalidRoute }
        guard token.utf8.count <= 4096,
              token.isEmpty || token.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw SandboxStoredReportError.invalidRoute
        }
        if userID.isEmpty || authToken.isEmpty {
            guard !token.isEmpty, !run.isEmpty, result.isEmpty else { throw SandboxStoredReportError.signInRequired }
        }
        if !userID.isEmpty || !authToken.isEmpty {
            guard Self.validCredential(userID, max: 128), Self.validCredential(authToken, max: 4096) else {
                throw SandboxStoredReportError.invalidCredentials
            }
        }

        let route = result.isEmpty ? "browser/runs/\(run)/report" : "browser/results/\(result)"
        var components = URLComponents(url: apiBaseURL.appendingAPIPath(route), resolvingAgainstBaseURL: false)
        var query: [URLQueryItem] = []
        if !token.isEmpty { query.append(URLQueryItem(name: "token", value: token)) }
        if !result.isEmpty && !selectedRun.isEmpty { query.append(URLQueryItem(name: "run", value: selectedRun)) }
        components?.queryItems = query.isEmpty ? nil : query
        guard let url = components?.url, url.scheme?.lowercased() == "https",
              url.host == apiBaseURL.host, url.user == nil, url.password == nil, url.fragment == nil else {
            throw SandboxStoredReportError.invalidBaseURL
        }
        var request = URLRequest(url: url, timeoutInterval: 30)
        request.httpMethod = "GET"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if !userID.isEmpty && !authToken.isEmpty {
            request.setValue("Bearer \(authToken)", forHTTPHeaderField: "Authorization")
            request.setValue(userID, forHTTPHeaderField: "id")
        }

        let (data, response) = try await sender(request)
        guard let http = response as? HTTPURLResponse, let finalURL = response.url,
              finalURL.scheme?.lowercased() == "https", finalURL.host == apiBaseURL.host,
              finalURL.user == nil, finalURL.password == nil else { throw SandboxStoredReportError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw SandboxStoredReportError.requestFailed(http.statusCode) }
        if let length = http.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init), length > SandboxStoredReportLimits.responseBytes {
            throw SandboxStoredReportError.responseTooLarge
        }
        guard data.count <= SandboxStoredReportLimits.responseBytes,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw data.count > SandboxStoredReportLimits.responseBytes ? SandboxStoredReportError.responseTooLarge : SandboxStoredReportError.invalidResponse
        }
        return try Self.decode(root, fallbackID: result.isEmpty ? run : selectedRun.isEmpty ? run : selectedRun)
    }

    private static func decode(_ root: [String: Any], fallbackID: String) throws -> SandboxStoredReport {
        guard let target = root["target"] as? String, target.utf8.count <= SandboxStoredReportLimits.fieldBytes else {
            throw SandboxStoredReportError.invalidResponse
        }
        let analyst = root["analystReport"] as? [String: Any] ?? [:]
        let summary = root["analystSummary"] as? [String: Any] ?? [:]
        let status = root["status"] as? [String: Any] ?? [:]
        let allRuns = root["runs"] as? [[String: Any]] ?? []
        guard allRuns.count <= SandboxStoredReportLimits.maximumItems else { throw SandboxStoredReportError.invalidResponse }
        let runs = allRuns.compactMap { item -> SandboxStoredReportRun? in
            guard let id = item["id"] as? String, validIdentifier(id) else { return nil }
            let status = boundedString(item["status"])
            let startedAt = boundedString(item["startedAt"])
            return SandboxStoredReportRun(id: id, status: status, startedAt: startedAt)
        }
        let captures = root["captures"] as? [[String: Any]] ?? []
        let events = root["evidenceEvents"] as? [[String: Any]] ?? []
        let providers = analyst["providerReports"] as? [[String: Any]] ?? []
        let timeline = analyst["urlTimeline"] as? [[String: Any]] ?? summary["urlTimeline"] as? [[String: Any]] ?? []
        let network = analyst["networkEvidence"] as? [String: Any] ?? [:]
        let captureNetworkRows = captures.flatMap { capture in
            ((capture["networkSummary"] as? [String: Any])?["recentRequests"] as? [[String: Any]]) ?? []
        }
        let networkRows = (network["recentRequests"] as? [[String: Any]] ?? []) + captureNetworkRows
        let scripts = analyst["scriptArtifacts"] as? [[String: Any]] ?? []
        let associations = analyst["threatAssociations"] as? [[String: Any]] ?? summary["threatAssociations"] as? [[String: Any]] ?? []
        guard captures.count + events.count + providers.count + timeline.count + networkRows.count + scripts.count + associations.count <= SandboxStoredReportLimits.maximumItems else {
            throw SandboxStoredReportError.invalidResponse
        }
        return SandboxStoredReport(
            id: boundedString(root["runId"]).isEmpty ? fallbackID : boundedString(root["runId"]),
            target: target,
            finalURL: boundedString(root["finalUrl"]).isEmpty ? target : boundedString(root["finalUrl"]),
            status: boundedString(status["run"]),
            exportedAt: boundedString(root["exportedAt"]),
            verdict: boundedString(analyst["verdict"]),
            summary: boundedString(summary["narrative"]).isEmpty ? boundedString(analyst["markdown"]) : boundedString(summary["narrative"]),
            indicators: stringList(analyst["indicators"]),
            recommendedActions: stringList(analyst["recommendedActions"]),
            threatAssociations: associations.enumerated().map { index, item in
                SandboxStoredReportLine(id: "association-\(index)", title: joined(item, keys: ["name", "category", "confidence"]), detail: joined(item, keys: ["source", "evidence"]))
            },
            timeline: timeline.enumerated().map { index, item in
                SandboxStoredReportLine(id: "timeline-\(index)", title: joined(item, keys: ["capturedAt", "reason", "title"]), detail: boundedString(item["url"]))
            },
            providers: providers.enumerated().map { index, item in
                SandboxStoredReportLine(id: "provider-\(index)", title: joined(item, keys: ["tool", "status", "verdict"]), detail: joined(item, keys: ["error", "communitySummary"]))
            },
            evidence: (captures + events).enumerated().map { index, item in
                let title = joined(item, keys: ["kind", "type", "label", "title"])
                let evidence = item["evidence"] as? [String: Any] ?? [:]
                let detail = joined(item, keys: ["url", "reason", "text", "message", "verdict"])
                    + (boundedString(evidence["textExcerpt"]).isEmpty ? "" : " · " + boundedString(evidence["textExcerpt"]))
                return SandboxStoredReportLine(id: "evidence-\(index)", title: title.isEmpty ? "Evidence" : title, detail: detail)
            },
            captures: captures.enumerated().map { index, item in
                let evidence = item["evidence"] as? [String: Any] ?? [:]
                return SandboxStoredReportCapture(
                    id: "capture-\(index)",
                    title: joined(item, keys: ["label", "title", "kind"]),
                    url: boundedString(item["url"]),
                    capturedAt: boundedString(item["capturedAt"]),
                    reason: boundedString(item["reason"]),
                    imageDataURL: boundedImage(item["image"]),
                    textExcerpt: boundedString(evidence["textExcerpt"]),
                    sourceCode: boundedString(evidence["sourceCode"])
                )
            },
            networkEvidence: networkRows.enumerated().map { index, item in
                SandboxStoredReportLine(id: "network-\(index)", title: joined(item, keys: ["method", "status", "type"]), detail: joined(item, keys: ["url", "domain", "requestTime"]))
            },
            scriptArtifacts: scripts.enumerated().map { index, item in
                let indicators = item["indicators"] as? [String: Any] ?? [:]
                let values = ["domains", "ips", "urls"].flatMap { key in (indicators[key] as? [String] ?? []).prefix(20) }
                return SandboxStoredReportLine(id: "script-\(index)", title: joined(item, keys: ["assessment", "scriptId", "source", "sha256"]), detail: ([boundedString(item["summary"])] + values).filter { !$0.isEmpty }.joined(separator: " · "))
            },
            consoleEvents: (stringList(root["consoleEvents"]) + stringList(root["providerConsoleEvents"])).prefix(SandboxStoredReportLimits.maximumItems).map { $0 },
            availableRuns: runs
        )
    }

    private static func joined(_ object: [String: Any], keys: [String]) -> String {
        keys.map { boundedString(object[$0]) }.filter { !$0.isEmpty }.joined(separator: " · ")
    }

    private static func stringList(_ value: Any?) -> [String] {
        guard let values = value as? [Any], values.count <= SandboxStoredReportLimits.maximumItems else { return [] }
        return values.compactMap { item in
            guard let text = item as? String, text.utf8.count <= SandboxStoredReportLimits.fieldBytes else { return nil }
            return text
        }
    }

    private static func boundedString(_ value: Any?) -> String {
        guard let text = value as? String, text.utf8.count <= SandboxStoredReportLimits.fieldBytes else { return "" }
        return text
    }

    private static func boundedImage(_ value: Any?) -> String {
        guard let text = value as? String, text.utf8.count <= 8_000_000,
              ["data:image/png;", "data:image/jpeg;", "data:image/webp;"].contains(where: text.hasPrefix) else { return "" }
        return text
    }

    private static func validUUID(_ value: String) -> Bool {
        value.range(of: "^[a-fA-F0-9]{8}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{4}-[a-fA-F0-9]{12}$", options: .regularExpression) != nil
    }

    private static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= SandboxStoredReportLimits.idBytes && value.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil
    }

    private static func validCredential(_ value: String, max: Int) -> Bool {
        value.utf8.count <= max && value.range(of: "^[A-Za-z0-9._~-]{1,\(max)}$", options: .regularExpression) != nil
    }

    private static func sendBounded(_ request: URLRequest) async throws -> (Data, URLResponse) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let session = URLSession(configuration: configuration, delegate: SandboxStoredReportRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(for: request)
        if let length = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Length").flatMap(Int.init),
           length > SandboxStoredReportLimits.responseBytes { throw SandboxStoredReportError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(64 * 1024)
        for try await byte in bytes {
            guard data.count < SandboxStoredReportLimits.responseBytes else { throw SandboxStoredReportError.responseTooLarge }
            data.append(byte)
        }
        return (data, response)
    }
}
