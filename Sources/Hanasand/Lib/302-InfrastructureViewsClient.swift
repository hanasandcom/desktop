import CoreFoundation
import Darwin
import Foundation

struct InfrastructureViewsAccess: Equatable {
    let accountScope: String
    let canRead: Bool
    let canWrite: Bool
}

struct InfrastructureViewsClient {
    typealias Sender = (URLRequest) async throws -> (Data, URLResponse)

    static let maximumResponseBytes = 4 * 1024 * 1024
    let apiBaseURL: URL
    let cdnBaseURL: URL
    let userID: String
    let token: String
    let impersonationToken: String
    let impersonatingUserID: String
    let accountScope: String
    private let send: Sender

    init(apiBaseURL: URL, cdnBaseURL: URL, userID: String, token: String, impersonationToken: String = "", impersonatingUserID: String = "", send: Sender? = nil) throws {
        let user = userID.trimmingCharacters(in: .whitespacesAndNewlines)
        let bearer = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !user.isEmpty, !bearer.isEmpty else { throw InfrastructureViewsError.signInRequired }
        guard Self.validBase(apiBaseURL), Self.validBase(cdnBaseURL),
              user.range(of: "^[A-Za-z0-9._-]{1,128}$", options: .regularExpression) != nil,
              bearer.range(of: "^[A-Za-z0-9._~-]{1,4096}$", options: .regularExpression) != nil else {
            throw InfrastructureViewsError.insecureEndpoint
        }
        self.apiBaseURL = apiBaseURL
        self.cdnBaseURL = cdnBaseURL
        self.userID = user
        self.token = bearer
        self.impersonationToken = impersonationToken
        self.impersonatingUserID = impersonatingUserID
        accountScope = "\(apiBaseURL.absoluteString)|\(cdnBaseURL.absoluteString)|\(user)"
        self.send = try send ?? Self.ephemeralSender()
    }

    var isOwnAccount: Bool { impersonationToken.isEmpty && impersonatingUserID.isEmpty }

    func loadAccess() async throws -> InfrastructureViewsAccess {
        try requireOwnAccount()
        var components = URLComponents(url: try endpoint(apiBaseURL, path: "management/organizations"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "internalPages", value: "1")]
        guard let url = components?.url else { throw InfrastructureViewsError.insecureEndpoint }
        let data = try await request(url: url, method: "GET", isMutation: false)
        guard let body = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let allowed = body["allowed"] as? Bool,
              let canEdit = body["canEdit"] as? Bool else { throw InfrastructureViewsError.invalidResponse }
        return InfrastructureViewsAccess(accountScope: accountScope, canRead: allowed, canWrite: allowed && canEdit && isOwnAccount)
    }

    func loadContainers() async throws -> InfrastructureContainersSnapshot {
        try requireOwnAccount()
        let data = try await request(url: endpoint(apiBaseURL, path: "system/snapshot"), method: "GET", isMutation: false)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let generatedAt = root["generated_at"] as? String, Self.validTimestamp(generatedAt),
              let docker = root["dockerTelemetry"] as? [String: Any],
              let rawContainers = docker["containers"] as? [[String: Any]], rawContainers.count <= 2000 else {
            throw InfrastructureViewsError.invalidResponse
        }
        var seen = Set<String>()
        let containers = try rawContainers.map { try Self.container($0, seen: &seen) }
        return InfrastructureContainersSnapshot(
            accountScope: accountScope,
            generatedAt: generatedAt,
            source: Self.text(docker["source"], maximum: 160),
            unavailableReason: Self.text(docker["unavailable_reason"], maximum: 1000),
            containers: containers
        )
    }

    func loadRuntimeLogs(service: String) async throws -> InfrastructureRuntimeLogs {
        try requireOwnAccount()
        guard !service.isEmpty, service.count <= 300,
              !service.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw InfrastructureViewsError.invalidResponse
        }
        var components = URLComponents(url: try endpoint(apiBaseURL, path: "logs/realtime"), resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "limit", value: "120"), URLQueryItem(name: "service", value: service)]
        guard let url = components?.url else { throw InfrastructureViewsError.insecureEndpoint }
        let data = try await request(url: url, method: "GET", isMutation: false)
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let generatedAt = root["generated_at"] as? String, Self.validTimestamp(generatedAt),
              let runtimeAvailable = root["runtime_available"] as? Bool,
              let nativeAvailable = root["native_available"] as? Bool,
              let entries = root["logs"] as? [[String: Any]], entries.count <= 120 else {
            throw InfrastructureViewsError.invalidResponse
        }
        let logs = entries.map { entry in
            InfrastructureRuntimeLogs.Entry(
                id: Self.text(entry["id"], maximum: 200),
                service: Self.text(entry["service"], maximum: 300),
                level: Self.text(entry["level"], maximum: 40),
                message: Self.text(entry["message"], maximum: 16_000),
                createdAt: Self.text(entry["created_at"], maximum: 80),
                source: Self.text(entry["source"], maximum: 80)
            )
        }
        guard logs.allSatisfy({ !$0.id.isEmpty }) else { throw InfrastructureViewsError.invalidResponse }
        return InfrastructureRuntimeLogs(source: Self.text(root["source"], maximum: 160), generatedAt: generatedAt,
                                          unavailableReason: Self.text(root["unavailable_reason"], maximum: 1000),
                                          runtimeAvailable: runtimeAvailable, nativeAvailable: nativeAvailable, entries: logs)
    }

    func restart(container: InfrastructureContainer, snapshot: InfrastructureContainersSnapshot, access: InfrastructureViewsAccess) async throws {
        try authorizeContainers(snapshot: snapshot, access: access)
        let age = Date().timeIntervalSince(Self.date(snapshot.generatedAt))
        guard age >= -5, age <= 30,
              snapshot.containers.contains(where: { $0.id == container.id && $0.name == container.name }),
              container.id.range(of: "^[A-Fa-f0-9]{12,64}$", options: .regularExpression) != nil,
              !["dead", "exited", "removing"].contains(container.state.lowercased()) else {
            throw InfrastructureViewsError.staleInventory
        }
        let data = try await request(url: endpoint(apiBaseURL, path: "restart/\(container.id)"), method: "GET", isMutation: true)
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any], result["ok"] as? Bool == true,
              result["detail"] != nil else { throw InfrastructureViewsError.uncertainResult }
    }

    func loadBlocklist() async throws -> [InfrastructureBlocklistEntry] {
        try requireOwnAccount()
        let data = try await request(url: endpoint(cdnBaseURL, path: "blocklist/overview"), method: "GET", isMutation: false)
        guard let raw = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]], raw.count <= 100 else {
            throw InfrastructureViewsError.invalidResponse
        }
        var seen = Set<Int>()
        let entries = try raw.map { row -> InfrastructureBlocklistEntry in
            guard let id = Self.integer(row["id"]), id > 0, seen.insert(id).inserted,
                  let kind = InfrastructureBlocklistEntry.Kind(rawValue: Self.text(row["type"], maximum: 40)),
                  let value = row["value"] as? String, !value.isEmpty, value.count <= 2048 else {
                throw InfrastructureViewsError.invalidResponse
            }
            let location = row["location"] as? [String: Any] ?? [:]
            let place = ["country", "region", "city"].compactMap { key -> String? in
                let value = Self.text(location[key], maximum: 120)
                return value.isEmpty ? nil : value
            }.joined(separator: ", ")
            return InfrastructureBlocklistEntry(id: id, kind: kind, value: value,
                isVPN: row["is_vpn"] as? Bool ?? false, isProxy: row["is_proxy"] as? Bool ?? false,
                isTor: row["is_tor"] as? Bool ?? false, isRelay: row["is_relay"] as? Bool ?? false,
                owner: Self.text(row["owner"], maximum: 200), location: place,
                requests: Self.integer(row["requests"]), createdAt: Self.text(row["created_at"], maximum: 80),
                updatedAt: Self.text(row["updated_at"], maximum: 80))
        }
        return entries
    }

    func createBlocklistEntry(_ draft: InfrastructureBlocklistDraft) async throws {
        try authorizeBlocklist()
        try Self.validate(draft)
        let body = try JSONSerialization.data(withJSONObject: ["metric": draft.kind.rawValue, "value": draft.value.trimmingCharacters(in: .whitespacesAndNewlines)])
        let data = try await request(url: endpoint(cdnBaseURL, path: "blocklist"), method: "POST", body: body, isMutation: true)
        guard let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.integer(receipt["id"]) != nil || receipt["message"] as? String == "Entry already exists" else {
            throw InfrastructureViewsError.uncertainResult
        }
    }

    func updateBlocklistEntry(_ entry: InfrastructureBlocklistEntry, draft: InfrastructureBlocklistDraft, currentEntries: [InfrastructureBlocklistEntry]) async throws {
        try authorizeBlocklist()
        try Self.validate(draft)
        guard currentEntries.contains(where: { $0.id == entry.id && $0 == entry }) else { throw InfrastructureViewsError.invalidScope }
        // The CDN endpoint interpolates keys into SQL; send only the established columns.
        let body = try JSONSerialization.data(withJSONObject: [
            "metric": draft.kind.rawValue,
            "value": draft.value.trimmingCharacters(in: .whitespacesAndNewlines),
            "is_vpn": draft.isVPN,
            "is_proxy": draft.isProxy,
            "is_tor": draft.isTor,
        ])
        let data = try await request(url: endpoint(cdnBaseURL, path: "blocklist/\(entry.id)"), method: "PUT", body: body, isMutation: true)
        guard let receipt = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Self.integer(receipt["id"]) == entry.id,
              receipt["metric"] as? String == draft.kind.rawValue,
              receipt["value"] as? String == draft.value.trimmingCharacters(in: .whitespacesAndNewlines) else {
            throw InfrastructureViewsError.uncertainResult
        }
    }

    func deleteBlocklistEntry(_ entry: InfrastructureBlocklistEntry, currentEntries: [InfrastructureBlocklistEntry]) async throws {
        try authorizeBlocklist()
        guard currentEntries.contains(where: { $0.id == entry.id && $0 == entry }) else { throw InfrastructureViewsError.invalidScope }
        let data = try await request(url: endpoint(cdnBaseURL, path: "blocklist/\(entry.id)"), method: "DELETE", isMutation: true)
        guard let result = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              (result["message"] as? String) == "Blocklist entry deleted",
              let deleted = result["deleted"] as? [String: Any], Self.integer(deleted["id"]) == entry.id else { throw InfrastructureViewsError.uncertainResult }
    }

    private func authorizeContainers(snapshot: InfrastructureContainersSnapshot, access: InfrastructureViewsAccess) throws {
        try requireOwnAccount()
        guard access.accountScope == accountScope, snapshot.accountScope == accountScope, access.canRead, access.canWrite else {
            throw InfrastructureViewsError.invalidScope
        }
    }

    private func authorizeBlocklist() throws {
        try requireOwnAccount()
    }

    private func requireOwnAccount() throws {
        guard isOwnAccount else { throw InfrastructureViewsError.ownAccountRequired }
    }

    private func request(url: URL, method: String, body: Data? = nil, isMutation: Bool) async throws -> Data {
        guard url.scheme?.lowercased() == "https", url.host != nil, url.user == nil, url.password == nil else {
            throw InfrastructureViewsError.insecureEndpoint
        }
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = method
        request.httpBody = body
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(userID, forHTTPHeaderField: "id")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            let (data, response) = try await send(request)
            guard let http = response as? HTTPURLResponse else { throw InfrastructureViewsError.invalidResponse }
            guard data.count <= Self.maximumResponseBytes else { throw InfrastructureViewsError.responseTooLarge }
            guard (200..<300).contains(http.statusCode) else {
                if isMutation && http.statusCode >= 500 { throw InfrastructureViewsError.uncertainResult }
                if http.statusCode == 401 || http.statusCode == 403 { throw InfrastructureViewsError.accessDenied }
                throw InfrastructureViewsError.requestFailed(http.statusCode)
            }
            return data
        } catch let error as InfrastructureViewsError {
            throw error
        } catch {
            if isMutation { throw InfrastructureViewsError.uncertainResult }
            throw InfrastructureViewsError.requestFailed(0)
        }
    }

    private func endpoint(_ base: URL, path: String) throws -> URL {
        guard Self.validBase(base) else { throw InfrastructureViewsError.insecureEndpoint }
        return base.appendingAPIPath(path)
    }

    private static func validBase(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "https" && url.host != nil && url.user == nil && url.password == nil && url.query == nil && url.fragment == nil
    }

    private static func validate(_ draft: InfrastructureBlocklistDraft) throws {
        let value = draft.value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.count <= 2048,
              !value.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else { throw InfrastructureViewsError.invalidDraft }
        if draft.kind == .ip {
            guard isIP(value) else { throw InfrastructureViewsError.invalidDraft }
        }
    }

    private static func isIP(_ value: String) -> Bool {
        var address = in_addr()
        if value.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 { return true }
        var address6 = in6_addr()
        return value.withCString({ inet_pton(AF_INET6, $0, &address6) }) == 1
    }

    private static func container(_ row: [String: Any], seen: inout Set<String>) throws -> InfrastructureContainer {
        guard let id = row["id"] as? String, id.range(of: "^[A-Fa-f0-9]{12,64}$", options: .regularExpression) != nil,
              seen.insert(id).inserted,
              let name = row["name"] as? String, !name.isEmpty, name.count <= 300 else {
            throw InfrastructureViewsError.invalidResponse
        }
        let stats = row["stats"] as? [String: Any] ?? [:]
        let rawPorts = row["ports"] as? [[String: Any]] ?? []
        guard rawPorts.count <= 200 else { throw InfrastructureViewsError.invalidResponse }
        let ports = try rawPorts.map { port -> InfrastructureContainer.Port in
            guard let privatePort = integer(port["private_port"]), (0...65535).contains(privatePort) else { throw InfrastructureViewsError.invalidResponse }
            let publicPort = integer(port["public_port"])
            guard publicPort == nil || (0...65535).contains(publicPort!) else { throw InfrastructureViewsError.invalidResponse }
            return .init(ip: text(port["ip"], maximum: 100), privatePort: privatePort, publicPort: publicPort, type: text(port["type"], maximum: 20))
        }
        let state = text(row["state"], maximum: 100).isEmpty ? text(row["status"], maximum: 100) : text(row["state"], maximum: 100)
        return InfrastructureContainer(id: id, name: name, image: text(row["image"], maximum: 500), state: state,
            health: text(row["health"], maximum: 100).isEmpty ? "Not reported" : text(row["health"], maximum: 100),
            cpuPercent: number(stats["cpu_percent"]) ?? number(row["cpu"]),
            memoryBytes: number(stats["memory_bytes"]) ?? number(row["memory"]),
            memoryLimitBytes: number(stats["memory_limit_bytes"]), memoryPercent: number(stats["memory_percent"]),
            uptimeSeconds: number(row["uptime_seconds"]), restartCount: integer(row["restart_count"]),
            createdAt: text(row["created_at"], maximum: 80), statsUpdatedAt: text(row["stats_updated_at"], maximum: 80),
            unavailableReason: text(row["stats_unavailable_reason"], maximum: 1000), ports: ports)
    }

    private static func text(_ value: Any?, maximum: Int) -> String {
        guard let string = value as? String else { return "" }
        return String(string.prefix(maximum))
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber else { return nil }
        let result = number.doubleValue
        return result.isFinite && result >= 0 ? result : nil
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue >= Double(Int.min), number.doubleValue <= Double(Int.max), number.doubleValue.rounded() == number.doubleValue else { return nil }
        return number.intValue
    }

    private static func validTimestamp(_ value: String) -> Bool { date(value) != .distantPast }

    private static func date(_ value: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value) ?? .distantPast
    }

    private static func ephemeralSender() throws -> Sender {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let delegate = InfrastructureNoRedirectDelegate()
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        return { request in
            let result = try await session.data(for: request)
            if let http = result.1 as? HTTPURLResponse,
               let length = http.value(forHTTPHeaderField: "Content-Length"), let expected = Int(length), expected > Self.maximumResponseBytes {
                throw InfrastructureViewsError.responseTooLarge
            }
            return result
        }
    }
}

private final class InfrastructureNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}
