import Foundation

private final class NativeDomainMonitorRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

struct NativeDomainMonitorClient {
    private struct TrafficDomain {
        let domain: String
        let today: Int?
        let week: Int?
        let month: Int?
        let total: Int?
    }

    private struct Capture {
        let tenantID: String
        let domain: String
        let sourceID: String
        let sourceName: String
        let observedAt: String
        let publishedAt: String
        let monitoredSince: String
    }

    private struct Source {
        let tenantID: String
        let id: String
        let name: String
    }

    private struct Resource<Value> {
        let value: Value?
        let state: NativeDomainMonitorSnapshot.ResourceState
    }

    private let settings: HanasandDesktopSettings
    private let session: URLSession

    init(settings: HanasandDesktopSettings) {
        self.settings = settings
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration, delegate: NativeDomainMonitorRedirectBlocker(), delegateQueue: nil)
    }

    func loadSnapshot() async -> NativeDomainMonitorSnapshot {
        async let trafficSummary = loadTrafficSummary()
        async let trafficMetrics = loadTrafficMetrics()
        async let captures = loadCaptures()
        async let sourceOperations = loadSourceOperations()
        let (summary, metrics, captureResult, sourceResult) = await (trafficSummary, trafficMetrics, captures, sourceOperations)

        let traffic = Dictionary(uniqueKeysWithValues: (summary.value ?? []).map { ($0.domain, $0) })
        let topDomains = metrics.value ?? []
        let groupedCaptures = Dictionary(grouping: captureResult.value ?? [], by: \.domain)
        let sourceNames = Dictionary(uniqueKeysWithValues: (sourceResult.value ?? []).map { ($0.id, $0.name) })
        let domains = Set(traffic.keys)
            .union(topDomains.map(\.domain))
            .union(groupedCaptures.keys)
            .filter(Self.isMonitorDomain)
            .sorted()

        let rows = domains.map { domain -> NativeDomainMonitorRow in
            let domainCaptures = groupedCaptures[domain] ?? []
            let topCount = topDomains.first(where: { $0.domain == domain })?.count
            let trafficRow = traffic[domain]
            let seenTimes = domainCaptures.map(\.observedAt).filter { !$0.isEmpty }.sorted()
            let monitoredDates = domainCaptures.map(\.monitoredSince).filter { !$0.isEmpty }.sorted()
            let sourceIDs = Set(domainCaptures.map(\.sourceID))
            let sourceLabels = sourceResult.value.map { _ in
                sourceIDs.compactMap { sourceNames[$0] }.sorted()
            }
            let capturesWereLoaded = captureResult.value != nil
            return NativeDomainMonitorRow(
                domain: domain,
                customer: nil,
                status: capturesWereLoaded && !domainCaptures.isEmpty ? "Review (inferred)" : nil,
                monitoredSince: capturesWereLoaded ? monitoredDates.first : nil,
                lastSeenAt: capturesWereLoaded ? seenTimes.last : nil,
                breachMentions: capturesWereLoaded ? domainCaptures.count : nil,
                matchedTerms: [domain],
                sources: sourceLabels,
                requestsToday: summary.value.map { _ in trafficRow?.today ?? 0 },
                requestsThisWeek: summary.value.map { _ in trafficRow?.week ?? 0 },
                requestsThisMonth: summary.value.map { _ in trafficRow?.month ?? 0 },
                requestsTotal: summary.value.map { _ in trafficRow?.total ?? topCount ?? 0 } ?? topCount
            )
        }

        return NativeDomainMonitorSnapshot(
            rows: rows,
            trafficSummary: summary.state,
            trafficMetrics: metrics.state,
            captures: captureResult.state,
            sourceOperations: sourceResult.state
        )
    }

    private func loadTrafficSummary() async -> Resource<[TrafficDomain]> {
        do {
            let url = try endpoint(base: settings.cdnBaseURL, path: "traffic/summary", query: [URLQueryItem(name: "metric", value: "domain")])
            let payload = try await get(url, authenticated: true, maxBytes: 4_000_000)
            guard let values = payload as? [[String: Any]] else { throw ClientError.invalidResponse }
            let rows = values.compactMap { value -> TrafficDomain? in
                guard let domain = value["value"] as? String, Self.isMonitorDomain(domain) else { return nil }
                return TrafficDomain(
                    domain: domain.lowercased(),
                    today: Self.integer(value["hits_today"]),
                    week: Self.integer(value["hits_last_week"]),
                    month: Self.integer(value["hits_this_month"]),
                    total: Self.integer(value["hits_total"])
                )
            }
            return Resource(value: rows, state: .init(title: "Traffic domain summary", detail: "Loaded \(rows.count) domain rows.", available: true))
        } catch {
            return Resource(value: nil, state: .init(title: "Traffic domain summary", detail: error.localizedDescription, available: false))
        }
    }

    private func loadTrafficMetrics() async -> Resource<[(domain: String, count: Int)]> {
        do {
            let url = try endpoint(base: settings.cdnBaseURL, path: "traffic/metrics", query: [])
            let payload = try await get(url, authenticated: true, maxBytes: 4_000_000)
            guard let object = payload as? [String: Any],
                  let values = object["top_domains"] as? [[String: Any]] else { throw ClientError.invalidResponse }
            let rows = values.compactMap { value -> (domain: String, count: Int)? in
                guard let domain = value["key"] as? String, Self.isMonitorDomain(domain),
                      let count = Self.integer(value["count"]) else { return nil }
                return (domain.lowercased(), count)
            }
            return Resource(value: rows, state: .init(title: "Traffic metric totals", detail: "Loaded \(rows.count) top domains.", available: true))
        } catch {
            return Resource(value: nil, state: .init(title: "Traffic metric totals", detail: error.localizedDescription, available: false))
        }
    }

    private func loadCaptures() async -> Resource<[Capture]> {
        do {
            let tenantID = try selectedTenantID()
            let url = try intelligenceEndpoint(path: "v1/intel/captures", query: [
                URLQueryItem(name: "limit", value: "50"), URLQueryItem(name: "page", value: "1"), URLQueryItem(name: "tenantId", value: tenantID)
            ])
            let payload = try await get(url, authenticated: true, maxBytes: 4_000_000)
            guard let object = payload as? [String: Any], let records = object["captures"] as? [[String: Any]] else {
                throw ClientError.invalidResponse
            }
            let parsed = records.compactMap(Self.capture)
            guard parsed.count == records.count, parsed.allSatisfy({ $0.tenantID == tenantID }) else { throw ClientError.scopeUnconfirmed }
            let rows = parsed.filter { $0.domain != "unresolved" }
            return Resource(value: rows, state: .init(title: "Threat intelligence captures", detail: "Loaded \(rows.count) captures from the first 50 records.", available: true))
        } catch {
            return Resource(value: nil, state: .init(title: "Threat intelligence captures", detail: error.localizedDescription, available: false))
        }
    }

    private func loadSourceOperations() async -> Resource<[Source]> {
        do {
            let tenantID = try selectedTenantID()
            let url = try intelligenceEndpoint(path: "v1/intel/source-operations", query: [
                URLQueryItem(name: "limit", value: "25"), URLQueryItem(name: "page", value: "1"),
                URLQueryItem(name: "tenantId", value: tenantID), URLQueryItem(name: "includeCandidates", value: "false")
            ])
            let payload = try await get(url, authenticated: true, maxBytes: 4_000_000)
            guard let object = payload as? [String: Any], let records = (object["rows"] ?? object["sources"]) as? [[String: Any]] else {
                throw ClientError.invalidResponse
            }
            let rows = records.compactMap { value -> Source? in
                guard let id = value["id"] as? String, !id.isEmpty,
                      let tenant = value["tenantId"] as? String else { return nil }
                let name = value["name"] as? String
                return Source(tenantID: tenant, id: id, name: name?.isEmpty == false ? name! : id)
            }
            guard rows.count == records.count, rows.allSatisfy({ $0.tenantID == tenantID }) else { throw ClientError.scopeUnconfirmed }
            return Resource(value: rows, state: .init(title: "Source names", detail: "Loaded \(rows.count) source records.", available: true))
        } catch {
            return Resource(value: nil, state: .init(title: "Source names", detail: error.localizedDescription, available: false))
        }
    }

    private func get(_ url: URL, authenticated: Bool, maxBytes: Int) async throws -> Any {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if authenticated {
            let token = settings.authToken.trimmingCharacters(in: .whitespacesAndNewlines)
            let userID = settings.userID.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty, !userID.isEmpty else { throw ClientError.signIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            request.setValue(userID, forHTTPHeaderField: "id")
        }
        let (data, response) = try await session.data(for: request)
        guard data.count <= maxBytes else { throw ClientError.responseTooLarge }
        guard let http = response as? HTTPURLResponse, response.url == url else { throw ClientError.invalidResponse }
        guard (200..<300).contains(http.statusCode) else { throw ClientError.httpStatus(http.statusCode) }
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw ClientError.invalidResponse }
    }

    private func endpoint(base: String, path: String, query: [URLQueryItem]) throws -> URL {
        guard let configured = URL(string: base), configured.scheme?.lowercased() == "https",
              let host = configured.host, configured.user == nil, configured.password == nil,
              configured.query == nil, configured.fragment == nil,
              var components = URLComponents(url: configured, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidEndpoint
        }
        components.percentEncodedPath = (configured.path.hasSuffix("/") ? configured.path : configured.path + "/") + path
        components.queryItems = query.isEmpty ? nil : query
        guard let url = components.url, url.scheme?.lowercased() == "https", url.host?.lowercased() == host.lowercased() else {
            throw ClientError.invalidEndpoint
        }
        return url
    }

    private func intelligenceEndpoint(path: String, query: [URLQueryItem]) throws -> URL {
        let base = settings.websiteBaseURL.normalizedBaseURL
        let host = base.host?.lowercased()
        let intelligenceBase = host == "hanasand.com" ? URL(string: "https://ti.hanasand.com")! : base
        guard intelligenceBase.scheme?.lowercased() == "https", let expectedHost = intelligenceBase.host,
              intelligenceBase.user == nil, intelligenceBase.password == nil,
              var components = URLComponents(url: intelligenceBase, resolvingAgainstBaseURL: false) else {
            throw ClientError.invalidEndpoint
        }
        components.percentEncodedPath = "/" + path
        components.queryItems = query
        guard let url = components.url, url.scheme?.lowercased() == "https", url.host?.lowercased() == expectedHost.lowercased() else {
            throw ClientError.invalidEndpoint
        }
        return url
    }

    private func selectedTenantID() throws -> String {
        let tenantID = settings.selectedOrganizationID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard tenantID.range(of: "^[A-Za-z0-9_.:-]{1,200}$", options: .regularExpression) != nil else {
            throw ClientError.organizationRequired
        }
        guard settings.impersonationToken.isEmpty, settings.impersonatingUserID.isEmpty else {
            throw ClientError.impersonationUnsupported
        }
        return tenantID
    }

    private static func capture(_ value: [String: Any]) -> Capture? {
        guard let sourceID = value["sourceId"] as? String, !sourceID.isEmpty else { return nil }
        guard let tenantID = value["tenantId"] as? String else { return nil }
        let metadata = value["metadata"] as? [String: Any] ?? [:]
        let provenance = value["provenance"] as? [String: Any] ?? [:]
        let url = value["url"] as? String ?? ""
        let directDomain = text(metadata["domain"], metadata["victimDomain"], metadata["hostname"])
        let terms = metadata["matchedWatchTerms"] as? [String] ?? []
        let matchedDomain = terms.first(where: { $0.contains(".") })
        let domain = (directDomain ?? matchedDomain ?? hostname(url) ?? "unresolved").lowercased()
        let capturedAt = value["collectedAt"] as? String ?? ""
        let publishedAt = value["publishedAt"] as? String ?? capturedAt
        let firstObserved = provenance["firstObservedAt"] as? String
        return Capture(
            tenantID: tenantID,
            domain: domain,
            sourceID: sourceID,
            sourceName: value["sourceName"] as? String ?? sourceID,
            observedAt: capturedAt,
            publishedAt: publishedAt,
            monitoredSince: firstObserved ?? publishedAt
        )
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int, value >= 0 { return value }
        if let value = value as? NSNumber, value.doubleValue.isFinite, value.doubleValue >= 0,
           value.doubleValue.rounded() == value.doubleValue { return value.intValue }
        return nil
    }

    private static func text(_ values: Any?...) -> String? {
        values.compactMap { $0 as? String }.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.first(where: { !$0.isEmpty })
    }

    private static func hostname(_ rawValue: String) -> String? {
        guard let url = URL(string: rawValue), url.scheme == "https" || url.scheme == "http" else { return nil }
        return url.host
    }

    private static func isMonitorDomain(_ value: String) -> Bool {
        !value.isEmpty && !value.hasPrefix("/") && !value.contains(" ")
            && (value.contains(".") || value == "localhost")
            && value.range(of: "^[\\d.]+$", options: .regularExpression) == nil
    }

    private enum ClientError: LocalizedError {
        case signIn
        case organizationRequired
        case impersonationUnsupported
        case scopeUnconfirmed
        case invalidEndpoint
        case invalidResponse
        case responseTooLarge
        case httpStatus(Int)

        var errorDescription: String? {
            switch self {
            case .signIn: "Sign in to load monitored domains."
            case .organizationRequired: "Select an organization to safely scope threat intelligence data."
            case .impersonationUnsupported: "Return to your own account to load organization monitor data."
            case .scopeUnconfirmed: "The threat intelligence response did not confirm the selected organization, so these records were withheld."
            case .invalidEndpoint: "The monitor API endpoint is invalid."
            case .invalidResponse: "The monitor API returned an invalid response."
            case .responseTooLarge: "The monitor API response exceeded the size limit."
            case .httpStatus(let code): "The monitor API returned HTTP \(code)."
            }
        }
    }
}
