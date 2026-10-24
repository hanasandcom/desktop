import Foundation

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
