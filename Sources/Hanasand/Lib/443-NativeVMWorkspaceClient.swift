import Foundation

private final class NativeVMRedirectBlocker: NSObject, URLSessionTaskDelegate {
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

struct NativeVMWorkspaceClient {
    typealias Sender = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    private static let redirectBlocker = NativeVMRedirectBlocker()
    private static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: configuration, delegate: redirectBlocker, delegateQueue: nil)
    }()

    private let baseURL: URL
    private let userID: String
    private let token: String
    private let organizationID: String?
    private let send: Sender

    init(
        apiBaseURL: String,
        userID: String,
        token: String,
        organizationID: String? = nil,
        send: @escaping Sender = { request in try await Self.session.data(for: request) }
    ) throws {
        guard var components = URLComponents(string: apiBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = components.scheme?.lowercased(),
              let host = components.host?.lowercased(),
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil,
              scheme == "https" || (scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw NativeVMWorkspaceClientError.invalidEndpoint
        }
        components.path = "/" + components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard let baseURL = components.url else { throw NativeVMWorkspaceClientError.invalidEndpoint }
        self.baseURL = baseURL
        self.userID = userID
        self.token = token
        self.organizationID = organizationID?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.send = send
    }

    func loadDetails(for rawName: String) async throws -> NativeVMWorkspaceDetails? {
        let name = try validatedName(rawName)
        let value = try await get("vm/details/\(name)")
        guard let object = firstObject(value) else { return nil }
        guard (object["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame else {
            throw NativeVMWorkspaceClientError.invalidResponse
        }
        let fieldNames = [
            ("status", "Status"), ("status_reason", "Status reason"), ("type", "Type"),
            ("architecture", "Architecture"), ("created", "Created"), ("last_used", "Last used"),
            ("last_checked", "Last checked"), ("config_architecture", "Image architecture"),
            ("config_image_description", "Image"), ("config_image_label", "Image label"),
            ("config_image_os", "Operating system"), ("config_image_release", "OS release"),
            ("config_image_version", "Image version"), ("limits_cpu", "CPU limit"),
            ("limits_memory", "Memory limit"), ("device_eth0_ipv4_address", "IPv4"),
            ("device_eth0_network", "Network"), ("primary_host", "Primary host"),
            ("description", "Description"), ("volatile_uuid", "Instance UUID")
        ]
        let fields = fieldNames.compactMap { key, label -> (String, String)? in
            guard let text = object[key] as? String,
                  !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (label, String(text.prefix(1_000)))
        }
        let profiles = (object["profiles"] as? [String] ?? []).prefix(100).map { String($0.prefix(200)) }
        return NativeVMWorkspaceDetails(name: name, fields: fields, profiles: profiles)
    }

    func loadMetrics(for rawName: String) async throws -> [NativeVMMetric] {
        let name = try validatedName(rawName)
        let value = try await get("vm/metrics/\(name)")
        guard let rows = value as? [[String: Any]], rows.count <= 120 else {
            throw NativeVMWorkspaceClientError.invalidResponse
        }
        let keys: [(String, String)] = [
            ("cpu_usage_percent", "CPU usage (%)"), ("cpu_cores", "CPU cores"),
            ("cpu_temperature", "CPU temperature"), ("ram_used_mb", "Memory used (MB)"),
            ("ram_total_mb", "Memory total (MB)"), ("gpu_usage_percent", "GPU usage (%)"),
            ("disk_used_mb", "Disk used (MB)"), ("disk_total_mb", "Disk total (MB)"),
            ("net_in_kbps", "Network in (KB/s)"), ("net_out_kbps", "Network out (KB/s)"),
            ("uptime_seconds", "Uptime (s)"), ("load_average_1", "Load average (1m)")
        ]
        return try rows.enumerated().map { index, row in
            guard (row["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame else {
                throw NativeVMWorkspaceClientError.invalidResponse
            }
            let values = keys.compactMap { key, label -> (String, String)? in
                guard let value = row[key], !(value is NSNull) else { return nil }
                let text = String(describing: value)
                guard text.count <= 100 else { return nil }
                return (label, text)
            }
            return NativeVMMetric(
                id: String(describing: row["id"] ?? "\(name)-\(index)"),
                recordedAt: row["created_at"] as? String,
                powerState: row["power_state"] as? String,
                values: values
            )
        }
    }

    func loadManagement(for rawName: String) async throws -> NativeVMManagementAccess {
        let name = try validatedName(rawName)
        let value = try await get("vm/\(name)/public-services")
        guard let object = value as? [String: Any],
              let canManage = object["canManage"] as? Bool,
              let rows = object["services"] as? [[String: Any]], rows.count <= 1_000 else {
            throw NativeVMWorkspaceClientError.invalidResponse
        }
        let services = rows.compactMap { row -> (String, String)? in
            guard let serviceName = row["name"] as? String,
                  let type = row["type"] as? String,
                  let port = row["port"] else { return nil }
            return (String(serviceName.prefix(100)), "\(type) · port \(String(describing: port)) · \(String(describing: row["hostname"] ?? "Host unavailable"))")
        }
        return NativeVMManagementAccess(canManage: canManage, services: services)
    }

    private func validatedName(_ rawName: String) throws -> String {
        guard rawName.count <= 100,
              rawName.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
              rawName != ".", rawName != "..", rawName.lowercased() != "root", rawName.lowercased() != "nobody" else {
            throw NativeVMWorkspaceClientError.invalidVMName
        }
        return rawName
    }

    private func get(_ path: String) async throws -> Any {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        let basePath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        let expectedPath = "/" + [basePath, path].filter({ !$0.isEmpty }).joined(separator: "/")
        components?.path = "/" + [basePath, path].filter { !$0.isEmpty }.joined(separator: "/")
        guard let url = components?.url,
              url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              url.host?.lowercased() == baseURL.host?.lowercased(),
              url.path == expectedPath else {
            throw NativeVMWorkspaceClientError.invalidEndpoint
        }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if !userID.isEmpty { request.setValue(userID, forHTTPHeaderField: "id") }
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let organizationID, !organizationID.isEmpty {
            request.setValue(organizationID, forHTTPHeaderField: "x-organization-id")
        }

        let (data, response) = try await send(request)
        guard data.count <= 4 * 1024 * 1024,
              let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              response.url?.host?.lowercased() == baseURL.host?.lowercased(),
              response.url?.path == url.path else {
            if data.count > 4 * 1024 * 1024 { throw NativeVMWorkspaceClientError.responseTooLarge }
            throw NativeVMWorkspaceClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else { throw NativeVMWorkspaceClientError.httpStatus(http.statusCode) }
        do { return try JSONSerialization.jsonObject(with: data) }
        catch { throw NativeVMWorkspaceClientError.invalidResponse }
    }

    private func firstObject(_ value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        if let rows = value as? [[String: Any]] { return rows.first }
        return nil
    }
}
