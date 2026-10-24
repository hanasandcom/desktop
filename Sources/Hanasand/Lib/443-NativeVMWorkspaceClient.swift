import Foundation
import CryptoKit

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
    static let managementMaximumAge: TimeInterval = 30
    static let maximumResponseBytes = 4 * 1024 * 1024

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
    private let scope: String
    private let send: Sender
    private let now: () -> Date

    init(
        apiBaseURL: String,
        userID: String,
        token: String,
        organizationID: String? = nil,
        now: @escaping () -> Date = Date.init,
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
        let tokenDigest = SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
        self.scope = [baseURL.absoluteString, userID, tokenDigest, self.organizationID ?? "personal"].joined(separator: "|")
        self.now = now
        self.send = send
    }

    func loadInventory() async throws -> NativeVMInventorySnapshot {
        let account = try validatedIdentifier(userID)
        var merged: [String: NativeVMInventoryItem] = [:]
        var warnings: [String] = []
        var failures: [Error] = []
        var successfulReads = 0

        for path in ["vms/\(account)", "vms/access/\(account)"] {
            do {
                let value = try await get(path)
                guard let rows = value as? [[String: Any]], rows.count <= 10_000 else {
                    throw NativeVMWorkspaceClientError.invalidResponse
                }
                var identities = Set<String>()
                let items = try rows.map(parseInventoryItem)
                for item in items {
                    let identity = item.name.lowercased()
                    guard identities.insert(identity).inserted else { throw NativeVMWorkspaceClientError.invalidResponse }
                    if let organizationID, !organizationID.isEmpty,
                       item.organizationID != organizationID {
                        throw NativeVMWorkspaceClientError.invalidResponse
                    }
                    if let existing = merged[identity] {
                        merged[identity] = mergeInventoryItems(existing, item)
                    } else {
                        merged[identity] = item
                    }
                }
                successfulReads += 1
            } catch {
                failures.append(error)
                warnings.append(error.localizedDescription)
            }
        }

        guard successfulReads > 0 else { throw failures.first ?? NativeVMWorkspaceClientError.invalidResponse }
        let items = merged.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return NativeVMInventorySnapshot(items: items, isComplete: successfulReads == 2, warnings: warnings)
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
            ("config_image_architecture", "Configured image architecture"),
            ("config_image_description", "Image"), ("config_image_label", "Image label"),
            ("config_image_os", "Operating system"), ("config_image_release", "OS release"),
            ("config_image_serial", "Image serial"), ("config_image_type", "Image type"),
            ("config_image_version", "Image version"), ("limits_cpu", "CPU limit"),
            ("limits_memory", "Memory limit"), ("volatile_base_image", "Base image"),
            ("volatile_cloud_init_instance_id", "Cloud-init instance"), ("volatile_eth0_hwaddr", "Network MAC"),
            ("volatile_last_state_power", "Previous power state"), ("volatile_uuid", "Instance UUID"),
            ("volatile_uuid_generation", "UUID generation"), ("volatile_vsock_id", "VSock ID"),
            ("device_eth0_ipv4_address", "IPv4"), ("device_eth0_name", "Network interface"),
            ("device_eth0_network", "Network"), ("device_eth0_type", "Network type"),
            ("description", "Description"), ("primary_host", "Primary host"),
            ("ephemeral", "Ephemeral"), ("stateful", "Stateful")
        ]
        let fields = fieldNames.compactMap { key, label -> (String, String)? in
            guard let raw = object[key], !(raw is NSNull) else { return nil }
            let text = String(describing: raw)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  text.count <= 1_000 else { return nil }
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
            ("gpu_memory_used_mb", "GPU memory used (MB)"), ("gpu_memory_total_mb", "GPU memory total (MB)"),
            ("gpu_temperature", "GPU temperature"), ("system_temperature", "System temperature"),
            ("disk_used_mb", "Disk used (MB)"), ("disk_total_mb", "Disk total (MB)"),
            ("disk_read_iops", "Disk reads (IOPS)"), ("disk_write_iops", "Disk writes (IOPS)"),
            ("net_in_kbps", "Network in (KB/s)"), ("net_out_kbps", "Network out (KB/s)"),
            ("power_consumption_watts", "Power (W)"), ("uptime_seconds", "Uptime (s)"),
            ("uptime_total_seconds", "Total uptime (s)"), ("load_average_1", "Load average (1m)"),
            ("load_average_5", "Load average (5m)"), ("load_average_15", "Load average (15m)")
        ]
        return try rows.enumerated().map { index, row in
            guard (row["name"] as? String)?.caseInsensitiveCompare(name) == .orderedSame else {
                throw NativeVMWorkspaceClientError.invalidResponse
            }
            let values = keys.compactMap { key, label -> (String, String)? in
                guard let value = row[key], !(value is NSNull) else { return nil }
                let text: String
                if let number = value as? NSNumber, String(cString: number.objCType) != "c", number.doubleValue.isFinite {
                    text = number.stringValue
                } else if let string = value as? String, Double(string)?.isFinite == true {
                    text = string
                } else { return nil }
                guard text.count <= 100 else { return nil }
                return (label, text)
            }
            return NativeVMMetric(
                id: String(describing: row["id"] ?? "\(name)-\(index)"),
                recordedAt: row["created_at"] as? String,
                powerState: row["power_state"] as? String,
                poweredOnAt: row["powered_on_at"] as? String,
                poweredOffAt: row["powered_off_at"] as? String,
                values: values
            )
        }
        .sorted {
            guard let lhs = $0.recordedAt.flatMap(Date.init(iso8601String:)),
                  let rhs = $1.recordedAt.flatMap(Date.init(iso8601String:)) else { return false }
            return lhs > rhs
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
        return NativeVMManagementAccess(scope: scope, vmName: name, capturedAt: now(), canManage: canManage,
                                        services: try rows.map(parsePublicService))
    }

    func createPublicService(
        for rawName: String,
        authorization: NativeVMManagementAccess,
        name rawServiceName: String,
        type: String,
        port: Int
    ) async throws -> NativeVMPublicService {
        let vmName = try validatedName(rawName)
        try authorizeManagement(authorization, vmName: vmName)
        let serviceName = rawServiceName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard serviceName.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$"#, options: .regularExpression) != nil,
              !serviceName.hasPrefix("port-"), ["http", "tls", "minecraft-java"].contains(type), (1...65_535).contains(port) else {
            throw NativeVMWorkspaceClientError.invalidServiceInput
        }
        let body = try JSONSerialization.data(withJSONObject: ["name": serviceName, "type": type, "port": port])
        let (value, status) = try await request("vm/\(Self.pathSegment(vmName))/public-services", method: "POST", body: body, mutation: true)
        guard status == 201, let object = value as? [String: Any] else { throw NativeVMWorkspaceClientError.uncertainOutcome }
        do { return try parsePublicService(object) }
        catch { throw NativeVMWorkspaceClientError.uncertainOutcome }
    }

    func removePublicService(
        for rawName: String,
        authorization: NativeVMManagementAccess,
        serviceID rawServiceID: String
    ) async throws {
        let vmName = try validatedName(rawName)
        try authorizeManagement(authorization, vmName: vmName)
        let serviceID = try validatedIdentifier(rawServiceID)
        guard authorization.services.contains(where: { $0.id == serviceID }) else {
            throw NativeVMWorkspaceClientError.staleManagementSnapshot
        }
        let (value, status) = try await request(
            "vm/\(Self.pathSegment(vmName))/public-services/\(Self.pathSegment(serviceID))",
            method: "DELETE", mutation: true
        )
        guard status == 200, let object = value as? [String: Any], object["ok"] as? Bool == true else {
            throw NativeVMWorkspaceClientError.uncertainOutcome
        }
    }

    private func parseInventoryItem(_ object: [String: Any]) throws -> NativeVMInventoryItem {
        guard let rawName = object["name"] as? String else { throw NativeVMWorkspaceClientError.invalidResponse }
        let name = try validatedName(rawName)
        guard let owner = object["owner"] as? String, owner.count <= 200 else {
            throw NativeVMWorkspaceClientError.invalidResponse
        }
        func optionalText(_ key: String, maximum: Int = 1_000) throws -> String? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            guard let text = value as? String, text.count <= maximum else { throw NativeVMWorkspaceClientError.invalidResponse }
            return text
        }
        func optionalFlag(_ key: String) throws -> Bool? {
            guard let value = object[key], !(value is NSNull) else { return nil }
            guard let flag = value as? Bool else { throw NativeVMWorkspaceClientError.invalidResponse }
            return flag
        }
        let accessUsers: [String]
        if let rawUsers = object["access_users"], !(rawUsers is NSNull) {
            guard let users = rawUsers as? [String], users.count <= 10_000,
                  users.allSatisfy({ !$0.isEmpty && $0.count <= 200 }) else { throw NativeVMWorkspaceClientError.invalidResponse }
            accessUsers = users
        } else { accessUsers = [] }
        var restoredInstanceMissing: Bool?
        if let rawRestore = object["deletion_restore"], !(rawRestore is NSNull) {
            guard let restore = rawRestore as? [String: Any] else { throw NativeVMWorkspaceClientError.invalidResponse }
            if let rawMissing = restore["instanceMissing"], !(rawMissing is NSNull) {
                guard let missing = rawMissing as? Bool else { throw NativeVMWorkspaceClientError.invalidResponse }
                restoredInstanceMissing = missing
            }
        }
        return NativeVMInventoryItem(
            name: name,
            owner: owner,
            createdBy: try optionalText("created_by", maximum: 200),
            organizationID: try optionalText("organization_id", maximum: 200),
            organizationName: try optionalText("organization_name"),
            accessUsers: accessUsers,
            managed: try optionalFlag("managed"),
            canAssignOrganization: try optionalFlag("can_assign_organization"),
            status: try optionalText("status"),
            statusReason: try optionalText("status_reason"),
            statusCheckedAt: try optionalText("status_checked_at"),
            deletedAt: try optionalText("deleted_at"),
            deleteAfter: try optionalText("delete_after"),
            deletionError: try optionalText("deletion_error"),
            restoredInstanceMissing: restoredInstanceMissing,
            primaryHost: try optionalText("primary_host"),
            failoverHost: try optionalText("failover_host"),
            failoverPremium: try optionalFlag("failover_premium"),
            failoverEnabled: try optionalFlag("failover_enabled"),
            alwaysRunningPremium: try optionalFlag("always_running_premium"),
            alwaysRunningEnabled: try optionalFlag("always_running_enabled"),
            type: try optionalText("type"),
            architecture: try optionalText("architecture"),
            created: try optionalText("created"),
            lastUsed: try optionalText("last_used"),
            cpuLimit: try optionalText("limits_cpu"),
            memoryLimit: try optionalText("limits_memory"),
            imageDescription: try optionalText("config_image_description"),
            imageOS: try optionalText("config_image_os"),
            imageVersion: try optionalText("config_image_version"),
            ipv4: try optionalText("device_eth0_ipv4_address"),
            lastChecked: try optionalText("last_checked")
        )
    }

    private func mergeInventoryItems(_ first: NativeVMInventoryItem, _ second: NativeVMInventoryItem) -> NativeVMInventoryItem {
        NativeVMInventoryItem(
            name: first.name,
            owner: first.owner,
            createdBy: first.createdBy ?? second.createdBy,
            organizationID: first.organizationID ?? second.organizationID,
            organizationName: first.organizationName ?? second.organizationName,
            accessUsers: Array(Set(first.accessUsers + second.accessUsers)).sorted(),
            managed: first.managed ?? second.managed,
            canAssignOrganization: first.canAssignOrganization ?? second.canAssignOrganization,
            status: first.status ?? second.status,
            statusReason: first.statusReason ?? second.statusReason,
            statusCheckedAt: first.statusCheckedAt ?? second.statusCheckedAt,
            deletedAt: first.deletedAt ?? second.deletedAt,
            deleteAfter: first.deleteAfter ?? second.deleteAfter,
            deletionError: first.deletionError ?? second.deletionError,
            restoredInstanceMissing: first.restoredInstanceMissing ?? second.restoredInstanceMissing,
            primaryHost: first.primaryHost ?? second.primaryHost,
            failoverHost: first.failoverHost ?? second.failoverHost,
            failoverPremium: first.failoverPremium ?? second.failoverPremium,
            failoverEnabled: first.failoverEnabled ?? second.failoverEnabled,
            alwaysRunningPremium: first.alwaysRunningPremium ?? second.alwaysRunningPremium,
            alwaysRunningEnabled: first.alwaysRunningEnabled ?? second.alwaysRunningEnabled,
            type: first.type ?? second.type,
            architecture: first.architecture ?? second.architecture,
            created: first.created ?? second.created,
            lastUsed: first.lastUsed ?? second.lastUsed,
            cpuLimit: first.cpuLimit ?? second.cpuLimit,
            memoryLimit: first.memoryLimit ?? second.memoryLimit,
            imageDescription: first.imageDescription ?? second.imageDescription,
            imageOS: first.imageOS ?? second.imageOS,
            imageVersion: first.imageVersion ?? second.imageVersion,
            ipv4: first.ipv4 ?? second.ipv4,
            lastChecked: first.lastChecked ?? second.lastChecked
        )
    }

    private func validatedName(_ rawName: String) throws -> String {
        guard rawName.count <= 100,
              rawName.range(of: #"^[A-Za-z0-9][A-Za-z0-9_.-]*$"#, options: .regularExpression) != nil,
              rawName != ".", rawName != "..", rawName.lowercased() != "root", rawName.lowercased() != "nobody" else {
            throw NativeVMWorkspaceClientError.invalidVMName
        }
        return rawName
    }

    private func validatedIdentifier(_ rawValue: String) throws -> String {
        guard rawValue.count <= 200,
              rawValue.range(of: #"^[A-Za-z0-9_.:@-]+$"#, options: .regularExpression) != nil,
              rawValue != ".", rawValue != ".." else { throw NativeVMWorkspaceClientError.invalidResponse }
        return rawValue
    }

    private func authorizeManagement(_ authorization: NativeVMManagementAccess, vmName: String) throws {
        let age = now().timeIntervalSince(authorization.capturedAt)
        guard authorization.scope == scope,
              authorization.vmName.caseInsensitiveCompare(vmName) == .orderedSame,
              age >= -5, age <= Self.managementMaximumAge else {
            throw NativeVMWorkspaceClientError.staleManagementSnapshot
        }
        guard authorization.canManage else { throw NativeVMWorkspaceClientError.permissionDenied }
    }

    private func parsePublicService(_ row: [String: Any]) throws -> NativeVMPublicService {
        guard let id = row["id"] as? String, !id.isEmpty, id.count <= 200,
              let serviceName = row["name"] as? String,
              serviceName.range(of: #"^[a-z0-9](?:[a-z0-9-]{0,38}[a-z0-9])?$"#, options: .regularExpression) != nil,
              let type = row["type"] as? String, ["http", "tls", "minecraft-java"].contains(type),
              let portValue = row["port"] as? NSNumber, String(cString: portValue.objCType) != "c",
              portValue.intValue > 0, portValue.intValue <= 65_535 else {
            throw NativeVMWorkspaceClientError.invalidResponse
        }
        let hostname: String?
        if let rawHostname = row["hostname"], !(rawHostname is NSNull) {
            guard let parsedHostname = rawHostname as? String, parsedHostname.count <= 253 else {
                throw NativeVMWorkspaceClientError.invalidResponse
            }
            hostname = parsedHostname
        } else {
            hostname = nil
        }
        return NativeVMPublicService(id: id, name: serviceName, type: type, port: portValue.intValue,
                                     hostname: hostname, createdAt: row["createdAt"] as? String)
    }

    private func get(_ path: String) async throws -> Any {
        try await request(path, method: "GET").value
    }

    private func request(_ path: String, method: String, body: Data? = nil, mutation: Bool = false) async throws -> (value: Any, status: Int) {
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
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: mutation ? 30 : 15)
        request.httpMethod = method
        request.httpBody = body
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        if !userID.isEmpty { request.setValue(userID, forHTTPHeaderField: "id") }
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let organizationID, !organizationID.isEmpty {
            request.setValue(organizationID, forHTTPHeaderField: "x-organization-id")
        }

        let (data, response): (Data, URLResponse)
        do { (data, response) = try await send(request) }
        catch {
            if mutation { throw NativeVMWorkspaceClientError.uncertainOutcome }
            throw error
        }
        guard data.count <= Self.maximumResponseBytes,
              let http = response as? HTTPURLResponse,
              response.url?.scheme?.lowercased() == baseURL.scheme?.lowercased(),
              response.url?.host?.lowercased() == baseURL.host?.lowercased(),
              response.url?.port == url.port,
              response.url?.path == url.path,
              response.url?.query == url.query else {
            if mutation { throw NativeVMWorkspaceClientError.uncertainOutcome }
            if data.count > Self.maximumResponseBytes { throw NativeVMWorkspaceClientError.responseTooLarge }
            throw NativeVMWorkspaceClientError.invalidResponse
        }
        guard (200..<300).contains(http.statusCode) else {
            if mutation && (http.statusCode >= 500 || (300..<400).contains(http.statusCode)) {
                throw NativeVMWorkspaceClientError.uncertainOutcome
            }
            throw NativeVMWorkspaceClientError.httpStatus(http.statusCode)
        }
        do { return (try JSONSerialization.jsonObject(with: data), http.statusCode) }
        catch { throw mutation ? NativeVMWorkspaceClientError.uncertainOutcome : NativeVMWorkspaceClientError.invalidResponse }
    }

    private static func pathSegment(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~")) ?? ""
    }

    private func firstObject(_ value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] { return object }
        if let rows = value as? [[String: Any]] { return rows.first }
        return nil
    }
}

private extension Date {
    init?(iso8601String: String) {
        if let date = ISO8601DateFormatter().date(from: iso8601String) { self = date; return }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let date = formatter.date(from: iso8601String) else { return nil }
        self = date
    }
}
