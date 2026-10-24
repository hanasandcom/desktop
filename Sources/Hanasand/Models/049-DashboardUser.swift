import AppKit
import ApplicationServices
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct DashboardUserOrganization: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let slug: String
    let status: String
}

struct DashboardUser: Decodable, Identifiable {
    let id: String
    let name: String?
    let username: String?
    let email: String?
    let avatar: String?
    let active: Bool?
    let createdAt: String?
    let lastLoginAt: String?
    let deletionScheduledAt: String?
    let deactivatedAt: String?
    let deactivatedBy: String?
    let highestRoleID: String?
    let highestRoleName: String?
    let highestRolePriority: Int?
    let organization: String?
    let organizationIDs: String?
    let organizations: [DashboardUserOrganization]

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case username
        case email
        case avatar
        case active
        case createdAt = "created_at"
        case lastLoginAt = "last_login_at"
        case deletionScheduledAt = "deletion_scheduled_at"
        case deactivatedAt = "deactivated_at"
        case deactivatedBy = "deactivated_by"
        case highestRoleID = "highest_role_id"
        case highestRoleName = "highest_role_name"
        case highestRolePriority = "highest_role_priority"
        case organization
        case organizationIDs = "organization_ids"
        case organizations = "organization_memberships"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(String.self, forKey: .id)
        name = try values.decodeIfPresent(String.self, forKey: .name)
        username = try values.decodeIfPresent(String.self, forKey: .username)
        email = try values.decodeIfPresent(String.self, forKey: .email)
        avatar = try values.decodeIfPresent(String.self, forKey: .avatar)
        active = try values.decodeIfPresent(Bool.self, forKey: .active)
        createdAt = try values.decodeIfPresent(String.self, forKey: .createdAt)
        lastLoginAt = try values.decodeIfPresent(String.self, forKey: .lastLoginAt)
        deletionScheduledAt = try values.decodeIfPresent(String.self, forKey: .deletionScheduledAt)
        deactivatedAt = try values.decodeIfPresent(String.self, forKey: .deactivatedAt)
        deactivatedBy = try values.decodeIfPresent(String.self, forKey: .deactivatedBy)
        highestRoleID = try values.decodeIfPresent(String.self, forKey: .highestRoleID)
        highestRoleName = try values.decodeIfPresent(String.self, forKey: .highestRoleName)
        highestRolePriority = try values.decodeIfPresent(Int.self, forKey: .highestRolePriority)
        organization = try values.decodeIfPresent(String.self, forKey: .organization)
        organizationIDs = try values.decodeIfPresent(String.self, forKey: .organizationIDs)
        organizations = try values.decodeIfPresent([DashboardUserOrganization].self, forKey: .organizations) ?? []
    }

    var displayName: String { name?.isEmpty == false ? name! : id }
    var displayUsername: String { username?.isEmpty == false ? username! : id }
    var isReservedPlaceholder: Bool { ReservedUsernamePolicy.isReservedPlaceholder(id: id, username: username, active: active) }
    var roleLabel: String { highestRoleName ?? highestRoleID ?? "No role" }
    var ownerPickerLabel: String {
        [displayName, organization, id].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }.joined(separator: " · ")
    }
    var ownerSearchText: String {
        [id, name, organization, organizationIDs, highestRoleName, highestRoleID].compactMap { $0 }.joined(separator: " ").lowercased()
    }
}

struct DashboardUserDeletionReceipt: Decodable, Equatable {
    struct User: Decodable, Equatable {
        let id: String
        let deletionScheduledAt: String?

        enum CodingKeys: String, CodingKey {
            case id
            case deletionScheduledAt = "deletion_scheduled_at"
        }
    }

    let pendingDeletion: Bool
    let user: User

    enum CodingKeys: String, CodingKey {
        case pendingDeletion = "pending_deletion"
        case user
    }

    func confirmsDeletion(of expectedID: String) -> Bool {
        guard pendingDeletion, user.id == expectedID,
              let value = user.deletionScheduledAt,
              let date = Self.parseDate(value) else { return false }
        return date > Date()
    }

    static func parseDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}
