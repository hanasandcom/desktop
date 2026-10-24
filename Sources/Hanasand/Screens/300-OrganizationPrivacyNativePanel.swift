import AppKit
import SwiftUI

struct OrganizationPrivacyNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var snapshot: OrganizationPrivacySnapshot?
    @State private var selectedTab: Tab = .summary
    @State private var loading = false
    @State private var error = ""
    @State private var busy = false
    @State private var pendingIntent: OrganizationPrivacyIntent?
    @State private var actionConfirmation: OrganizationPrivacyAction?
    @State private var showDeletionForm = false
    @State private var deletionName = ""
    @State private var currentPassword = ""
    @State private var resultMessage = ""
    @State private var actionFailure = ""

    private enum Tab: String, CaseIterable, Identifiable {
        case summary = "Summary"
        case runs = "Runs"
        case requests = "Requests"
        case records = "Records"
        var id: String { rawValue }
    }

    private var organizationID: String { model.selectedOrganizationID }
    private var membership: DashboardOrganizationMembership? {
        model.organizationMemberships.first { $0.id == organizationID }
    }
    private var isImpersonating: Bool { model.isImpersonatingForOrganizationSwitch }
    private var membershipVerified: Bool {
        !organizationID.isEmpty
            && model.organizationDirectorySnapshotUserID == model.userIDForRequests
            && model.settings.selectedOrganizationUserID == model.userIDForRequests
            && membership?.status == "active"
    }
    private var scopeFingerprint: String {
        "\(model.userIDForRequests)|\(model.authTokenForRequests)|\(organizationID)|\(model.settings.impersonationToken)|\(model.settings.impersonatingUserID)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                ActionButton(title: loading ? "Loading…" : "Refresh", icon: "arrow.clockwise") { Task { await refresh(offset: 0) } }
                    .disabled(loading || !membershipVerified || isImpersonating)
                if let snapshot { Text(snapshot.organization.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.textSecondary) }
            }

            if organizationID.isEmpty {
                NativeEmptyState(title: "Select an organization", message: "Choose an active organization in the directory to review its privacy policy and history.")
                openDirectory
            } else if isImpersonating {
                NativeEmptyState(title: "Return to your own account", message: "Organization privacy history is unavailable while impersonating another account.")
            } else if !membershipVerified {
                NativeGroupPanel(title: "Verify organization access", subtitle: "Refresh the directory and active membership before viewing privacy history.") {
                    if let status = model.organizationDirectoryError, !status.isEmpty { Text(status).foregroundStyle(theme.danger) }
                    ActionButton(title: "Refresh organizations", icon: "arrow.clockwise") {
                        Task { await model.loadOrganizationDirectory() }
                    }
                }
            } else if loading && snapshot == nil {
                NativeEmptyState(title: "Loading privacy history", message: "Checking the selected organization and loading its current retention state.")
            } else if let snapshot {
                Picker("Privacy view", selection: $selectedTab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                switch selectedTab {
                case .summary: summary(snapshot)
                case .runs: recordList(title: "Retention runs", records: snapshot.runs, empty: "No retention runs have been recorded.")
                case .requests: recordList(title: "Privacy requests", records: snapshot.requests, empty: "No privacy requests have been recorded.")
                case .records: retentionRecords(snapshot)
                }
                privacyActions(snapshot)
                if !resultMessage.isEmpty { NativeNotice(message: resultMessage, tone: .info) }
                if !actionFailure.isEmpty { NativeNotice(message: actionFailure, title: "Privacy export failed", tone: .error) }
            } else {
                NativeEmptyState(title: "Privacy history unavailable", message: error.isEmpty ? "Refresh to load the selected organization’s privacy state." : error)
            }
            if !error.isEmpty, snapshot != nil { NativeNotice(message: error, title: "Privacy request failed", tone: .error) }
        }
        .task(id: scopeFingerprint) {
            snapshot = nil
            error = ""
            currentPassword = ""
            deletionName = ""
            pendingIntent = nil
            actionFailure = ""
            selectedTab = .summary
            guard membershipVerified, !isImpersonating else { return }
            await refresh(offset: 0)
        }
        .confirmationDialog(actionConfirmation?.title ?? "Confirm privacy action", isPresented: Binding(
            get: { actionConfirmation != nil }, set: { if !$0 { actionConfirmation = nil } }
        ), titleVisibility: .visible) {
            if let actionConfirmation {
                Button(actionConfirmation.buttonTitle, role: actionConfirmation.isDestructive ? .destructive : nil) {
                    let selected = actionConfirmation
                    self.actionConfirmation = nil
                    Task { await perform(selected) }
                }
            }
            Button("Cancel", role: .cancel) { actionConfirmation = nil; currentPassword = "" }
        } message: {
            if let actionConfirmation, let snapshot {
                Text(actionConfirmation.message(organization: snapshot.organization.name, retentionDays: snapshot.organization.retentionDays))
            }
        }
        .sheet(isPresented: $showDeletionForm, onDismiss: { if actionConfirmation == nil { currentPassword = ""; deletionName = "" } }) {
            deletionForm
        }
    }

    private var openDirectory: some View {
        ActionButton(title: "Open organization directory", icon: "building.2") {
            model.openNativeDashboard(path: "/organizations", label: "Organizations")
        }
    }

    @ViewBuilder
    private func summary(_ snapshot: OrganizationPrivacySnapshot) -> some View {
        NativeGroupPanel(title: "\(snapshot.organization.retentionDays)-day retention policy", subtitle: "Organization status: \(snapshot.organization.status)") {
            if !snapshot.protection.explanation.isEmpty {
                Text(snapshot.protection.explanation).font(.system(size: 12)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                metric("Protected records", snapshot.protection.protectedEvents)
                metric("Retention records", snapshot.protection.totalRetentionItems)
                metric("Access recovery holds", snapshot.protection.accessRecoveryHolds)
                metric("Immutable system events", snapshot.protection.immutableSystemEvents)
                metric("Webhook audit events", snapshot.protection.immutableWebhookAuditEvents)
                metric("Immutable log events", snapshot.protection.immutableLogEvents)
            }
        }
        NativeGroupPanel(title: "Recent activity", subtitle: "Latest records returned by the privacy service") {
            HStack(alignment: .top, spacing: 14) {
                countButton("Retention runs", count: snapshot.runs.count, tab: .runs)
                countButton("Privacy requests", count: snapshot.requests.count, tab: .requests)
            }
        }
    }

    @ViewBuilder
    private func privacyActions(_ snapshot: OrganizationPrivacySnapshot) -> some View {
        NativeGroupPanel(title: "Privacy actions", subtitle: "Actions use your current organization role and require a fresh authorization check.") {
            if let permissions = snapshot.permissions {
                HStack(spacing: 8) {
                    if permissions.canExport {
                        ActionButton(title: "Export data", icon: "square.and.arrow.down") { actionConfirmation = .export }
                            .disabled(busy || pendingIntent != nil)
                    }
                    if permissions.canRunRetention {
                        ActionButton(title: "Run retention", icon: "trash") { actionConfirmation = .runRetention }
                            .disabled(busy || pendingIntent != nil)
                    }
                    if permissions.canRequestDeletion && permissions.deletionRequiresReauthentication {
                        ActionButton(title: "Request deletion", icon: "exclamationmark.triangle") {
                            deletionName = ""; currentPassword = ""; showDeletionForm = true
                        }.disabled(busy || pendingIntent != nil)
                    }
                }
                if !permissions.canExport && !permissions.canRunRetention && !permissions.canRequestDeletion {
                    Text("Your current role can review privacy history but cannot run privacy actions.").font(.system(size: 12)).foregroundStyle(theme.textSecondary)
                }
            }
            if let pendingIntent {
                NativeNotice(message: "The \(pendingIntent.action.title.lowercased()) request \(pendingIntent.requestID) has an unresolved outcome. Refresh to reconcile it before submitting another action.", tone: .info)
            }
        }
    }

    private var deletionForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Request organization deletion").font(.system(size: 17, weight: .semibold))
            Text("Enter the exact organization name and your current password. Protected evidence remains; this may remove your organization access.")
                .font(.system(size: 12)).foregroundStyle(theme.textSecondary)
            TextField("Exact organization name", text: $deletionName)
            SecureField("Current password", text: $currentPassword)
            HStack {
                Button("Cancel") { showDeletionForm = false; deletionName = ""; currentPassword = "" }
                Spacer()
                Button("Review request", role: .destructive) { showDeletionForm = false; actionConfirmation = .delete }
                    .disabled(snapshot.map { deletionName != $0.organization.name } ?? true || currentPassword.isEmpty || busy)
            }
        }
        .padding(20).frame(width: 440)
    }

    private func metric(_ title: String, _ value: Int) -> some View {
        NativeGroupPanel(title: title, subtitle: "") {
            Text(value.formatted()).font(.system(size: 22, weight: .semibold, design: .rounded)).foregroundStyle(theme.text)
        }
    }

    private func countButton(_ title: String, count: Int, tab: Tab) -> some View {
        Button { selectedTab = tab } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                Text(count.formatted()).font(.system(size: 20, weight: .semibold, design: .rounded)).foregroundStyle(theme.text)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(11)
            .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func recordList(title: String, records: [OrganizationPrivacySnapshot.Record], empty: String) -> some View {
        NativeGroupPanel(title: title, subtitle: "Up to 20 most recent records") {
            if records.isEmpty { NativeEmptyState(title: "Nothing recorded", message: empty) }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(records) { record in recordCard(record) }
                }
            }
        }
    }

    @ViewBuilder
    private func retentionRecords(_ snapshot: OrganizationPrivacySnapshot) -> some View {
        NativeGroupPanel(title: "Retention records", subtitle: "Records are paged in batches of 50; fields shown are limited to the privacy history summary.") {
            if snapshot.items.isEmpty { NativeEmptyState(title: "No retention records", message: "This organization has no retention records on this page.") }
            else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 260), spacing: 10, alignment: .top)], alignment: .leading, spacing: 10) {
                    ForEach(snapshot.items) { record in recordCard(record) }
                }
            }
            HStack(spacing: 8) {
                ActionButton(title: "Previous", icon: "chevron.left") { Task { await refresh(offset: max(0, snapshot.itemPage.offset - 50)) } }
                    .disabled(loading || snapshot.itemPage.offset == 0)
                Text("Records \(snapshot.items.isEmpty ? 0 : snapshot.itemPage.offset + 1)–\(snapshot.itemPage.offset + snapshot.items.count)")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary)
                ActionButton(title: "Next", icon: "chevron.right") { if let next = snapshot.itemPage.nextOffset { Task { await refresh(offset: next) } } }
                    .disabled(loading || snapshot.itemPage.nextOffset == nil || (snapshot.itemPage.nextOffset ?? 0) > 100_000)
            }
        }
    }

    private func recordCard(_ record: OrganizationPrivacySnapshot.Record) -> some View {
        NativeGroupPanel(title: record.requestType?.replacingOccurrences(of: "_", with: " ").capitalized
                         ?? record.triggerType?.replacingOccurrences(of: "_", with: " ").capitalized
                         ?? "Retention record", subtitle: record.status?.capitalized ?? record.reason?.capitalized ?? "Record") {
            field("Record", record.recordID ?? record.id)
            if let requestID = record.requestID, !requestID.isEmpty { field("Request", requestID) }
            if let date = record.requestedAt ?? record.createdAt ?? record.processedAt, !date.isEmpty { field("Date", date) }
            if let completed = record.completedAt, !completed.isEmpty { field("Completed", completed) }
            if let error = record.error, !error.isEmpty { field("Error", error) }
        }
    }

    private func field(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
            Text(value).font(.system(size: 11)).foregroundStyle(theme.textSecondary).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @MainActor
    private func refresh(offset: Int) async {
        guard membershipVerified, !isImpersonating else { return }
        let organizationID = self.organizationID
        let userID = model.userIDForRequests
        let token = model.authTokenForRequests
        loading = true
        error = ""
        defer { loading = false }
        do {
            let client = try OrganizationPrivacyClient(settings: model.settings, organizationID: organizationID)
            let loaded = try await client.load(offset: offset)
            guard organizationID == self.organizationID,
                  userID == model.userIDForRequests,
                  token == model.authTokenForRequests,
                  !isImpersonating,
                  membershipVerified,
                  loaded.organization.id == organizationID else { throw OrganizationPrivacyError.organizationScopeChanged }
            snapshot = loaded
            if let pendingIntent, OrganizationPrivacyReconciliation.matchingRecord(in: loaded, intent: pendingIntent) != nil {
                resultMessage = "The request was found in privacy history. Its latest status is shown in the Requests or Runs tab."
                self.pendingIntent = nil
            }
        } catch { self.error = error.localizedDescription }
    }

    @MainActor
    private func perform(_ action: OrganizationPrivacyAction) async {
        guard let before = snapshot, membershipVerified, !isImpersonating, !busy, pendingIntent == nil else { return }
        busy = true; error = ""; resultMessage = ""; actionFailure = ""
        defer { busy = false; currentPassword = ""; deletionName = "" }
        let intent = OrganizationPrivacyIntent(action: action, requestID: UUID().uuidString.lowercased())
        do {
            let client = try OrganizationPrivacyClient(settings: model.settings, organizationID: organizationID)
            let receipt = try await client.perform(action, requestID: intent.requestID, expectedName: before.organization.name,
                                                   deletionName: action == .delete ? deletionName : nil,
                                                   currentPassword: action == .delete ? currentPassword : nil)
            guard organizationID == self.organizationID, membershipVerified, !isImpersonating else { throw OrganizationPrivacyError.organizationScopeChanged }
            if let data = receipt.exportFile {
                let panel = NSSavePanel(); panel.nameFieldStringValue = "\(before.organization.name)-privacy-export.json"
                panel.allowedContentTypes = [.json]; panel.canCreateDirectories = true
                if panel.runModal() == .OK, let url = panel.url { try data.write(to: url, options: .atomic); resultMessage = "Verified export saved to \(url.lastPathComponent). SHA-256: \(receipt.checksum ?? "")" }
                else { resultMessage = "Export completed, but the save dialog was canceled. The archive is no longer available from request history." }
            } else if action == .export && receipt.status == "failed" {
                actionFailure = "The service recorded this export request as failed. Review its status in Requests before trying again."
                selectedTab = .requests
                await refresh(offset: 0)
            } else {
                resultMessage = "\(action.title) request status: \(receipt.status). Refreshing privacy history."
                if let state = receipt.state { snapshot = state }
                await refresh(offset: 0)
            }
        } catch {
            if case OrganizationPrivacyError.permissionDenied = error {
                self.error = error.localizedDescription
            } else if case OrganizationPrivacyError.invalidDeletionConfirmation = error {
                self.error = error.localizedDescription
            } else if case OrganizationPrivacyError.requestFailed(let status, _) = error, (400...499).contains(status), status != 409 {
                self.error = error.localizedDescription
            } else {
                pendingIntent = intent
                resultMessage = "The service did not confirm the outcome. Refresh privacy history to reconcile request \(intent.requestID)."
            }
        }
    }
}
