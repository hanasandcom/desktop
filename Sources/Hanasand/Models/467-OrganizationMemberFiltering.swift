import Foundation

struct OrganizationMemberRouteFocus: Equatable {
    enum Kind: Equatable { case member, invite }

    let kind: Kind
    let id: String

    static func resolve(query: [String: String], members: [DashboardOrganizationMember], invites: [DashboardOrganizationInvite]) -> OrganizationMemberRouteFocus? {
        if let inviteID = query["inviteId"], invites.contains(where: { $0.id == inviteID }) {
            return OrganizationMemberRouteFocus(kind: .invite, id: inviteID)
        }
        if let memberID = query["memberId"], members.contains(where: { $0.userId == memberID }) {
            return OrganizationMemberRouteFocus(kind: .member, id: memberID)
        }
        switch query["focus"] {
        case "invites":
            return invites.first.map { OrganizationMemberRouteFocus(kind: .invite, id: $0.id) }
        case "members":
            return members.first.map { OrganizationMemberRouteFocus(kind: .member, id: $0.userId) }
        default:
            return nil
        }
    }
}

struct OrganizationMemberFiltering: Equatable {
    var searchText = ""
    var role = "all"
    var status = "all"

    var hasActiveFilters: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || role != "all"
            || status != "all"
    }

    func matching(_ members: [DashboardOrganizationMember]) -> [DashboardOrganizationMember] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return members.filter { member in
            let matchesSearch = query.isEmpty
                || member.name.localizedCaseInsensitiveContains(query)
                || (member.email ?? "").localizedCaseInsensitiveContains(query)
                || member.userId.localizedCaseInsensitiveContains(query)
                || member.role.localizedCaseInsensitiveContains(query)
                || member.status.localizedCaseInsensitiveContains(query)
            let matchesRole = role == "all" || member.role.caseInsensitiveCompare(role) == .orderedSame
            let matchesStatus = status == "all" || member.status.caseInsensitiveCompare(status) == .orderedSame
            return matchesSearch && matchesRole && matchesStatus
        }
    }

    func matchingInvites(_ invites: [DashboardOrganizationInvite]) -> [DashboardOrganizationInvite] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return invites }
        return invites.filter {
            $0.email.localizedCaseInsensitiveContains(query)
                || $0.role.localizedCaseInsensitiveContains(query)
                || $0.status.localizedCaseInsensitiveContains(query)
                || $0.id.localizedCaseInsensitiveContains(query)
        }
    }

    static func countsByRole(in members: [DashboardOrganizationMember]) -> [String: Int] {
        counts(in: members, value: \.role)
    }

    static func countsByStatus(in members: [DashboardOrganizationMember]) -> [String: Int] {
        counts(in: members, value: \.status)
    }

    private static func counts(in members: [DashboardOrganizationMember], value: KeyPath<DashboardOrganizationMember, String>) -> [String: Int] {
        members.reduce(into: [:]) { counts, member in
            let key = member[keyPath: value].lowercased()
            counts[key, default: 0] += 1
        }
    }
}
