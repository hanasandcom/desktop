import Foundation

struct DashboardDirectoryOrganization: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let slug: String
    let status: String
    let memberCount: Int?
    let createdAt: String?
    let lastActiveAt: String?

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
