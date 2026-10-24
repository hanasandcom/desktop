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

private enum MonitoringCasePanel: String, CaseIterable {
    case overview = "Overview"
    case comments = "Comments"
    case events = "Check runs"
    case history = "History"
    case notifications = "Notifications"
    case development = "Development"
}

private enum PendingCaseChange {
    case status(String, String?)
    case severity(String)
    case notifications(Bool)
    case comment(String)
    case confirmResolution(String)
    var title: String {
        switch self {
        case .status(let status, _): return status == "resolved" ? "Resolve case?" : status == "closed" ? "Close case?" : "Change case status?"
        case .severity: return "Change severity?"
        case .notifications(let enabled): return enabled ? "Enable notifications?" : "Disable notifications?"
        case .comment: return "Add comment?"
        case .confirmResolution: return "Confirm resolution review?"
        }
    }
    var message: String {
        switch self {
        case .status(let status, _): return status == "resolved" || status == "closed" ? "The case will be updated with your resolution comment." : "The case status will be updated."
        case .severity: return "The monitoring case severity will be updated."
        case .notifications(let enabled): return "Notifications will be \(enabled ? "enabled" : "disabled") for this case."
        case .comment: return "Your comment will be added to the monitoring case."
        case .confirmResolution: return "Confirm that you reviewed the automated resolution."
        }
    }
}

struct MonitoringCasesNativePanel: View {
    @EnvironmentObject private var model: DesktopAgentModel
    @Environment(\.desktopTheme) private var theme
    @State private var panel: MonitoringCasePanel = .overview
    @State private var pending: PendingCaseChange?
    @State private var confirmingCaseReview = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                SearchFieldRow(placeholder: "Search cases", text: $model.monitoringCaseSearch)
                ActionButton(title: "Refresh", icon: "arrow.clockwise") { Task { await model.refreshMonitoringCasesForReview() } }
            }
            if model.monitoringCaseMutationNeedsReview {
                NativeNotice(message: "A previous case change could not be confirmed. Refresh the current case, review its history, then acknowledge before making another change.")
                HStack(spacing: 8) {
                    ActionButton(title: model.monitoringCaseMutationReviewRefreshed ? "Case records refreshed" : "Refresh for review", icon: "arrow.clockwise") {
                        Task { await model.refreshMonitoringCasesForReview() }
                    }
                    .disabled(model.isLoadingNativeDashboard || model.monitoringCaseMutationReviewRefreshed)
                    ActionButton(title: "Acknowledge review", icon: "checkmark.shield") {
                        confirmingCaseReview = true
                    }
                    .disabled(!model.monitoringCaseMutationReviewRefreshed)
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["active", "all", "open", "in_progress", "resolved", "closed"], id: \.self) { value in
                        FilterChip(title: value.replacingOccurrences(of: "_", with: " ").capitalized, active: model.monitoringCaseStatusFilter == value) { model.monitoringCaseStatusFilter = value }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["all", "low", "medium", "high", "critical"], id: \.self) { value in
                        FilterChip(title: value.capitalized, active: model.monitoringCaseSeverityFilter == value) { model.monitoringCaseSeverityFilter = value }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["all", "unassigned"] + Array(Set(model.monitoringCases.map(\.assignedOwner).filter { !$0.isEmpty })).sorted(), id: \.self) { owner in
                        FilterChip(title: owner == "all" ? "All owners" : owner == "unassigned" ? "Unassigned" : owner, active: model.monitoringCaseOwnerFilter == owner) { model.monitoringCaseOwnerFilter = owner }
                    }
                }
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["all", "human", "ai", "automation", "unknown"], id: \.self) { value in
                        FilterChip(title: value == "all" ? "All resolutions" : value.capitalized, active: model.monitoringCaseResolutionFilter == value) { model.monitoringCaseResolutionFilter = value }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(["all", "pending", "confirmed"], id: \.self) { value in
                        FilterChip(title: value == "all" ? "All reviews" : value.capitalized, active: model.monitoringCaseReviewFilter == value) { model.monitoringCaseReviewFilter = value }
                    }
                }
                .fixedSize(horizontal: true, vertical: false)
            }

            if !model.nativeDashboardStatus.isEmpty && (model.nativeDashboardStatus.hasPrefix("Could not") || model.nativeDashboardStatus.hasPrefix("Sign in")) {
                NativeNotice(message: model.nativeDashboardStatus)
            }
            if model.nativeDashboardStatus == "Loading case details" || model.nativeDashboardStatus == "Loading check run page" {
                HStack(spacing: 8) { ProgressView().controlSize(.small); Text(model.nativeDashboardStatus).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary) }
            }

            if model.monitoringCases.isEmpty {
                if model.isLoadingNativeDashboard {
                    NativeEmptyState(title: "Loading monitoring cases", message: "Retrieving your cases from the selected account.")
                } else if !model.hasHanasandAuth {
                    NativeEmptyState(title: "Sign in required", message: "Sign in to view monitoring cases.")
                } else {
                    NativeEmptyState(title: "No monitoring cases", message: "Health-check cases will appear here when a check reports an incident.")
                }
            } else if model.filteredMonitoringCases.isEmpty {
                NativeEmptyState(title: "No matching cases", message: "Try a different search or filter.")
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 255), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                    ForEach(model.filteredMonitoringCases) { item in
                        NativeGroupPanel(title: item.title, subtitle: "\(item.status.replacingOccurrences(of: "_", with: " ").capitalized) · \(item.severity.capitalized)") {
                            Text(item.summary.isEmpty ? "No summary provided." : item.summary)
                                .font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                                .lineLimit(4).textSelection(.enabled)
                            Text("Updated \(item.updatedAt.isEmpty ? item.lastSeenAt : item.updatedAt) · \(item.occurrences) occurrences")
                                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(1)
                            ActionButton(title: model.selectedMonitoringCase?.id == item.id ? "Selected" : "Review case", icon: "arrow.right") {
                                panel = .overview
                                model.selectedMonitoringCase = nil
                                Task { await model.loadMonitoringCaseDetail(id: item.id) }
                            }
                        }
                    }
                }
            }

            if let item = model.selectedMonitoringCase {
                detail(item)
            }
        }
        .alert(pending?.title ?? "Confirm change", isPresented: Binding(get: { pending != nil }, set: { if !$0 { pending = nil } })) {
            Button("Cancel", role: .cancel) { pending = nil }
            Button("Confirm", role: .destructive) { applyPendingChange() }
        } message: { Text(pending?.message ?? "") }
        .confirmationDialog("Acknowledge this case review?", isPresented: $confirmingCaseReview, titleVisibility: .visible) {
            Button("I reviewed the refreshed case history", role: .destructive) {
                model.acknowledgeMonitoringCaseMutationReview()
            }
            Button("Keep changes locked", role: .cancel) {}
        } message: {
            Text("The earlier change remains unconfirmed. Check the refreshed case status and history before continuing.")
        }
    }

    @ViewBuilder private func detail(_ item: MonitoringCase) -> some View {
        NativeGroupPanel(title: item.title, subtitle: "\(item.id) · Assigned owner: \(item.assignedOwner.isEmpty ? "Unassigned" : item.assignedOwner)") {
            if let context = model.nativeCaseHandoffContext {
                Text("Opened from \(context.route ?? "case link") · Alert \(context.alertID ?? "not specified") · Organization \(context.organizationID ?? "current")")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(theme.textTertiary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                ForEach(MonitoringCasePanel.allCases, id: \.self) { value in
                    FilterChip(title: value.rawValue, active: panel == value) { panel = value }
                }
                ActionButton(title: "Close details", icon: "xmark") { model.selectedMonitoringCase = nil }
            }
            Group {
                switch panel {
                case .overview: overview(item)
                case .comments: comments(item)
                case .events: events(item)
                case .history: entries(item.history, empty: "No case history recorded.")
                case .notifications: notifications(item)
                case .development: CasesDevelopmentNativePanel(caseID: item.id, organizationID: item.organizationId)
                }
            }
        }
    }

    @ViewBuilder private func overview(_ item: MonitoringCase) -> some View {
        Text(item.summary).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
        Text("First seen: \(item.createdAt)\nLast seen: \(item.lastSeenAt)\nRecovered: \(item.resolvedAt.isEmpty ? "Not recovered" : item.resolvedAt)\nOccurrences: \(item.occurrences)")
            .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
        Text("Health checks update recovery automatically. Closing a case does not mark the check as recovered.")
            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textSecondary)
        if item.canManage && model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty && !model.monitoringCaseMutationNeedsReview {
            HStack(spacing: 8) {
                ForEach(["low", "medium", "high", "critical"], id: \.self) { value in
                    FilterChip(title: value.capitalized, active: item.severity == value) { pending = .severity(value) }
                }
            }
            HStack(spacing: 8) {
                ActionButton(title: item.status == "in_progress" ? "Set open" : "Start progress", icon: "arrow.trianglehead.2.clockwise") {
                    pending = .status(item.status == "open" ? "in_progress" : "open", nil)
                }
                if !["resolved", "closed"].contains(item.status) {
                    ActionButton(title: "Resolve", icon: "checkmark.circle") { pending = .status("resolved", model.monitoringCaseComment) }
                        .disabled(model.monitoringCaseComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    ActionButton(title: "Close", icon: "xmark.circle") { pending = .status("closed", model.monitoringCaseComment) }
                        .disabled(model.monitoringCaseComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            if !["resolved", "closed"].contains(item.status) {
                TextField("Resolution comment (required to resolve or close)", text: $model.monitoringCaseComment, axis: .vertical)
                    .lineLimit(2...5).textFieldStyle(.roundedBorder)
            } else {
                ActionButton(title: "Reopen case", icon: "arrow.uturn.backward") { pending = .status("open", nil) }
            }
        } else {
            Text("This case is read-only for the current session.").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
        }
        if let resolution = item.resolution { evidence("Resolution", resolution) }
        if item.needsHumanReview && item.canManage && model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty && !model.monitoringCaseMutationNeedsReview,
           let resolutionID = MonitoringCase.stringValue(item.resolution, key: "id") {
            ActionButton(title: "Confirm resolution", icon: "checkmark.shield") { pending = .confirmResolution(resolutionID) }
        }
        if let check = item.currentCheck { evidence("Current check configuration", check) }
        if !item.relatedChecks.isEmpty { entries(item.relatedChecks, empty: "No related checks.") }
        if let diagnostics = item.diskDiagnostics { evidence("Disk diagnostics", diagnostics) }
    }

    @ViewBuilder private func comments(_ item: MonitoringCase) -> some View {
        entries(item.comments, empty: "No comments yet.")
        if item.canManage && model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty && !model.monitoringCaseMutationNeedsReview {
            TextField("Add a comment", text: $model.monitoringCaseComment, axis: .vertical).lineLimit(2...5).textFieldStyle(.roundedBorder)
            ActionButton(title: "Add comment", icon: "text.bubble") { pending = .comment(model.monitoringCaseComment) }
                .disabled(model.monitoringCaseComment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    @ViewBuilder private func events(_ item: MonitoringCase) -> some View {
        Text("\(item.occurrences) occurrences · \(item.eventTotal) recorded runs · Snapshot \(item.eventSnapshot)")
            .font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
        entries(item.events, empty: "No underlying check runs are available.")
        HStack(spacing: 8) {
            ActionButton(title: "Previous runs", icon: "chevron.left") { Task { await model.loadMonitoringCaseEventPage(page: item.eventPage - 1) } }
                .disabled(model.isLoadingNativeDashboard || item.eventPage <= 0)
            Text("Page \(item.eventPage + 1)").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.textTertiary)
            ActionButton(title: "Next runs", icon: "chevron.right") { Task { await model.loadMonitoringCaseEventPage(page: item.eventPage + 1) } }
                .disabled(model.isLoadingNativeDashboard || (item.eventPage + 1) * 50 >= item.eventTotal)
        }
    }

    @ViewBuilder private func notifications(_ item: MonitoringCase) -> some View {
        if item.canManage && model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty && !model.monitoringCaseMutationNeedsReview {
            ActionButton(title: item.notificationsEnabled ? "Disable notifications" : "Enable notifications", icon: "bell") { pending = .notifications(!item.notificationsEnabled) }
        }
        entries(item.notifications, empty: "No notifications recorded.")
    }

    @ViewBuilder private func entries(_ values: [JSONValue], empty: String) -> some View {
        if values.isEmpty {
            Text(empty).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textTertiary)
        } else {
            ForEach(Array(values.enumerated()), id: \.offset) { index, value in
                evidence("Record \(index + 1)", value)
            }
        }
    }

    private func evidence(_ title: String, _ value: JSONValue) -> some View {
        NativeGroupPanel(title: title, subtitle: "") {
            Text(value.pretty).font(.system(size: 11, weight: .regular, design: .monospaced)).foregroundStyle(theme.textSecondary)
                .textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func applyPendingChange() {
        guard let change = pending else { return }
        pending = nil
        Task {
            switch change {
            case .status(let status, let comment):
                await model.updateMonitoringCase(status: status, comment: comment)
            case .severity(let severity):
                await model.updateMonitoringCase(severity: severity)
            case .notifications(let enabled):
                await model.updateMonitoringCase(notificationsEnabled: enabled)
            case .comment(let comment):
                await model.updateMonitoringCase(comment: comment)
            case .confirmResolution(let id):
                await model.updateMonitoringCase(confirmResolutionId: id)
            }
        }
    }
}
