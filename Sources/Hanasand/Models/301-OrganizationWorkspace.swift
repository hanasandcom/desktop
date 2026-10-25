import Foundation

struct OrganizationWorkspaceSettings: Codable, Equatable {
    var name: String
    var slug: String
    var defaultWebhookPolicy: String
    var alertVisibilityPolicy: String
    var lifecycleStatus: String
    var retentionDays: Int
}

struct OrganizationWorkspaceSettingsPage: Decodable, Equatable {
    struct Organization: Decodable, Equatable {
        let id: String
        let name: String
        let slug: String?
        let status: String
        let role: String?
        enum CodingKeys: String, CodingKey { case id, name, slug, role, lifecycleStatus }
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            slug = try c.decodeIfPresent(String.self, forKey: .slug)
            status = try c.decodeIfPresent(String.self, forKey: .lifecycleStatus) ?? "unknown"
            role = try c.decodeIfPresent(String.self, forKey: .role)
        }
    }
    struct Permissions: Decodable, Equatable {
        let canEdit: Bool
        let editableFields: [String]
    }
    let organization: Organization
    let settings: OrganizationWorkspaceSettings
    let permissions: Permissions

    private struct SettingsPayload: Decodable {
        let defaultWebhookPolicy: String
        let alertVisibilityPolicy: String
        let lifecycleStatus: String
        let retentionDays: Int
    }

    enum CodingKeys: String, CodingKey { case organization, settings, permissions }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        organization = try c.decode(Organization.self, forKey: .organization)
        let values = try c.decode(SettingsPayload.self, forKey: .settings)
        settings = OrganizationWorkspaceSettings(name: organization.name, slug: organization.slug ?? "",
            defaultWebhookPolicy: values.defaultWebhookPolicy, alertVisibilityPolicy: values.alertVisibilityPolicy,
            lifecycleStatus: values.lifecycleStatus, retentionDays: values.retentionDays)
        permissions = try c.decode(Permissions.self, forKey: .permissions)
    }
}

struct OrganizationWorkspaceRecord: Decodable, Identifiable, Equatable {
    let id: String
    let title: String
    let status: String
    let severity: String
    let updatedAt: String
    let createdAt: String
    let organizationId: String?

    init(id: String, title: String, status: String, severity: String, updatedAt: String, createdAt: String, organizationId: String?) {
        self.id = id
        self.title = title
        self.status = status
        self.severity = severity
        self.updatedAt = updatedAt
        self.createdAt = createdAt
        self.organizationId = organizationId
    }

    enum CodingKeys: String, CodingKey {
        case id, title, status, severity, updatedAt, updated_at, createdAt, created_at
        case organizationId, organization_id
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decodeIfPresent(String.self, forKey: .title) ?? id
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? "unknown"
        severity = try c.decodeIfPresent(String.self, forKey: .severity) ?? ""
        updatedAt = try c.decodeIfPresent(String.self, forKey: .updatedAt) ?? c.decodeIfPresent(String.self, forKey: .updated_at) ?? ""
        createdAt = try c.decodeIfPresent(String.self, forKey: .createdAt) ?? c.decodeIfPresent(String.self, forKey: .created_at) ?? ""
        organizationId = try c.decodeIfPresent(String.self, forKey: .organizationId) ?? c.decodeIfPresent(String.self, forKey: .organization_id)
        guard !id.isEmpty else { throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "Organization record has no identifier") }
    }
}

struct OrganizationWorkspaceRecordPage: Decodable {
    let organizationId: String?
    let items: [OrganizationWorkspaceRecord]
    let cases: [OrganizationWorkspaceRecord]
    let warnings: [String]

    enum CodingKeys: String, CodingKey { case organizationId, items, cases, warnings }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        organizationId = try c.decodeIfPresent(String.self, forKey: .organizationId)
        items = try c.decodeIfPresent([OrganizationWorkspaceRecord].self, forKey: .items) ?? []
        cases = try c.decodeIfPresent([OrganizationWorkspaceRecord].self, forKey: .cases) ?? []
        warnings = try c.decodeIfPresent([String].self, forKey: .warnings) ?? []
    }

    var records: [OrganizationWorkspaceRecord] { cases.isEmpty ? items : cases }
}

enum OrganizationWorkspaceActivityKind: String, CaseIterable, Identifiable, Equatable {
    case event = "Event", caseRecord = "Case", delivery = "Delivery", member = "Team", invite = "Invitation", watchlist = "Watchlist", destination = "Destination"
    var id: String { rawValue }
}

struct OrganizationWorkspaceActivityEntry: Identifiable, Equatable {
    let id: String
    let kind: OrganizationWorkspaceActivityKind
    let occurredAt: String
    let title: String
    let detail: String
    let status: String
    let subjectID: String
    let contextPath: String
    let contextQuery: [String: String]
    let metadata: [String]
}

struct OrganizationWorkspaceActivityPage {
    let entries: [OrganizationWorkspaceActivityEntry]
    let warnings: [String]

    static var summaryUnavailable: OrganizationWorkspaceActivityPage {
        OrganizationWorkspaceActivityPage(entries: [], warnings: [
            "Organization members activity could not be loaded.",
            "Organization invites activity could not be loaded.",
            "Organization watchlists activity could not be loaded.",
        ])
    }
}

struct OrganizationWorkspaceSettingsReceipt: Decodable {
    let organization: OrganizationWorkspaceSettingsPage.Organization?
    let settings: SettingsPayload?
    let settingsMutationReceipt: MutationReceipt?

    struct SettingsPayload: Decodable {
        let defaultWebhookPolicy: String
        let alertVisibilityPolicy: String
        let lifecycleStatus: String
        let retentionDays: Int
    }

    struct MutationReceipt: Decodable {
        let schemaVersion: String
        let organizationId: String
        let lifecycleStatus: String
        let mutatedFields: [String]
    }
}

enum OrganizationWorkspaceSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case settings = "Settings"
    case events = "Events & cases"
    case activity = "Activity"
    var id: String { rawValue }
}

struct OrganizationWorkspaceOverview: Equatable {
    let eventCount: Int
    let caseCount: Int
    let openCaseCount: Int
    let latestActivity: String?
    let role: String?
    let activeMemberCount: Int?
    let pendingInviteCount: Int?
    let activeWatchlistCount: Int?
    let pausedWatchlistCount: Int?

    init(events: [OrganizationWorkspaceRecord], cases: [OrganizationWorkspaceRecord],
         activity: OrganizationWorkspaceActivityPage, organizationID: String, role: String?, canViewInvites: Bool) {
        eventCount = events.count
        caseCount = cases.count
        openCaseCount = cases.filter { !["closed", "resolved", "false_positive", "suppressed"].contains($0.status.lowercased()) }.count
        latestActivity = (events + cases)
            .compactMap { record -> String? in
                let value = record.updatedAt.isEmpty ? record.createdAt : record.updatedAt
                return value.isEmpty ? nil : value
            }
            .max()

        self.role = role?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        activeMemberCount = Self.count(kind: .member, matching: "active", activity: activity, organizationID: organizationID)
        pendingInviteCount = canViewInvites
            ? Self.count(kind: .invite, matching: "pending", activity: activity, organizationID: organizationID)
            : nil
        activeWatchlistCount = Self.count(kind: .watchlist, matching: "active", activity: activity, organizationID: organizationID)
        pausedWatchlistCount = Self.count(kind: .watchlist, matching: "paused", activity: activity, organizationID: organizationID)
    }

    private static func count(kind: OrganizationWorkspaceActivityKind, matching status: String,
                              activity: OrganizationWorkspaceActivityPage, organizationID: String) -> Int? {
        let sourceName: String
        switch kind {
        case .member: sourceName = "members"
        case .invite: sourceName = "invites"
        case .watchlist: sourceName = "watchlists"
        default: return nil
        }
        guard !organizationID.isEmpty,
              !activity.warnings.contains(where: { $0.localizedCaseInsensitiveContains("organization \(sourceName)") }) else {
            return nil
        }
        let rows = activity.entries.filter { $0.kind == kind }
        guard rows.allSatisfy({ $0.contextQuery["organizationId"] == organizationID }) else { return nil }
        return rows.filter { $0.status.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(status) == .orderedSame }.count
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

enum OrganizationWorkspaceSummaryDestination: CaseIterable, Hashable {
    case team
    case watchlists

    var path: String {
        switch self {
        case .team: "/organizations/team"
        case .watchlists: "/watchlists"
        }
    }

    var label: String {
        switch self {
        case .team: "Organization Team"
        case .watchlists: "Watchlists"
        }
    }

    var title: String {
        switch self {
        case .team: "Manage team"
        case .watchlists: "Manage watchlists"
        }
    }
}

enum OrganizationWorkspacePolicy {
    static let editableSettings: Set<String> = ["name", "slug", "defaultWebhookPolicy", "alertVisibilityPolicy", "retentionDays"]

    static func canEdit(settings: OrganizationWorkspaceSettingsPage, selectedOrganizationID: String,
                        signedInUserID: String, isAuthenticated: Bool, isImpersonating: Bool) -> Bool {
        isAuthenticated && !isImpersonating && !selectedOrganizationID.isEmpty
            && settings.organization.id == selectedOrganizationID
            && settings.permissions.canEdit
            && settings.permissions.editableFields.contains("name")
            && ["owner", "admin"].contains(settings.organization.role?.lowercased() ?? "")
    }

    static func valid(_ value: OrganizationWorkspaceSettings) -> Bool {
        let name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let slug = value.slug.trimmingCharacters(in: .whitespacesAndNewlines)
        return !name.isEmpty && name.count <= 120
            && !slug.isEmpty && slug.count <= 80
            && slug.range(of: "^[a-z0-9]+(?:-[a-z0-9]+)*$", options: .regularExpression) != nil
            && ["active_destinations", "manual_selection", "disabled"].contains(value.defaultWebhookPolicy)
            && ["members", "admins", "owners"].contains(value.alertVisibilityPolicy)
            && ["active", "archived"].contains(value.lifecycleStatus)
            && (30...2555).contains(value.retentionDays)
    }
}
