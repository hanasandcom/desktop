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

enum DashboardOrganizationDirectorySortKey: String, CaseIterable, Identifiable {
    case name
    case slug
    case status
    case members
    case created
    case lastActive

    var id: String { rawValue }

    var title: String {
        switch self {
        case .name: "Organization"
        case .slug: "Slug"
        case .status: "Status"
        case .members: "Members"
        case .created: "Created"
        case .lastActive: "Last active (UTC)"
        }
    }

    static func sorted(
        _ organizations: [DashboardDirectoryOrganization],
        by key: Self,
        ascending: Bool
    ) -> [DashboardDirectoryOrganization] {
        let dates = Dictionary(uniqueKeysWithValues: organizations.map { organization in
            (organization.id, (created: parseUTCDate(organization.createdAt), lastActive: parseUTCDate(organization.lastActiveAt)))
        })

        return organizations.sorted { lhs, rhs in
            let comparison: ComparisonResult
            switch key {
            case .name:
                comparison = lhs.name.localizedStandardCompare(rhs.name)
            case .slug:
                comparison = lhs.slug.localizedStandardCompare(rhs.slug)
            case .status:
                comparison = lhs.status.localizedStandardCompare(rhs.status)
            case .members:
                comparison = compare(lhs.memberCount ?? Int.min, rhs.memberCount ?? Int.min)
            case .created:
                comparison = compare(dates[lhs.id]?.created, dates[rhs.id]?.created)
            case .lastActive:
                comparison = compare(dates[lhs.id]?.lastActive, dates[rhs.id]?.lastActive)
            }

            if comparison != .orderedSame {
                return ascending ? comparison == .orderedAscending : comparison == .orderedDescending
            }

            let nameComparison = lhs.name.localizedStandardCompare(rhs.name)
            if nameComparison != .orderedSame { return nameComparison == .orderedAscending }
            return lhs.id.localizedStandardCompare(rhs.id) == .orderedAscending
        }
    }

    private static func compare<T: Comparable>(_ lhs: T?, _ rhs: T?) -> ComparisonResult {
        switch (lhs, rhs) {
        case let (lhs?, rhs?):
            if lhs < rhs { return .orderedAscending }
            if lhs > rhs { return .orderedDescending }
            return .orderedSame
        case (nil, .some): return .orderedAscending
        case (.some, nil): return .orderedDescending
        case (nil, nil): return .orderedSame
        }
    }

    private static func compare(_ lhs: Int, _ rhs: Int) -> ComparisonResult {
        if lhs < rhs { return .orderedAscending }
        if lhs > rhs { return .orderedDescending }
        return .orderedSame
    }

    private static func parseUTCDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }
}

struct OrganizationDirectoryNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State private var searchText = ""
    @State private var sortKey: DashboardOrganizationDirectorySortKey = .name
    @State private var sortAscending = true
    @State private var createName = ""
    @State private var createFirstWatchlistKind = OrganizationWatchlistKind.domain
    @State private var createFirstWatchlistValue = ""
    @State private var createFirstWatchlistNotes = ""
    @State private var createInviteEmails = ""
    @State private var createInviteRole = "reader"
    @State private var createSetupStatus = ""

    private var normalizedCreateName: String {
        DashboardOrganizationCreationPolicy.normalizedName(createName)
    }

    private var normalizedCreateInviteEmails: [String] {
        DashboardOrganizationCreationPolicy.inviteEmails(createInviteEmails)
    }

    private var invalidCreateInviteEmails: [String] {
        DashboardOrganizationCreationPolicy.invalidInviteEmails(createInviteEmails)
    }

    private var createNameAlreadyUsed: Bool {
        DashboardOrganizationCreationPolicy.nameIsInUse(normalizedCreateName, organizations: model.organizationDirectory)
    }

    private var filteredOrganizations: [DashboardDirectoryOrganization] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let matchingOrganizations = query.isEmpty ? model.organizationDirectory : model.organizationDirectory.filter {
            $0.name.localizedCaseInsensitiveContains(query)
                || $0.slug.localizedCaseInsensitiveContains(query)
                || $0.status.localizedCaseInsensitiveContains(query)
        }
        return DashboardOrganizationDirectorySortKey.sorted(matchingOrganizations, by: sortKey, ascending: sortAscending)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "building.2")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(theme.accent)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Organization directory")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(theme.text)
                    Text("Directory visibility does not grant organization membership.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer()
                if model.isLoadingOrganizationDirectory {
                    ProgressView().controlSize(.small)
                } else {
                    Button("Refresh") { Task { await model.loadOrganizationDirectory() } }
                        .buttonStyle(.bordered)
                }
            }

            if model.isImpersonatingForOrganizationSwitch {
                NativeNotice(message: "Return to your own account before switching organizations.", tone: .info)
            }
            if let error = model.organizationDirectoryError {
                NativeNotice(message: error, title: "Organizations unavailable")
            }
            if !createSetupStatus.isEmpty {
                NativeNotice(message: createSetupStatus, title: "Organization setup")
            }
            if model.isImpersonatingForOrganizationSwitch {
                Label("Workspace selection is paused during impersonation", systemImage: "person.crop.circle.badge.exclam")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            } else if !model.selectedOrganizationID.isEmpty {
                HStack(spacing: 10) {
                    Label("Current workspace: \(model.selectedOrganizationName ?? model.selectedOrganizationID)", systemImage: "building.2.crop.circle")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.text)
                    Spacer()
                    Button("Use personal workspace") { model.usePersonalWorkspace() }
                        .buttonStyle(.plain)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(theme.accent)
                }
                .padding(12)
                .background(theme.card)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            } else {
                Label("Current workspace: Personal", systemImage: "person.crop.circle")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
            }

            if model.organizationDirectorySnapshotUserID != model.userIDForRequests {
                NativeNotice(message: "Refresh to verify current memberships before switching.", tone: .info)
            }

            SearchFieldRow(placeholder: "Search organizations by name, slug, or status", text: $searchText)

            HStack(spacing: 10) {
                Text("\(filteredOrganizations.count) of \(model.organizationDirectory.count) organizations")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityAddTraits(.updatesFrequently)
                Spacer(minLength: 8)
                Picker("Sort organizations", selection: $sortKey) {
                    ForEach(DashboardOrganizationDirectorySortKey.allCases) { key in
                        Text(key.title).tag(key)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .accessibilityLabel("Sort organizations")

                Button {
                    sortAscending.toggle()
                } label: {
                    Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.bordered)
                .accessibilityLabel(sortAscending ? "Sort ascending" : "Sort descending")
                .help(sortAscending ? "Sort ascending" : "Sort descending")
            }

            if model.hasHanasandAuth {
                NativeGroupPanel(title: "Create an organization", subtitle: "Create a workspace and optionally prepare its first shared term and team invitations") {
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Organization name", text: $createName)
                            .textFieldStyle(.roundedBorder)
                            .disabled(model.isLoadingOrganizationDirectory || model.isImpersonatingForOrganizationSwitch)
                        if createNameAlreadyUsed {
                            Text("An organization with this name or slug is already listed.")
                                .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger)
                        } else if !normalizedCreateName.isEmpty {
                            Text("Slug · \(DashboardOrganizationCreationPolicy.slug(for: normalizedCreateName))")
                                .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary)
                        }

                        DisclosureGroup("First shared watchlist term (optional)") {
                            VStack(alignment: .leading, spacing: 8) {
                                Picker("Term type", selection: $createFirstWatchlistKind) {
                                    ForEach(OrganizationWatchlistKind.allCases, id: \.self) { kind in Text(kind.rawValue.capitalized).tag(kind) }
                                }
                                .pickerStyle(.menu)
                                TextField("company.com, supplier, or actor", text: $createFirstWatchlistValue)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Monitoring notes (optional)", text: $createFirstWatchlistNotes)
                                    .textFieldStyle(.roundedBorder)
                                if createFirstWatchlistValue.count > 240 || createFirstWatchlistNotes.count > 2000 {
                                    Text("Terms must be at most 240 characters and notes at most 2,000 characters.")
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.danger)
                                }
                            }
                            .padding(.top, 7)
                        }
                        .font(.system(size: 11, weight: .semibold))

                        DisclosureGroup("First team invitations (optional)") {
                            VStack(alignment: .leading, spacing: 8) {
                                TextField("name@example.com, another@example.com", text: $createInviteEmails, axis: .vertical)
                                    .lineLimit(2...4).textFieldStyle(.roundedBorder)
                                Picker("Invitation role", selection: $createInviteRole) {
                                    ForEach(["reader", "editor", "admin"], id: \.self) { role in Text(role.capitalized).tag(role) }
                                }
                                .pickerStyle(.menu)
                                if let invalid = invalidCreateInviteEmails.first {
                                    Text("Invalid email: \(invalid)").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.danger)
                                } else if normalizedCreateInviteEmails.count > 25 {
                                    Text("Invite up to 25 people at a time.").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.danger)
                                } else if !normalizedCreateInviteEmails.isEmpty {
                                    Text("\(normalizedCreateInviteEmails.count) unique recipient\(normalizedCreateInviteEmails.count == 1 ? "" : "s")")
                                        .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                                }
                            }
                            .padding(.top, 7)
                        }
                        .font(.system(size: 11, weight: .semibold))

                        Button(model.isLoadingOrganizationDirectory ? "Creating organization…" : "Create organization") {
                            Task { await createOrganization() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.isLoadingOrganizationDirectory || model.isImpersonatingForOrganizationSwitch
                                  || normalizedCreateName.isEmpty || createNameAlreadyUsed
                                  || !invalidCreateInviteEmails.isEmpty || normalizedCreateInviteEmails.count > 25
                                  || createFirstWatchlistValue.count > 240 || createFirstWatchlistNotes.count > 2000)
                    }
                    if model.isImpersonatingForOrganizationSwitch {
                        Text("Return to your own account to create an organization.")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }

            if model.isLoadingOrganizationDirectory && model.organizationDirectory.isEmpty {
                NativeEmptyState(title: "Loading organizations", message: "Checking directory visibility and your active memberships.")
            } else if model.organizationDirectory.isEmpty {
                NativeEmptyState(title: "No organizations found", message: "Create an organization or refresh to check your active memberships.")
            } else if filteredOrganizations.isEmpty {
                NativeEmptyState(title: "No matches", message: "No organizations match this search.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(filteredOrganizations) { organization in
                        organizationCard(organization)
                    }
                }
            }

            if !model.selectedOrganizationID.isEmpty {
                OrganizationMembersNativePanel()
            }
        }
        .task(id: model.selectedDashboardPath) {
            await model.loadOrganizationDirectory()
        }
    }

    @MainActor
    private func createOrganization() async {
        let previousOrganizationID = model.selectedOrganizationID
        let accountID = model.userIDForRequests
        let sessionToken = model.authTokenForRequests
        let watchlistValue = createFirstWatchlistValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let inviteEmails = normalizedCreateInviteEmails
        createSetupStatus = ""

        await model.createOrganization(named: normalizedCreateName)
        guard model.organizationDirectoryError == nil else { return }
        createName = ""

        let organizationID = model.selectedOrganizationID
        guard !organizationID.isEmpty, organizationID != previousOrganizationID else {
            createSetupStatus = "Creation was not confirmed in the active directory. Refresh organizations before trying again."
            return
        }
        guard accountID == model.userIDForRequests, sessionToken == model.authTokenForRequests,
              !model.isImpersonatingForOrganizationSwitch else {
            createSetupStatus = "Organization creation may have completed, but the account session changed before setup could be verified. Refresh the directory before retrying."
            return
        }

        var setupMessages: [String] = ["Organization created."]
        if !watchlistValue.isEmpty {
            await model.loadOrganizationWatchlists()
            guard model.selectedOrganizationID == organizationID, accountID == model.userIDForRequests,
                  sessionToken == model.authTokenForRequests,
                  !model.isImpersonatingForOrganizationSwitch else {
                createSetupStatus = "Organization created. Setup stopped because the active organization or session changed."
                return
            }
            if model.canWriteSelectedOrganizationWatchlists {
                model.organizationWatchlistDraftKind = createFirstWatchlistKind
                model.organizationWatchlistDraftValue = watchlistValue
                let notes = createFirstWatchlistNotes.trimmingCharacters(in: .whitespacesAndNewlines)
                model.organizationWatchlistDraftNotes = notes.isEmpty ? "Initial shared watchlist term from organization setup." : notes
                await model.saveOrganizationWatchlistDraft()
                if !model.organizationWatchlistStatus.hasPrefix("Saved ") {
                    setupMessages.append("First shared term was not added. Finish it from Organization Watchlists.")
                } else {
                    setupMessages.append("First shared term added.")
                    createFirstWatchlistValue = ""
                    createFirstWatchlistNotes = ""
                }
            } else {
                setupMessages.append("First shared term could not be confirmed. Add it from Organization Watchlists.")
            }
        }

        if !inviteEmails.isEmpty {
            await model.loadOrganizationMembers()
            guard model.selectedOrganizationID == organizationID, accountID == model.userIDForRequests,
                  sessionToken == model.authTokenForRequests,
                  !model.isImpersonatingForOrganizationSwitch else {
                createSetupStatus = "Organization created. Setup stopped because the active organization or session changed."
                return
            }
            if model.organizationMembersCanManage {
                model.organizationInviteEmailDraft = inviteEmails.joined(separator: ", ")
                model.organizationInviteRoleDraft = createInviteRole
                await model.inviteOrganizationMembers()
                if model.organizationMembersStatus.hasPrefix("Invited ") {
                    setupMessages.append("Team invitations sent.")
                    createInviteEmails = ""
                    createInviteRole = "reader"
                } else {
                    setupMessages.append("Invitations were not confirmed. Finish them from Organization Members.")
                }
            } else {
                setupMessages.append("Invitations could not be confirmed. Finish them from Organization Members.")
            }
        }
        createSetupStatus = setupMessages.joined(separator: " ")
    }

    @ViewBuilder
    private func organizationCard(_ organization: DashboardDirectoryOrganization) -> some View {
        let member = model.organizationMemberships.first { $0.id == organization.id && $0.status == "active" }
        let current = model.selectedOrganizationID == organization.id
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(organization.name)
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(theme.text)
                        .lineLimit(2)
                    Text(organization.slug.isEmpty ? organization.id : organization.slug)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)
                Text(organization.status.capitalized)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(organization.status == "active" ? theme.green : theme.textTertiary)
            }

            Text("\(organization.memberCount.map(String.init) ?? "Unavailable") active members")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)

            VStack(alignment: .leading, spacing: 3) {
                Text("Created (UTC) · \(organization.createdAt.map(Self.formatUTCDate) ?? "Unavailable")")
                Text("Last active (UTC) · \(organization.lastActiveAt.map(Self.formatUTCTimestamp) ?? "No recorded activity")")
            }
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(theme.textTertiary)
            .lineLimit(1)
            .minimumScaleFactor(0.8)

            if current {
                Label("Current workspace", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(theme.green)
            } else if member != nil && model.canSwitchToOrganization(organization) {
                Button("Switch to \(organization.name)") {
                    Task { await model.selectOrganization(organization) }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isLoadingOrganizationDirectory)
            } else if organization.status != "active" {
                Text("This organization is not active.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            } else {
                Text("No verified active membership for switching.")
                    .font(.system(size: 11))
                    .foregroundStyle(theme.textTertiary)
            }
        }
        .padding(13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(theme.divider, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private static func formatUTCDate(_ value: String) -> String {
        formatUTC(value, dateStyle: .medium, timeStyle: .none)
    }

    private static func formatUTCTimestamp(_ value: String) -> String {
        formatUTC(value, dateStyle: .medium, timeStyle: .short)
    }

    private static func formatUTC(_ value: String, dateStyle: DateFormatter.Style, timeStyle: DateFormatter.Style) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let date = formatter.date(from: value) ?? {
            formatter.formatOptions = [.withInternetDateTime]
            return formatter.date(from: value)
        }()
        guard let date else { return "Unavailable" }

        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_GB")
        dateFormatter.timeZone = TimeZone(secondsFromGMT: 0)
        dateFormatter.dateStyle = dateStyle
        dateFormatter.timeStyle = timeStyle
        return dateFormatter.string(from: date)
    }
}
