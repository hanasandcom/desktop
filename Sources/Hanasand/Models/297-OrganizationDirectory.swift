import Foundation

struct DashboardDirectoryOrganization: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let slug: String
    let status: String
    let memberCount: Int?
    let createdAt: String?
    let lastActiveAt: String?

    init(id: String, name: String, slug: String, status: String, memberCount: Int?, createdAt: String? = nil, lastActiveAt: String? = nil) {
        self.id = id
        self.name = name
        self.slug = slug
        self.status = status
        self.memberCount = memberCount
        self.createdAt = createdAt
        self.lastActiveAt = lastActiveAt
    }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, status
        case memberCount = "member_count"
        case createdAt = "created_at"
        case lastActiveAt = "last_active_at"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decodeIfPresent(String.self, forKey: .slug) ?? ""
        status = try container.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        if let count = try? container.decode(Int.self, forKey: .memberCount) {
            memberCount = count
        } else if let count = try? container.decode(String.self, forKey: .memberCount) {
            memberCount = Int(count)
        } else {
            memberCount = nil
        }
        createdAt = try container.decodeIfPresent(String.self, forKey: .createdAt)
        lastActiveAt = try container.decodeIfPresent(String.self, forKey: .lastActiveAt)
    }
}

struct DashboardOrganizationMembership: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let role: String
    let status: String

    enum CodingKeys: String, CodingKey {
        case id, name, role
        case status = "lifecycleStatus"
    }
}

struct DashboardDirectoryOrganizationsEnvelope: Decodable {
    let organizations: [DashboardDirectoryOrganization]
}

struct DashboardOrganizationMembershipsEnvelope: Decodable {
    let organizations: [DashboardOrganizationMembership]
}

struct DashboardIdentityOrganization: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let slug: String?
    let lifecycleStatus: String
    let role: String
    let memberCount: Int?

    var directoryOrganization: DashboardDirectoryOrganization {
        DashboardDirectoryOrganization(
            id: id,
            name: name,
            slug: slug ?? "",
            status: lifecycleStatus,
            memberCount: memberCount
        )
    }

    var activeMembership: DashboardOrganizationMembership {
        // The identity list contains only active memberships for the signed-in user.
        DashboardOrganizationMembership(id: id, name: name, role: role, status: "active")
    }

    enum CodingKeys: String, CodingKey {
        case id, name, slug, lifecycleStatus, role, memberCount
        case memberCountSnake = "member_count"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        slug = try container.decodeIfPresent(String.self, forKey: .slug)
        lifecycleStatus = try container.decode(String.self, forKey: .lifecycleStatus)
        role = try container.decode(String.self, forKey: .role)
        if let count = try? container.decode(Int.self, forKey: .memberCount) {
            memberCount = count
        } else {
            memberCount = try? container.decode(Int.self, forKey: .memberCountSnake)
        }
        guard !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !role.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: container, debugDescription: "Organization membership is missing its identity fields")
        }
    }
}

struct DashboardIdentityOrganizationsEnvelope: Decodable {
    let organizations: [DashboardIdentityOrganization]
}

struct DashboardOrganizationDirectorySnapshot {
    let organizations: [DashboardDirectoryOrganization]
    let memberships: [DashboardOrganizationMembership]
}

enum DashboardOrganizationRouteContext {
    static func requestedOrganizationID(from query: [String: String]) -> String? {
        ["org", "organizationId", "orgId"]
            .compactMap { query[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }
}

enum DashboardOrganizationSwitchPolicy {
    static func canSwitch(
        organizationID: String,
        organizationStatus: String,
        membershipStatus: String?,
        isAuthenticated: Bool,
        isOwnAccount: Bool,
        isImpersonating: Bool
    ) -> Bool {
        isAuthenticated && isOwnAccount && !isImpersonating
            && !organizationID.isEmpty
            && organizationStatus == "active"
            && membershipStatus == "active"
    }
}

enum DashboardOrganizationCreationPolicy {
    static func normalizedName(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func slug(for name: String) -> String {
        normalizedName(name).lowercased()
            .replacingOccurrences(of: "[^a-z0-9]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    static func nameIsInUse(_ value: String, organizations: [DashboardDirectoryOrganization]) -> Bool {
        let name = normalizedName(value).lowercased()
        guard !name.isEmpty else { return false }
        let slug = slug(for: value)
        return organizations.contains { organization in
            normalizedName(organization.name).lowercased() == name
                || organization.slug.lowercased() == slug
                || organization.id.lowercased() == slug
        }
    }

    static func invalidInviteEmails(_ value: String) -> [String] {
        let emails = value.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = emails.filter { seen.insert($0).inserted }
        return unique.filter { email in
            email.count > 254
                || email.range(of: "^[^\\s@]+@[^\\s@]+\\.[^\\s@]+$", options: .regularExpression) == nil
        }
    }

    static func inviteEmails(_ value: String) -> [String] {
        value.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() }
            .filter { !$0.isEmpty }
            .reduce(into: [String]()) { result, email in
                if !result.contains(email) { result.append(email) }
            }
    }
}
