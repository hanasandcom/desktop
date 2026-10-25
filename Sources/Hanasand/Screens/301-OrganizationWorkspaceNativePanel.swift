import AppKit
import SwiftUI

private func captureOrganizationWorkspaceScreenResult<Value>(_ operation: () async throws -> Value) async -> Result<Value, Error> {
    do { return .success(try await operation()) }
    catch { return .failure(error) }
}

struct OrganizationWorkspaceNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var section: OrganizationWorkspaceSection
    @State private var settingsPage: OrganizationWorkspaceSettingsPage?
    @State private var draft: OrganizationWorkspaceSettings?
    @State private var events: [OrganizationWorkspaceRecord] = []
    @State private var cases: [OrganizationWorkspaceRecord] = []
    @State private var activityPage = OrganizationWorkspaceActivityPage.summaryUnavailable
    @State private var warnings: [String] = []
    @State private var isLoading = false
    @State private var isSaving = false
    @State private var error = ""
    @State private var organizationRouteError = ""
    @State private var status = ""
    @State private var loadedOrganizationID = ""
    @State private var confirmSave = false
    @State private var search = ""
    @State private var activitySearch = ""
    @State private var activityFilter = "All"
    @State private var selectedActivityID = ""

    init(section: OrganizationWorkspaceSection = .overview) {
        _section = State(initialValue: section)
    }

    private var organizationID: String { model.selectedOrganizationID }
    private var requestedOrganizationID: String? {
        DashboardOrganizationRouteContext.requestedOrganizationID(from: model.selectedNativeDashboardQuery)
    }
    private var impersonating: Bool { !model.settings.impersonationToken.isEmpty || !model.settings.impersonatingUserID.isEmpty }
    private var canEdit: Bool {
        guard let settingsPage else { return false }
        return OrganizationWorkspacePolicy.canEdit(settings: settingsPage, selectedOrganizationID: organizationID,
            signedInUserID: model.userIDForRequests, isAuthenticated: model.hasHanasandAuth, isImpersonating: impersonating)
    }
    private var canViewInvites: Bool {
        ["owner", "admin"].contains(settingsPage?.organization.role?.lowercased() ?? "")
    }
    private var visibleRecords: [OrganizationWorkspaceRecord] {
        let records = events + cases
        let needle = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return records.filter { needle.isEmpty || "\($0.title) \($0.status) \($0.severity) \($0.id)".localizedCaseInsensitiveContains(needle) }
            .sorted { ($0.updatedAt.isEmpty ? $0.createdAt : $0.updatedAt) > ($1.updatedAt.isEmpty ? $1.createdAt : $1.updatedAt) }
    }
    private var activityEntries: [OrganizationWorkspaceActivityEntry] {
        let eventRows = events.map { record in
            OrganizationWorkspaceActivityEntry(id: "event-\(record.id)", kind: .event, occurredAt: record.updatedAt,
                title: record.title, detail: [record.severity, record.status].filter { !$0.isEmpty }.joined(separator: " · "), status: record.status,
                subjectID: record.id, contextPath: "/ti/workbench", contextQuery: ["organizationId": organizationID, "alertId": record.id],
                metadata: ["Severity · \(record.severity)", "Status · \(record.status)"])
        }
        let caseRows = cases.map { record in
            OrganizationWorkspaceActivityEntry(id: "case-\(record.id)", kind: .caseRecord, occurredAt: record.updatedAt.isEmpty ? record.createdAt : record.updatedAt,
                title: record.title, detail: [record.severity, record.status].filter { !$0.isEmpty }.joined(separator: " · "), status: record.status,
                subjectID: record.id, contextPath: "/cases/\(record.id)", contextQuery: ["organizationId": organizationID],
                metadata: ["Severity · \(record.severity)", "Status · \(record.status)"])
        }
        let needle = activitySearch.trimmingCharacters(in: .whitespacesAndNewlines)
        return (activityPage.entries + eventRows + caseRows)
            .filter { activityFilter == "All" || $0.kind.rawValue == activityFilter }
            .filter { needle.isEmpty || "\($0.kind.rawValue) \($0.title) \($0.detail) \($0.status) \($0.subjectID) \($0.metadata.joined(separator: " "))".localizedCaseInsensitiveContains(needle) }
            .sorted { $0.occurredAt > $1.occurredAt }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            NativeGroupPanel(title: "Organization workspace", subtitle: "Settings, scoped monitoring records, and recent activity") {
                HStack(spacing: 10) {
                    Picker("Organization section", selection: $section) {
                        ForEach(OrganizationWorkspaceSection.allCases) { item in Text(item.rawValue).tag(item) }
                    }.pickerStyle(.segmented).labelsHidden()
                    ActionButton(title: isLoading ? "Refreshing…" : "Refresh", icon: "arrow.clockwise") { Task { await refresh() } }
                        .disabled(isLoading || (organizationID.isEmpty && requestedOrganizationID == nil))
                }
                if !status.isEmpty { Text(status).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled) }
                if !error.isEmpty { NativeNotice(message: error) }
                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in NativeNotice(message: warning) }
                if isLoading { HStack(spacing: 8) { ProgressView().controlSize(.small); Text("Loading organization data…").font(.system(size: 11)).foregroundStyle(theme.textSecondary) } }
            }

            if !model.hasHanasandAuth {
                NativeEmptyState(title: "Sign in required", message: "Sign in to view organization data.")
            } else if !organizationRouteError.isEmpty {
                NativeGroupPanel(title: "Organization link unavailable", subtitle: "The linked workspace was not opened") {
                    Text(organizationRouteError).font(.system(size: 11)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    ActionButton(title: "Retry", icon: "arrow.clockwise") { Task { await refresh() } }
                }
            } else if let requestedOrganizationID, requestedOrganizationID != organizationID {
                NativeEmptyState(title: "Opening linked organization", message: "Checking active membership before loading its workspace.")
            } else if organizationID.isEmpty {
                NativeEmptyState(title: "Select an organization", message: "Choose an active organization to view its settings and monitoring records.")
            } else if section == .settings {
                settingsContent
            } else if section == .overview {
                overviewContent
            } else if section == .activity {
                activityContent
            } else {
                recordsContent
            }
        }
        .task(id: "\(organizationID)|\(requestedOrganizationID ?? "")|\(section.rawValue)") { await refresh() }
        .confirmationDialog("Save organization settings?", isPresented: $confirmSave, titleVisibility: .visible) {
            Button("Save settings", role: .none) { Task { await save() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates the selected organization’s name, slug, event and webhook policies, lifecycle, and retention period.")
        }
    }

    private var overviewContent: some View {
        let overview = OrganizationWorkspaceOverview(events: events, cases: cases, activity: activityPage,
            organizationID: organizationID, role: settingsPage?.organization.role, canViewInvites: canViewInvites)
        return VStack(alignment: .leading, spacing: 14) {
            if let page = settingsPage {
                NativeGroupPanel(title: "Workspace summary", subtitle: "Current membership and watchlist status") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 10) {
                        overviewSummaryMetric("Your role", value: overview.role?.capitalized ?? "Unavailable")
                        overviewSummaryMetric("Active members", value: overview.activeMemberCount.map(String.init) ?? "Unavailable")
                        if canViewInvites {
                            overviewSummaryMetric("Pending invites", value: overview.pendingInviteCount.map(String.init) ?? "Unavailable")
                        }
                        overviewSummaryMetric("Active watchlists", value: overview.activeWatchlistCount.map(String.init) ?? "Unavailable")
                        overviewSummaryMetric("Paused watchlists", value: overview.pausedWatchlistCount.map(String.init) ?? "Unavailable")
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack(spacing: 8) { overviewActions }
                        VStack(alignment: .leading, spacing: 8) { overviewActions }
                    }
                }
                NativeGroupPanel(title: page.organization.name, subtitle: "Organization overview · \(page.organization.role?.capitalized ?? "Member") · \(page.organization.status.capitalized)") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 145), alignment: .leading)], alignment: .leading, spacing: 10) {
                        overviewMetric("Events", value: overview.eventCount, symbol: "bell.badge")
                        overviewMetric("Cases", value: overview.caseCount, symbol: "folder")
                        overviewMetric("Open cases", value: overview.openCaseCount, symbol: "exclamationmark.bubble")
                    }
                    if let latestActivity = overview.latestActivity {
                        Label("Latest activity · \(formatDateText(latestActivity, fallback: latestActivity))", systemImage: "clock")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    } else if !isLoading {
                        Text("No organization events or cases have been recorded yet.")
                            .font(.system(size: 11))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }

            NativeGroupPanel(title: "Recent activity", subtitle: "Latest events and cases in the selected organization") {
                if visibleRecords.isEmpty && !isLoading {
                    NativeEmptyState(title: error.isEmpty ? "No recent activity" : "Activity unavailable",
                                     message: error.isEmpty ? "New organization events and cases will appear here." : "Refresh to retry the organization-scoped feeds.")
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)], alignment: .leading, spacing: 10) {
                        ForEach(Array(visibleRecords.prefix(6))) { record in recordCard(record) }
                    }
                }
            }
        }
    }

    private func overviewMetric(_ title: String, value: Int, symbol: String) -> some View {
        HStack(spacing: 9) {
            Image(systemName: symbol).foregroundStyle(theme.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
                Text(value.formatted()).font(.system(size: 17, weight: .bold, design: .rounded)).foregroundStyle(theme.text)
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func overviewSummaryMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
            Text(value).font(.system(size: 15, weight: .bold, design: .rounded)).foregroundStyle(theme.text)
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 45, alignment: .leading)
        .padding(10)
        .background(theme.card)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    @ViewBuilder private var overviewActions: some View {
        ForEach(OrganizationWorkspaceSummaryDestination.allCases, id: \.self) { destination in
            ActionButton(title: destination.title, icon: destination == .team ? "person.2" : "list.bullet.rectangle") {
                model.openNativeDashboard(path: destination.path, label: destination.label, query: ["organizationId": organizationID])
            }
        }
    }

    @ViewBuilder private var settingsContent: some View {
        if let page = settingsPage, let draft {
            NativeGroupPanel(title: page.organization.name, subtitle: "\(page.organization.role?.capitalized ?? "Member") · \(page.organization.status.capitalized)") {
                workspaceField("Organization name", value: fieldBinding(\.name), editable: canEdit)
                workspaceField("Slug", value: fieldBinding(\.slug), editable: canEdit)
                workspaceField("Webhook policy", value: fieldBinding(\.defaultWebhookPolicy), editable: canEdit,
                               choices: ["active_destinations", "manual_selection", "disabled"])
                workspaceField("Event visibility", value: fieldBinding(\.alertVisibilityPolicy), editable: canEdit,
                               choices: ["members", "admins", "owners"])
                workspaceField("Lifecycle", value: fieldBinding(\.lifecycleStatus), editable: canEdit,
                               choices: ["active", "archived"])
                HStack(spacing: 10) {
                    Text("Retention days").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textSecondary)
                    TextField("365", value: intBinding(\.retentionDays), format: .number).textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 120).disabled(!canEdit)
                    Text("30–2555 days").font(.system(size: 10)).foregroundStyle(theme.textTertiary)
                }
                if canEdit {
                    HStack {
                        ActionButton(title: isSaving ? "Saving…" : "Save settings", icon: "checkmark") { confirmSave = true }
                            .disabled(isSaving || draft == page.settings || !OrganizationWorkspacePolicy.valid(draft))
                        ActionButton(title: "Reset", icon: "arrow.uturn.backward") { self.draft = page.settings }
                            .disabled(isSaving || draft == page.settings)
                    }
                } else {
                    Text(impersonating ? "Return to your own account to edit organization settings." : "Only an organization owner or admin can edit settings.")
                        .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                }
                if !status.isEmpty { Text(status).font(.system(size: 11)).foregroundStyle(theme.textSecondary) }
            }
        } else if !isLoading && error.isEmpty {
            NativeEmptyState(title: "Organization settings unavailable", message: "Refresh to load settings for this organization.")
        }
    }

    @ViewBuilder private var recordsContent: some View {
        NativeGroupPanel(title: section == .events ? "Events and cases" : "Recent organization activity",
                         subtitle: section == .events ? "Latest organization-scoped records" : "Activity is derived from the available event and case feeds") {
            SearchFieldRow(placeholder: "Search records", text: $search)
            if visibleRecords.isEmpty && !isLoading {
                NativeEmptyState(title: error.isEmpty ? "No records found" : "Records could not be loaded",
                                 message: error.isEmpty ? "No organization events or cases match this view." : "Refresh to retry the organization-scoped feeds.")
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 12, alignment: .top)], alignment: .leading, spacing: 10) {
                ForEach(visibleRecords) { record in
                    recordCard(record)
                }
            }
        }
    }

    private var activityContent: some View {
        NativeGroupPanel(title: "Organization activity", subtitle: "Team, watchlists, destinations, deliveries, events, and cases for the selected organization") {
            SearchFieldRow(placeholder: "Search organization activity", text: $activitySearch)
            Picker("Activity type", selection: $activityFilter) {
                Text("All activity").tag("All")
                ForEach(OrganizationWorkspaceActivityKind.allCases) { kind in Text(kind.rawValue).tag(kind.rawValue) }
            }.pickerStyle(.menu)
            if activityEntries.isEmpty && !isLoading {
                NativeEmptyState(title: error.isEmpty ? "No matching activity" : "Activity is incomplete",
                    message: error.isEmpty ? "Try another search or activity type." : "Some organization activity sources could not be loaded.")
            }
            VStack(alignment: .leading, spacing: 12) {
                LazyVStack(spacing: 8) {
                    ForEach(activityEntries.prefix(120)) { entry in
                        activityTimelineRow(entry)
                    }
                }
                if let selected = activityEntries.first(where: { $0.id == selectedActivityID }) ?? activityEntries.first {
                    activityDetails(selected).frame(maxWidth: .infinity, alignment: .leading)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func activityTimelineRow(_ entry: OrganizationWorkspaceActivityEntry) -> some View {
        let dateLabel = formatDateText(entry.occurredAt, fallback: entry.occurredAt)
        let selected = selectedActivityID == entry.id
        return Button { selectedActivityID = entry.id } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 7) {
                    Text(entry.kind.rawValue.uppercased())
                        .font(.system(size: 9, weight: .bold))
                        .foregroundColor(theme.accent)
                    Spacer(minLength: 0)
                    Text(dateLabel).font(.system(size: 9)).foregroundColor(theme.textTertiary)
                }
                Text(entry.title).font(.system(size: 12, weight: .semibold)).foregroundColor(theme.text)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                Text(entry.detail).font(.system(size: 10)).foregroundColor(theme.textSecondary)
                    .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(9).frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? theme.cardRaised : theme.backgroundElevated)
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }.buttonStyle(.plain)
    }

    private func activityDetails(_ entry: OrganizationWorkspaceActivityEntry) -> some View {
        NativeGroupPanel(title: entry.title, subtitle: "\(entry.kind.rawValue) · \(entry.status)") {
            Text(entry.detail).font(.system(size: 11)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            Text("Record \(entry.subjectID)").font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
            if !entry.occurredAt.isEmpty { Text("Updated \(entry.occurredAt)").font(.system(size: 10)).foregroundStyle(theme.textTertiary).textSelection(.enabled) }
            ForEach(Array(entry.metadata.enumerated()), id: \.offset) { _, value in
                Text(value).font(.system(size: 10)).foregroundStyle(theme.textSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 7) { activityActions(entry) }
                VStack(alignment: .leading, spacing: 7) { activityActions(entry) }
            }
        }
    }

    @ViewBuilder private func activityActions(_ entry: OrganizationWorkspaceActivityEntry) -> some View {
        ActionButton(title: "Open in Desktop", icon: "arrow.up.right.square") {
            model.openNativeDashboard(path: entry.contextPath, label: entry.kind.rawValue, detailID: entry.subjectID, query: entry.contextQuery)
        }
        ActionButton(title: "Copy details", icon: "doc.on.doc") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(([entry.kind.rawValue, entry.title, entry.detail, entry.occurredAt] + entry.metadata).joined(separator: "\n"), forType: .string)
        }
        ActionButton(title: "Copy record ID", icon: "number") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(entry.subjectID, forType: .string)
        }
    }

    private func recordCard(_ record: OrganizationWorkspaceRecord) -> some View {
        NativeGroupPanel(title: record.title, subtitle: [record.status, record.severity].filter { !$0.isEmpty }.joined(separator: " · ")) {
            Text(record.id).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary).lineLimit(2).textSelection(.enabled)
            Text(record.updatedAt.isEmpty ? record.createdAt : record.updatedAt).font(.system(size: 10)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
        }
    }

    private func workspaceField(_ title: String, value: Binding<String>, editable: Bool, choices: [String]? = nil) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textSecondary).frame(width: 130, alignment: .leading)
            if let choices {
                Picker(title, selection: value) { ForEach(choices, id: \.self) { Text($0.replacingOccurrences(of: "_", with: " ").capitalized).tag($0) } }
                    .labelsHidden().disabled(!editable).frame(maxWidth: 280)
            } else {
                TextField(title, text: value).textFieldStyle(.roundedBorder).disabled(!editable).frame(maxWidth: 420)
            }
            Spacer(minLength: 0)
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func fieldBinding(_ keyPath: WritableKeyPath<OrganizationWorkspaceSettings, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: keyPath] ?? "" }, set: { draft?[keyPath: keyPath] = $0 })
    }
    private func intBinding(_ keyPath: WritableKeyPath<OrganizationWorkspaceSettings, Int>) -> Binding<Int> {
        Binding(get: { draft?[keyPath: keyPath] ?? 365 }, set: { draft?[keyPath: keyPath] = $0 })
    }

    @MainActor private func refresh() async {
        guard model.hasHanasandAuth else { return }
        organizationRouteError = ""
        if let requestedOrganizationID, requestedOrganizationID != organizationID {
            let selected = await model.selectOrganizationFromDeepLink(requestedOrganizationID)
            guard !Task.isCancelled else { return }
            guard selected, model.selectedOrganizationID == requestedOrganizationID else {
                organizationRouteError = model.organizationDirectoryError ?? "The linked organization is not available through an active membership."
                return
            }
        }
        guard !Task.isCancelled, !organizationID.isEmpty else { return }
        let requestedOrganization = organizationID
        let requestedUser = model.userIDForRequests
        let requestedToken = model.authTokenForRequests
        if loadedOrganizationID != requestedOrganization {
            settingsPage = nil
            draft = nil
            events = []
            cases = []
            activityPage = .summaryUnavailable
            warnings = []
            loadedOrganizationID = requestedOrganization
        }
        isLoading = true; error = ""; status = ""
        defer { if requestedOrganization == organizationID { isLoading = false } }
        do {
            let client = try OrganizationWorkspaceClient(settings: model.settings, organizationID: requestedOrganization)
            async let settingsResult = captureOrganizationWorkspaceScreenResult { try await client.loadSettings() }
            async let loadedRecords = client.loadRecords()
            let (pageResult, recordResult) = await (settingsResult, loadedRecords)
            guard requestedOrganization == organizationID,
                  requestedUser == model.userIDForRequests, requestedToken == model.authTokenForRequests,
                  !impersonating else { return }

            var sourceWarnings = recordResult.warnings
            switch pageResult {
            case let .success(page):
                guard page.organization.id == requestedOrganization else {
                    sourceWarnings.append("Settings could not be loaded: the response organization did not match the selected workspace.")
                    break
                }
                settingsPage = page
                draft = page.settings
            case let .failure(failure):
                sourceWarnings.append("Settings could not be loaded: \(failure.localizedDescription)")
            }
            if let loadedEvents = recordResult.events { events = loadedEvents }
            if let loadedCases = recordResult.cases { cases = loadedCases }

            let canViewInvites = ["owner", "admin"].contains(settingsPage?.organization.role?.lowercased() ?? "")
            if section == .activity || section == .overview {
                let activityResult = await captureOrganizationWorkspaceScreenResult {
                    try await client.loadActivity(includeInvites: canViewInvites)
                }
                guard requestedOrganization == organizationID,
                      requestedUser == model.userIDForRequests, requestedToken == model.authTokenForRequests,
                      !impersonating else { return }
                switch activityResult {
                case let .success(page):
                    let mergedPage = page.retainingUnavailableSources(from: activityPage)
                    activityPage = canViewInvites ? mergedPage : OrganizationWorkspaceActivityPage(
                        entries: mergedPage.entries.filter { $0.kind != .invite }, warnings: mergedPage.warnings
                    )
                    sourceWarnings.append(contentsOf: page.warnings)
                case let .failure(failure):
                    sourceWarnings.append("Organization activity could not be loaded: \(failure.localizedDescription)")
                }
            }
            var seenWarnings = Set<String>()
            warnings = sourceWarnings.filter { seenWarnings.insert($0).inserted }
            if warnings.isEmpty {
                status = "Loaded settings, \(events.count) events, and \(cases.count) cases."
            } else {
                status = "Some organization sources could not be refreshed. Available data remains shown; refresh to retry."
            }
        } catch {
            guard requestedOrganization == organizationID,
                  requestedUser == model.userIDForRequests, requestedToken == model.authTokenForRequests else { return }
            self.error = error.localizedDescription
            status = "Organization data could not be refreshed."
        }
    }

    @MainActor private func save() async {
        guard canEdit, !isSaving, let draft else { return }
        let requestedOrganization = organizationID
        let requestedUser = model.userIDForRequests
        let requestedToken = model.authTokenForRequests
        isSaving = true; error = ""; status = "Checking current organization access…"
        defer { isSaving = false }
        do {
            let client = try OrganizationWorkspaceClient(settings: model.settings, organizationID: requestedOrganization)
            _ = try await client.updateSettings(draft) { [weak model] in
                guard let model else { return false }
                return model.hasHanasandAuth && model.selectedOrganizationID == requestedOrganization
                    && model.userIDForRequests == requestedUser && model.authTokenForRequests == requestedToken
                    && model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty
            }
            guard requestedOrganization == organizationID, requestedUser == model.userIDForRequests,
                  requestedToken == model.authTokenForRequests, !impersonating else { throw OrganizationWorkspaceError.scopeChanged }
            status = "Settings saved. Refreshing current values…"
            await refresh()
            status = "Settings saved."
        } catch {
            self.error = error.localizedDescription
            status = "Settings were not confirmed. Refresh before trying again."
        }
    }
}
