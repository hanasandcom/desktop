import Foundation

enum HostAvailability: String, Decodable { case online, offline, unknown }

struct HostOverviewEnvelope: Decodable {
    struct Host: Decodable, Identifiable {
        enum ID: String, Decodable { case inspur, ovh }
        let id: ID
        let name: String
        let address: String
        let username: String
        let status: HostAvailability
        let hostname: String?
        let operatingSystem: String?

        enum CodingKeys: String, CodingKey { case id, name, address, username, status, hostname, operatingSystem }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(ID.self, forKey: .id)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? id.rawValue.capitalized
            address = try container.decodeIfPresent(String.self, forKey: .address) ?? ""
            username = try container.decodeIfPresent(String.self, forKey: .username) ?? ""
            status = HostAvailability(rawValue: try container.decodeIfPresent(String.self, forKey: .status) ?? "") ?? .unknown
            hostname = try container.decodeIfPresent(String.self, forKey: .hostname)
            operatingSystem = try container.decodeIfPresent(String.self, forKey: .operatingSystem)
        }
    }

    struct AccessUser: Decodable, Identifiable {
        let id: String
        let name: String
        let username: String
        let keyCount: Int?

        enum CodingKeys: String, CodingKey { case id, name, username, keyCount }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            id = try container.decode(String.self, forKey: .id)
            let decodedUsername = try container.decode(String.self, forKey: .username)
            name = try container.decodeIfPresent(String.self, forKey: .name) ?? decodedUsername
            username = decodedUsername
            let count = try container.decodeIfPresent(Int.self, forKey: .keyCount)
            keyCount = count.flatMap { $0 >= 0 ? $0 : nil }
        }
    }

    let hosts: [Host]
    let users: [AccessUser]

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hosts = try container.decode([Host].self, forKey: .hosts)
        users = try container.decode([AccessUser].self, forKey: .users)
        guard Set(hosts.map(\.id)).count == hosts.count,
              Set(users.map(\.id)).count == users.count,
              users.allSatisfy({ !$0.id.isEmpty && !$0.username.isEmpty }) else {
            throw DecodingError.dataCorruptedError(forKey: .hosts, in: container, debugDescription: "Host access response is incomplete or duplicated.")
        }
    }
    private enum CodingKeys: String, CodingKey { case hosts, users }
}

enum HostUpdateTarget: String, CaseIterable, Identifiable {
    case inspur, ovhcloud
    var id: String { rawValue }
    var title: String { self == .inspur ? "Inspur" : "OVH" }
}

enum HostUpdateView: String, CaseIterable, Identifiable {
    case pending, history, installed
    var id: String { rawValue }
    var title: String { rawValue.capitalized }
}

struct HostUpdateEnvelope: Decodable {
    struct Status: Decodable {
        struct Policy: Decodable {
            let nonSecurityDelayHours: Int?
            let securityInstall: String?
            let allowedOrigin: String?
            let repositoryVerification: String?
            enum CodingKeys: String, CodingKey { case nonSecurityDelayHours = "non_security_delay_hours", securityInstall = "security_install", allowedOrigin = "allowed_origin", repositoryVerification = "repository_verification" }
        }
        struct Package: Decodable, Identifiable {
            let name: String
            let version: String
            let repository: String
            let origin: String
            let security: Bool
            let firstSeen: Int?
            let installedAt: Int?
            var id: String { "\(name):\(version):\(origin)" }
            enum CodingKeys: String, CodingKey { case name = "package", version, repository = "repo", origin, security, firstSeen = "first_seen", installedAt = "installed_at" }
            var reportedAt: Int? { installedAt ?? firstSeen }
        }
        struct InstalledPackage: Decodable, Identifiable {
            let name: String
            let version: String
            var id: String { "\(name):\(version)" }
            enum CodingKeys: String, CodingKey { case name = "package", version }
        }
        let schemaVersion: Int?
        let host: String?
        let runID: String?
        let checkedAt: String?
        let status: String
        let lastError: String?
        let pending: [Package]
        let installed: [InstalledPackage]
        let lastUpdatedPackages: [String]
        let lastUpdateAt: String?
        let policy: Policy?
        enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", host, runID = "run_id", checkedAt = "checked_at", status, lastError = "last_error", pending = "pending_updates", installed = "installed_packages", lastUpdatedPackages = "last_updated_packages", lastUpdateAt = "last_update_at", policy }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion)
            host = try container.decodeIfPresent(String.self, forKey: .host)
            runID = try container.decodeIfPresent(String.self, forKey: .runID)
            checkedAt = try container.decodeIfPresent(String.self, forKey: .checkedAt)
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
            lastError = try container.decodeIfPresent(String.self, forKey: .lastError)
            pending = try container.decodeIfPresent([Package].self, forKey: .pending) ?? []
            installed = try container.decodeIfPresent([InstalledPackage].self, forKey: .installed) ?? []
            lastUpdatedPackages = try container.decodeIfPresent([String].self, forKey: .lastUpdatedPackages) ?? []
            lastUpdateAt = try container.decodeIfPresent(String.self, forKey: .lastUpdateAt)
            policy = try container.decodeIfPresent(Policy.self, forKey: .policy)
        }
    }

    struct HistoryEntry: Decodable, Identifiable {
        let runID: String
        let status: String
        let occurredAt: String
        let isToday: Bool
        let packages: [String]
        let error: String?
        var id: String { runID }
        enum CodingKeys: String, CodingKey { case runID = "run_id", status, occurredAt = "occurred_at", isToday = "is_today", packages, error }
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            runID = try container.decode(String.self, forKey: .runID)
            status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
            occurredAt = try container.decodeIfPresent(String.self, forKey: .occurredAt) ?? ""
            isToday = try container.decodeIfPresent(Bool.self, forKey: .isToday) ?? false
            packages = try container.decodeIfPresent([String].self, forKey: .packages) ?? []
            error = try container.decodeIfPresent(String.self, forKey: .error)
        }
    }

    let host: HostUpdateTarget
    let status: Status
    let history: [HistoryEntry]

    enum CodingKeys: String, CodingKey { case host, status, history }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let host = HostUpdateTarget(rawValue: try container.decode(String.self, forKey: .host)) else {
            throw DecodingError.dataCorruptedError(forKey: .host, in: container, debugDescription: "Unsupported host update target.")
        }
        self.host = host
        status = try container.decode(Status.self, forKey: .status)
        history = try container.decode([HistoryEntry].self, forKey: .history)
    }
}

func hostOverviewMayLoad(hasAuth: Bool, isImpersonating: Bool) -> Bool { hasAuth && !isImpersonating }
func hostUpdateAgeHours(firstSeen: Int?, delayHours: Int?, now: Date = .now) -> Int? {
    guard let firstSeen, let delayHours, delayHours >= 0 else { return nil }
    return max(0, Int(now.timeIntervalSince1970 - Double(firstSeen)) / 3600)
}
