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

enum AutomationPanelScope: Equatable {
    case all, health, personalCron

    var listScope: String? { self == .personalCron ? "personal" : nil }
    var heading: String {
        switch self {
        case .all: "Automations"
        case .health: "Health checks"
        case .personalCron: "Personal cron jobs"
        }
    }
    var noun: String { self == .personalCron ? "job" : "check" }
}

struct AutomationsNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    let scope: AutomationPanelScope
    private let initialAutomationID: String?
    private let startsInCreate: Bool

    init(scope: AutomationPanelScope = .all, initialAutomationID: String? = nil, startsInCreate: Bool = false) {
        self.scope = scope
        self.initialAutomationID = initialAutomationID
        self.startsInCreate = startsInCreate
        _selectedID = State(initialValue: startsInCreate ? "" : initialAutomationID ?? "")
        _isEditing = State(initialValue: startsInCreate)
        _draftPrompt = State(initialValue: startsInCreate ? "Check that the page is available." : "")
    }
    @State private var automations: [DesktopAutomation] = []
    @State private var runs: [DesktopAutomationRun] = []
    @State private var selectedID = ""
    @State private var searchText = ""
    @State private var sortKey = "name"
    @State private var sortAscending = true
    @State private var isLoading = false
    @State private var hasLoadedAutomationList = false
    @State private var createOutcomeUncertain = false
    @State private var busyAction = ""
    @State private var detailRequestID = UUID()
    @State private var message = ""
    @State private var isEditing = false
    @State private var confirmsDelete = false
    @State private var draftName = ""
    @State private var draftURL = ""
    @State private var draftPrompt = ""
    @State private var draftActionType = "agent_prompt"
    @State private var draftInterval = "15"
    @State private var draftMonitoringType = "fetch"
    @State private var draftScheduleKind = "interval"
    @State private var draftRunAt = ""
    @State private var draftTimeout = "5"
    @State private var draftRetries = "4"
    @State private var draftDestinations = ""
    @State private var draftNotifyOn = "failure"
    @State private var draftTimezone = "UTC"
    @State private var draftUserAgent = ""
    @State private var draftFollowRedirects = true
    @State private var draftExpectedDown = false
    @State private var draftUpsideDown = false
    @State private var draftNotifyWarnings = false
    @State private var canManageSystemAutomations = false
    @State private var draftJSONPath = ""
    @State private var draftJSONOperator = "gt"
    @State private var draftJSONAggregate = "max"
    @State private var draftJSONValue = "80"
    @State private var nextPage: Int?
    @State private var issues: [DesktopAutomationIssue] = []
    @State private var historyTotal = 0
    @State private var historyLoading = false
    @State private var historyFiltersVisible = false
    @State private var historyFromEnabled = false
    @State private var historyToEnabled = false
    @State private var historyFromDraft = Date().addingTimeInterval(-86_400)
    @State private var historyToDraft = Date()
    @State private var appliedHistoryFrom: Date?
    @State private var appliedHistoryTo: Date?
    @State private var loadedHistoryFrom: Date?
    @State private var loadedHistoryTo: Date?
    @State private var senderCredential: DesktopAutomationSenderKeyEnvelope?
    @State private var confirmsSenderKeyReplacement = false

    private var selected: DesktopAutomation? { automations.first { $0.id == selectedID } }
    private var canMutate: Bool { model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty }
    private var canStartCreate: Bool {
        DesktopAutomationEditorRules.canCreate(hasLoadedList: hasLoadedAutomationList, isLoading: isLoading, outcomeUncertain: createOutcomeUncertain, canMutate: canMutate)
    }
    private var statusCounts: [(String, Int)] {
        var counts = ["Up": 0, "Down": 0, "Maintenance": 0, "Pending": 0, "Warning": 0]
        for automation in automations {
            let status: String
            if automation.status == "paused" || automation.expectedDown || automation.upsideDown { status = "Maintenance" }
            else if automation.lastStatus == nil || automation.lastStatus == "running" { status = "Pending" }
            else if automation.lastStatus == "failed" { status = "Down" }
            else if automation.lastStatus == "warning" { status = "Warning" }
            else { status = "Up" }
            counts[status, default: 0] += 1
        }
        return ["Up", "Down", "Maintenance", "Pending", "Warning"].map { ($0, counts[$0, default: 0]) }
    }
    private var filtered: [DesktopAutomation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return automations.filter { automation in
            query.isEmpty || "\(automation.name) \(automation.targetUrl ?? "") \(automation.status) \(automation.caseNumbers.joined(separator: " "))".lowercased().contains(query)
        }.sorted { left, right in
            let a = sortValue(left)
            let b = sortValue(right)
            if a == nil && b != nil { return false }
            if b == nil && a != nil { return true }
            let comparison = (a ?? "").localizedStandardCompare(b ?? "")
            if comparison == .orderedSame { return left.name.localizedStandardCompare(right.name) == .orderedAscending }
            return sortAscending ? comparison == .orderedAscending : comparison == .orderedDescending
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SearchFieldRow(placeholder: "Search \(scope.heading.lowercased())", text: $searchText)
                    .layoutPriority(1)
                if scope != .personalCron {
                    Picker("Sort health checks", selection: $sortKey) {
                        Text("Name").tag("name")
                        Text("Status").tag("status")
                        Text("Certificate").tag("cert")
                        Text("Recent issues").tag("history")
                        Text("Uptime").tag("uptime")
                        Text("Type").tag("tags")
                    }
                    .labelsHidden()
                    .frame(width: 120)
                    Button {
                        sortAscending.toggle()
                    } label: {
                        Image(systemName: sortAscending ? "arrow.up" : "arrow.down")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .frame(width: 30, height: 30)
                            .background(theme.cardRaised, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(sortAscending ? "Sort ascending" : "Sort descending")
                }
                if scope == .personalCron {
                    compactControl(title: "System", icon: "server.rack", label: "Open system cron jobs") {
                        model.openNativeDashboard(path: "/system/cron", label: "Cron Jobs")
                    }
                }
                compactControl(title: "Refresh", icon: "arrow.clockwise", label: "Refresh \(scope.heading.lowercased())", isDisabled: !DesktopAutomationEditorRules.canRefresh(isLoading: isLoading, isSaving: busyAction == "save")) {
                    Task { await load() }
                }
                compactControl(title: "New", icon: "plus", label: "Create automation", prominent: true) {
                    beginCreate()
                }.disabled(!canStartCreate)
            }

            if !message.isEmpty && (!automations.isEmpty || isEditing) {
                Text(message)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(theme.textSecondary)
                    .textSelection(.enabled)
            }

            if createOutcomeUncertain {
                HStack(spacing: 8) {
                    Text("Refresh the list to check whether the previous create request saved before creating another automation.")
                        .font(.system(size: 12))
                        .foregroundStyle(theme.textSecondary)
                    ActionButton(title: "Refresh list", icon: "arrow.clockwise") { Task { await load() } }
                        .disabled(!DesktopAutomationEditorRules.canRefresh(isLoading: isLoading, isSaving: busyAction == "save"))
                }
            }

            if isEditing {
                editor
            } else if isLoading && automations.isEmpty {
                NativeEmptyState(title: "Loading automations", message: "Connecting to your Hanasand account.")
            } else if automations.isEmpty {
                NativeEmptyState(
                    title: message.isEmpty ? "No \(scope.noun)s yet" : "Couldn’t load \(scope.heading.lowercased())",
                    message: message.isEmpty ? (scope == .personalCron ? "Create a scheduled personal job." : "Create a check to monitor a website or service on a schedule.") : message
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    if scope != .all { summary }
                    ViewThatFits(in: .horizontal) {
                      HStack(alignment: .top, spacing: 14) {
                        automationList
                        if let selected { detail(selected) }
                        else if isLoading { NativeEmptyState(title: "Loading", message: "Refreshing automation details.") }
                      }
                      VStack(alignment: .leading, spacing: 12) {
                        automationList
                        if let selected { detail(selected) }
                      }
                    }
                }
            }
        }
        .task { await load() }
        .alert(scope == .personalCron ? "Delete scheduled job?" : "Delete health check?", isPresented: $confirmsDelete) {
            Button("Delete", role: .destructive) { Task { await deleteSelected() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This removes the scheduled automation and its check history.")
        }
        .confirmationDialog("Replace external sender key?", isPresented: $confirmsSenderKeyReplacement, titleVisibility: .visible) {
            Button("Create or replace key", role: .destructive) { Task { await createSenderKey() } }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("The previous sender key will stop working. The new key is shown once, so save it before leaving this page.")
        }
    }

    private var summary: some View {
        NativeGroupPanel(title: scope.heading, subtitle: "\(automations.count) \(scope.noun)\(automations.count == 1 ? "" : "s")") {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), alignment: .leading)], alignment: .leading, spacing: 8) {
                ForEach(Array(statusCounts.enumerated()), id: \.offset) { item in
                    summaryMetric(item.element.0, value: String(item.element.1))
                }
            }
        }
    }

    private func summaryMetric(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
            Text(value).font(.system(size: 15, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1).minimumScaleFactor(0.8)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(9).background(theme.cardRaised).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var automationList: some View {
        NativeGroupPanel(title: scope.heading, subtitle: "") {
            if filtered.isEmpty {
                Text("No automations match this search.")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filtered) { automation in
                        Button { Task { await select(automation) } } label: {
                            automationRow(automation)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("\(automation.name), \(automation.status)")
                    }
                }
            }
        }.frame(minWidth: 260, maxWidth: 330, alignment: .leading)
    }

    private var editor: some View {
        NativeGroupPanel(title: selected == nil ? "New automation" : "Edit automation", subtitle: "") {
            field("Name", text: $draftName, placeholder: "Production website")
            Picker("Action", selection: Binding(
                get: { draftActionType },
                set: { action in
                    draftActionType = action
                    if action != "agent_prompt" { draftMonitoringType = "fetch" }
                }
            )) {
                ForEach(availableActionTypes, id: \.self) { Text(actionLabel($0)).tag($0) }
            }.disabled(selected?.monitoringType == "push" || selected?.actionType == "organization_report")
            field("Description", text: $draftPrompt, placeholder: "Describe this scheduled action")
            if draftActionType == "agent_prompt" {
                field(draftMonitoringType == "push" ? "Source ID" : "URL or host", text: $draftURL, placeholder: draftMonitoringType == "push" ? "uptime.source" : "https://example.com")
                    .disabled(selected?.monitoringType == "push")
                Picker("Check type", selection: Binding(
                    get: { draftMonitoringType },
                    set: { type in
                        draftMonitoringType = type
                        if type == "push" {
                            draftURL = ""
                            draftTimeout = "180"
                            draftRetries = "0"
                            draftInterval = "1"
                            draftScheduleKind = "interval"
                            draftExpectedDown = false
                            draftUpsideDown = false
                        } else {
                            draftTimeout = "5"
                        }
                    }
                )) {
                    ForEach(["fetch", "post", "tcp", "ssh", "json"] + (selected == nil || selected?.monitoringType == "push" ? ["push"] : []), id: \.self) {
                        Text($0 == "push" ? "External events" : $0.uppercased()).tag($0)
                    }
                }.disabled(selected?.monitoringType == "push")
                if draftMonitoringType == "push" {
                    Text("External events use a one-minute heartbeat. Existing source IDs and check types cannot be changed.")
                        .font(.system(size: 10, weight: .regular)).foregroundStyle(theme.textTertiary)
                }
                if draftMonitoringType == "json" {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("JSON comparison").font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                        field("Field path · use . for nesting and * for array items", text: $draftJSONPath, placeholder: "results.*.latency")
                        Picker("Combine values", selection: $draftJSONAggregate) {
                            ForEach(DesktopAutomationEditorRules.aggregates, id: \.self) { Text($0.capitalized).tag($0) }
                        }
                        Picker("Alert when", selection: $draftJSONOperator) {
                            ForEach(DesktopAutomationEditorRules.operators, id: \.self) { Text(operatorLabel($0)).tag($0) }
                        }
                        field("Comparison value · numbers, true/false, or text", text: $draftJSONValue, placeholder: "80")
                        Text("Text values can be entered directly; quote them as JSON strings when the text starts with a number or needs surrounding whitespace.")
                            .font(.system(size: 10, weight: .regular)).foregroundStyle(theme.textTertiary)
                    }
                    .padding(10)
                    .background(theme.cardRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                }
            }
            Picker("Schedule", selection: $draftScheduleKind) {
                Text("Recurring").tag("interval")
                Text("Once").tag("once")
            }.disabled(draftMonitoringType == "push")
            if draftScheduleKind == "interval" {
                field("Repeat every (minutes)", text: $draftInterval, placeholder: "15")
                    .disabled(draftMonitoringType == "push")
            } else {
                field("Run at (ISO 8601)", text: $draftRunAt, placeholder: "2026-10-23T18:00:00Z")
            }
            field(draftMonitoringType == "push" ? "Mark offline after (seconds)" : "Response timeout (seconds)", text: $draftTimeout, placeholder: draftMonitoringType == "push" ? "180" : "5")
            if draftMonitoringType != "push" { field("Retries before failure", text: $draftRetries, placeholder: "4") }
            field("Timezone", text: $draftTimezone, placeholder: "UTC")
            field("Alert when", text: $draftNotifyOn, placeholder: "failure, always, or never")
            VStack(alignment: .leading, spacing: 5) {
                Text("Discord webhook URLs (one per line)").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
                TextEditor(text: $draftDestinations).font(.system(size: 12, weight: .medium)).frame(minHeight: 52)
                    .padding(6).background(theme.field).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            }
            if draftMonitoringType != "push" {
                field("User agent", text: $draftUserAgent, placeholder: "Hanasand health check")
                Toggle("Follow redirects", isOn: $draftFollowRedirects)
                Toggle("Notify on warnings", isOn: $draftNotifyWarnings)
            }
            Toggle("Expected down (maintenance)", isOn: $draftExpectedDown).disabled(draftMonitoringType == "push")
            Toggle("Invert result", isOn: $draftUpsideDown).disabled(draftMonitoringType == "push")
            HStack(spacing: 10) {
                ActionButton(title: "Cancel", icon: "xmark") { isEditing = false; message = "" }
                ActionButton(title: selected == nil ? "Create" : "Save", icon: "checkmark") { Task { await save() } }
                    .disabled(busyAction == "save" || !canMutate || (selected == nil && !canStartCreate))
            }
        }
    }

    private func automationRow(_ automation: DesktopAutomation) -> some View {
        HStack(spacing: 9) {
            Circle().fill(statusColor(automation)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(automation.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Text([automation.status.capitalized, automation.lastStatus?.capitalized, automation.uptime.map { String(format: "%.1f%% uptime", $0) }].compactMap { $0 }.joined(separator: " · "))
                    .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if selectedID == automation.id { Image(systemName: "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(theme.accent) }
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(selectedID == automation.id ? theme.accentSoft : theme.cardRaised)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func detail(_ automation: DesktopAutomation) -> some View {
        NativeGroupPanel(title: automation.name, subtitle: automation.targetUrl ?? automation.monitoringType.uppercased()) {
            labeled("Status", value: automation.status.capitalized)
            labeled("Checks", value: "\(automation.runCount)")
            labeled("Consecutive failures", value: "\(automation.consecutiveFailures)")
            labeled("Schedule", value: "Every \(automation.intervalMinutes ?? 15) minutes")
            labeled("Last run", value: automation.lastRunAt ?? "Not run")
            labeled("Next run", value: automation.nextRunAt ?? "Not scheduled")
            labeled("Uptime", value: automation.uptime.map { String(format: "%.2f%%", $0) } ?? "Not available")
            labeled("Monitoring type", value: automation.monitoringType.uppercased())
            labeled("Response timeout", value: "\(automation.timeoutSeconds) seconds")
            labeled("Retries", value: "\(automation.retryCount)")
            labeled("Alerts", value: automation.notifyOn?.capitalized ?? "Failure")
            if let cert = automation.certificateStatus, cert != "not_applicable" {
                labeled("TLS certificate", value: cert.replacingOccurrences(of: "_", with: " ").capitalized)
                if let expiry = automation.certificateExpiresAt { labeled("Certificate expires", value: expiry) }
            }
            Text(automation.prompt)
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
            if let result = automation.resultSummary, !result.isEmpty {
                Text(result)
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(automation.lastError == nil ? theme.textSecondary : theme.danger)
                    .textSelection(.enabled)
            }
            if automation.monitoringType == "push" {
                externalSender(automation)
            }
            HStack(spacing: 8) {
                ActionButton(title: automation.status == "active" ? "Pause" : "Resume", icon: automation.status == "active" ? "pause.fill" : "play.fill") {
                    Task { await setStatus(automation, status: automation.status == "active" ? "paused" : "active") }
                }.disabled(busyAction == automation.id || !canMutate)
                ActionButton(title: "Run now", icon: "bolt.fill") { Task { await runNow(automation) } }.disabled(busyAction == automation.id || !canMutate)
                if canEdit(automation) {
                    ActionButton(title: "Edit", icon: "pencil") { beginEdit(automation) }.disabled(!canMutate)
                }
                ActionButton(title: "Delete", icon: "trash", tone: .danger) { confirmsDelete = true }.disabled(busyAction == automation.id || !canMutate)
            }
            Divider().overlay(theme.divider)
            if !issues.isEmpty {
                Text("Issues (\(issues.count))").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                ForEach(issues) { issue in
                    VStack(alignment: .leading, spacing: 4) {
                        Text("\(issue.caseNumber) · \(issue.resolvedAt == nil ? "Open" : "Resolved") · \(issue.occurrences) occurrence\(issue.occurrences == 1 ? "" : "s")")
                            .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                        Text(issue.summary).font(.system(size: 11, weight: .regular)).foregroundStyle(theme.textSecondary).lineLimit(4).textSelection(.enabled)
                        Text("First seen: \(formatDateText(issue.firstSeenAt, fallback: issue.firstSeenAt)) · Last seen: \(formatDateText(issue.lastSeenAt, fallback: issue.lastSeenAt))\(issue.resolvedAt.map { " · Resolved: \(formatDateText($0, fallback: $0))" } ?? "")")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
                            .fixedSize(horizontal: false, vertical: true)
                        ForEach(Array(issue.notifications.enumerated()), id: \.offset) { item in
                            let notification = item.element
                            let delivery = notification.error.map { "Discord delivery failed: \($0)" }
                                ?? notification.deliveredAt.map { "Discord notified: \($0)" }
                                ?? "Discord notification pending."
                            Text(delivery)
                                .font(.system(size: 10, weight: .medium))
                                .foregroundStyle(notification.error == nil ? theme.textTertiary : theme.danger)
                                .fixedSize(horizontal: false, vertical: true)
                            if let nextAttemptAt = notification.nextAttemptAt {
                                Text("Next eligible notification \(formatDateText(nextAttemptAt, fallback: nextAttemptAt))")
                                    .font(.system(size: 10, weight: .medium))
                                    .foregroundStyle(theme.textTertiary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }.padding(8).background(theme.cardRaised).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                Divider().overlay(theme.divider)
            }
            HStack {
                Text("Recent checks (\(runs.count)/\(historyTotal))").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                compactControl(title: historyFiltersVisible ? "Hide filters" : "Filter", icon: "line.3.horizontal.decrease.circle", label: "Filter checks by time") {
                    historyFiltersVisible.toggle()
                }
                compactControl(title: "Refresh", icon: "arrow.clockwise", label: "Refresh checks", isDisabled: historyLoading) {
                    Task { await loadDetail(automation, from: appliedHistoryFrom, to: appliedHistoryTo) }
                }
            }
            if historyFiltersVisible {
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("From", isOn: $historyFromEnabled)
                    if historyFromEnabled {
                        DatePicker("Start", selection: $historyFromDraft, displayedComponents: [.date, .hourAndMinute])
                    }
                    Toggle("To", isOn: $historyToEnabled)
                    if historyToEnabled {
                        DatePicker("End", selection: $historyToDraft, displayedComponents: [.date, .hourAndMinute])
                    }
                    ActionButton(title: "Apply filters", icon: "line.3.horizontal.decrease.circle") {
                        guard !historyFromEnabled || !historyToEnabled || historyFromDraft <= historyToDraft else {
                            message = "The start time must be before the end time."
                            return
                        }
                        appliedHistoryFrom = historyFromEnabled ? historyFromDraft : nil
                        appliedHistoryTo = historyToEnabled ? historyToDraft : nil
                        Task { await loadDetail(automation, from: appliedHistoryFrom, to: appliedHistoryTo) }
                    }.disabled(historyLoading)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(9)
                .background(theme.cardRaised)
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
            if runs.isEmpty {
                Text(message.isEmpty ? "No check history is available for this time range." : message).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
            } else {
                ForEach(runs) { run in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(run.startedAt).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary)
                            Spacer()
                            Text(run.warning ? "Warning" : run.status.capitalized).font(.system(size: 10, weight: .semibold)).foregroundStyle(run.status == "failed" ? theme.danger : theme.green)
                        }
                        if let detail = run.error ?? run.result { Text(detail).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).lineLimit(3).textSelection(.enabled) }
                    }.padding(8).background(theme.cardRaised).clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
            }
            if let nextPage {
                ActionButton(title: "Load more checks", icon: "arrow.down") { Task { await loadMore(automation, page: nextPage) } }.disabled(historyLoading)
            }
        }
        .frame(minWidth: 320, maxWidth: .infinity, alignment: .leading)
    }

    private func externalSender(_ automation: DesktopAutomation) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("External sender").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
            Text("Event API path").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
            Text("/api/automations/\(automation.id)/events")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
                .lineLimit(2)
            ActionButton(title: "Create or replace sender key", icon: "key.fill", tone: .danger) {
                confirmsSenderKeyReplacement = true
            }
            .disabled(!canMutate || busyAction == "sender-key")
            Text("Replacing the key disconnects the previous sender. Send the key in X-API-Key.")
                .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary)
            if let senderCredential, selectedID == automation.id {
                Text("Sender key (shown once)").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
                Text(senderCredential.secret)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.text)
                    .textSelection(.enabled)
                    .lineLimit(3)
                HStack(spacing: 8) {
                    ActionButton(title: "Copy key", icon: "doc.on.doc") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(senderCredential.secret, forType: .string)
                        message = "Sender key copied."
                    }
                    Text(senderCredential.endpoint).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(2)
                }
            }
        }
        .padding(9)
        .background(theme.cardRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func field(_ title: String, text: Binding<String>, placeholder: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
            TextField(placeholder, text: text).textFieldStyle(.plain).font(.system(size: 12, weight: .medium))
                .padding(10).background(theme.field).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func labeled(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(theme.textTertiary)
            Spacer(minLength: 12)
            Text(value)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(theme.textSecondary)
                .multilineTextAlignment(.trailing)
                .lineLimit(2)
                .textSelection(.enabled)
        }
    }

    private func compactControl(
        title: String,
        icon: String,
        label: String,
        isDisabled: Bool = false,
        prominent: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .background(
                    prominent ? theme.cardRaised : Color.clear,
                    in: RoundedRectangle(cornerRadius: 8, style: .continuous)
                )
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .disabled(isDisabled)
    }

    private func statusColor(_ automation: DesktopAutomation) -> Color {
        if automation.status == "paused" || automation.expectedDown || automation.upsideDown { return theme.accent }
        if automation.lastStatus == "failed" || automation.consecutiveFailures > 0 { return theme.danger }
        if automation.lastStatus == "warning" { return theme.accent }
        return automation.status == "active" ? theme.green : theme.textTertiary
    }

    private func sortValue(_ automation: DesktopAutomation) -> String? {
        switch sortKey {
        case "status":
            if automation.monitoringType == "push" && automation.lastStatus == nil { return automation.status == "active" ? "Awaiting reading" : "Paused" }
            if automation.actionType == "agent_prompt" && (automation.targetUrl ?? "").isEmpty { return "Missing URL" }
            if automation.consecutiveFailures > 0 || automation.lastStatus == "failed" { return "Unhealthy" }
            if automation.lastStatus == "warning" { return "Warning" }
            if automation.expectedDown || automation.upsideDown { return "Maintenance" }
            return automation.status == "active" ? "Healthy" : "Paused"
        case "cert":
            let target = automation.targetUrl ?? ""
            let applies = target.lowercased().hasPrefix("http://") || target.lowercased().hasPrefix("https://")
                || automation.monitoringType == "tcp" && target.hasSuffix(":443")
            guard applies else { return "N/A" }
            switch automation.certificateStatus ?? "" {
            case "valid": return "Valid"
            case "invalid": return "Invalid"
            case "expiring": return "Expiring"
            case "not_applicable": return "N/A"
            default: return "Pending"
            }
        case "history":
            guard !automation.history.isEmpty else { return nil }
            return String(format: "%08d", automation.history.filter { $0.status == "failed" || $0.warning }.count)
        case "uptime":
            return automation.uptime.map { String(format: "%012.4f", $0) }
        case "tags":
            switch automation.actionType {
            case "mail_health_check": return "Mail health"
            case "system_alert": return "System alert"
            case "organization_report": return "Organization report"
            case "echo": return "Delivery test"
            default: return nil
            }
        default:
            return automation.name
        }
    }

    private func load() async {
        isLoading = true
        canManageSystemAutomations = false
        defer { isLoading = false }
        do {
            let overview = try await model.fetchDesktopAutomationOverview(scope: scope.listScope)
            let wasReconcilingCreate = createOutcomeUncertain
            automations = overview.automations
            hasLoadedAutomationList = true
            createOutcomeUncertain = false
            if wasReconcilingCreate { isEditing = false }
            canManageSystemAutomations = overview.canManageSystem == true
            if !startsInCreate && (selectedID.isEmpty || !automations.contains(where: { $0.id == selectedID })) {
                selectedID = automations.first(where: { $0.id == initialAutomationID })?.id ?? automations.first?.id ?? ""
            }
            if let selected { await loadDetail(selected, from: appliedHistoryFrom, to: appliedHistoryTo) }
            message = wasReconcilingCreate ? "Automation list refreshed to check the previous create request." : ""
        } catch { message = error.localizedDescription }
    }

    private func select(_ automation: DesktopAutomation) async {
        selectedID = automation.id
        appliedHistoryFrom = nil
        appliedHistoryTo = nil
        loadedHistoryFrom = nil
        loadedHistoryTo = nil
        runs = []
        issues = []
        historyTotal = 0
        nextPage = nil
        historyFromEnabled = false
        historyToEnabled = false
        historyFiltersVisible = false
        senderCredential = nil
        await loadDetail(automation)
    }

    private func loadDetail(_ automation: DesktopAutomation, page: Int = 1, from: Date? = nil, to: Date? = nil) async {
        let requestID = UUID()
        detailRequestID = requestID
        let preserveOlderPages = page == 1 && from == loadedHistoryFrom && to == loadedHistoryTo && !runs.isEmpty
        historyLoading = true
        defer {
            if detailRequestID == requestID { historyLoading = false }
        }
        do {
            let detail = try await model.fetchDesktopAutomationDetail(automation.id, page: page, from: from, to: to)
            guard !Task.isCancelled, detailRequestID == requestID, selectedID == automation.id else { return }
            if preserveOlderPages {
                var merged = Dictionary(uniqueKeysWithValues: runs.map { ($0.id, $0) })
                detail.runs.forEach { merged[$0.id] = $0 }
                runs = merged.values.sorted { $0.startedAt > $1.startedAt }
            } else {
                runs = detail.runs
            }
            loadedHistoryFrom = from
            loadedHistoryTo = to
            historyTotal = detail.total ?? runs.count
            issues = detail.issues
            nextPage = detail.nextPage ?? detail.nextCursor.flatMap(Int.init)
            message = ""
        } catch {
            guard !Task.isCancelled, detailRequestID == requestID, selectedID == automation.id else { return }
            runs = []
            issues = []
            nextPage = nil
            historyTotal = 0
            loadedHistoryFrom = from
            loadedHistoryTo = to
            message = error.localizedDescription
        }
    }

    private func loadMore(_ automation: DesktopAutomation, page: Int) async {
        let requestID = UUID()
        detailRequestID = requestID
        historyLoading = true
        defer {
            if detailRequestID == requestID { historyLoading = false }
        }
        do {
            let detail = try await model.fetchDesktopAutomationDetail(automation.id, page: page, from: appliedHistoryFrom, to: appliedHistoryTo)
            guard !Task.isCancelled, detailRequestID == requestID, selectedID == automation.id else { return }
            runs.append(contentsOf: detail.runs)
            historyTotal = detail.total ?? runs.count
            issues = detail.issues
            nextPage = detail.nextPage
        } catch {
            guard detailRequestID == requestID, selectedID == automation.id else { return }
            message = error.localizedDescription
        }
    }

    private func createSenderKey() async {
        guard let selected, selected.monitoringType == "push", canMutate else { return }
        busyAction = "sender-key"
        defer { busyAction = "" }
        do {
            senderCredential = try await model.createDesktopAutomationSenderKey(selected.id)
            message = "Sender key created. Save it now; it will not be shown again."
        } catch {
            message = error.localizedDescription
        }
    }

    private func beginCreate() {
        guard canStartCreate else { return }
        selectedID = ""
        draftName = ""
        draftURL = ""
        draftPrompt = "Check that the page is available."
        draftActionType = "agent_prompt"
        draftInterval = "15"
        draftMonitoringType = "fetch"
        draftScheduleKind = "interval"
        draftRunAt = ""
        draftTimeout = "5"
        draftRetries = "4"
        draftDestinations = ""
        draftNotifyOn = "failure"
        draftTimezone = TimeZone.current.identifier
        draftUserAgent = ""
        draftFollowRedirects = true
        draftExpectedDown = false
        draftUpsideDown = false
        draftNotifyWarnings = false
        draftJSONPath = ""
        draftJSONOperator = "gt"
        draftJSONAggregate = "max"
        draftJSONValue = "80"
        isEditing = true
    }

    private func beginEdit(_ automation: DesktopAutomation) {
        draftName = automation.name
        draftURL = automation.targetUrl ?? ""
        draftPrompt = automation.prompt
        draftActionType = automation.actionType
        draftInterval = String(automation.intervalMinutes ?? 15)
        draftMonitoringType = automation.monitoringType
        draftScheduleKind = automation.scheduleKind
        draftRunAt = automation.runAt ?? ""
        draftTimeout = String(automation.timeoutSeconds)
        draftRetries = String(automation.retryCount)
        draftDestinations = automation.notificationDestinations.joined(separator: "\n")
        draftNotifyOn = automation.notifyOn ?? "failure"
        draftTimezone = automation.timezone ?? "UTC"
        draftUserAgent = automation.userAgent ?? ""
        draftFollowRedirects = automation.followRedirects
        draftExpectedDown = automation.expectedDown
        draftUpsideDown = automation.upsideDown
        draftNotifyWarnings = automation.notifyWarnings
        if let rule = automation.jsonRule {
            draftJSONPath = rule.path
            draftJSONOperator = rule.operatorName
            draftJSONAggregate = rule.aggregate ?? "max"
            switch rule.value {
            case .string(let value): draftJSONValue = value
            case .number(let value): draftJSONValue = String(value)
            case .bool(let value): draftJSONValue = String(value)
            case .null: draftJSONValue = ""
            }
        } else {
            draftJSONPath = ""
            draftJSONOperator = "gt"
            draftJSONAggregate = "max"
            draftJSONValue = "80"
        }
        isEditing = true
    }

    private func save() async {
        guard selected != nil || canStartCreate else {
            message = "Refresh the list before creating another automation."
            return
        }
        let wasCreate = selected == nil
        let interval: Int
        if let parsed = Int(draftInterval) { interval = parsed }
        else if draftScheduleKind == "interval" { message = "Enter a valid repeat interval in minutes."; return }
        else { interval = selected?.intervalMinutes ?? 15 }
        guard draftScheduleKind != "interval" || (1...43_200).contains(interval) else {
            message = "Choose a repeat interval between 1 and 43200 minutes."
            return
        }
        guard let timeoutSeconds = Int(draftTimeout) else { message = "Enter a valid response timeout."; return }
        let retryCount: Int
        if draftMonitoringType == "push" { retryCount = 0 }
        else if let parsed = Int(draftRetries) { retryCount = parsed }
        else { message = "Enter a valid retry count."; return }
        let url = draftURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draftName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "Name is required."; return }
        guard !draftPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { message = "A description is required."; return }
        let destinations = draftDestinations.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        if let selected, DesktopAutomationEditorRules.wouldClearExistingDestinations(
            existingModelName: selected.modelName,
            existingDestinations: selected.notificationDestinations,
            requestedDestinations: destinations
        ) {
            message = "Clearing notification destinations is not supported by the API yet. Keep at least one destination or cancel this edit."
            return
        }
        let jsonRule: DesktopAutomationJSONRule? = draftMonitoringType == "json" && draftActionType == "agent_prompt"
            ? DesktopAutomationEditorRules.value(from: draftJSONValue).map { DesktopAutomationJSONRule(path: draftJSONPath.trimmingCharacters(in: .whitespacesAndNewlines), operatorName: draftJSONOperator, value: $0, aggregate: draftJSONAggregate) }
            : nil
        if let error = DesktopAutomationEditorRules.validate(
            actionType: draftActionType, monitoringType: draftMonitoringType, targetURL: url,
            jsonRule: jsonRule, canManageSystem: canManageSystemAutomations,
            scheduleKind: draftScheduleKind, intervalMinutes: interval, timeoutSeconds: timeoutSeconds, retryCount: retryCount, runAt: draftRunAt,
            expectedDown: draftExpectedDown, upsideDown: draftUpsideDown
        ) {
            message = error
            return
        }
        guard (draftMonitoringType == "push" ? (1...86_400) : (1...120)).contains(timeoutSeconds) else {
            message = draftMonitoringType == "push" ? "Enter an offline timeout between 1 and 86400 seconds." : "Enter a response timeout between 1 and 120 seconds."
            return
        }
        guard (0...5).contains(retryCount) else { message = "Enter between 0 and 5 retries."; return }
        let destinationRequired = draftActionType == "system_alert" || (draftActionType == "mail_health_check" && draftNotifyOn != "never")
        if (selected?.status ?? "active") == "active" && destinationRequired && destinations.isEmpty {
            message = "Add a notification destination before activating this action."
            return
        }
            let payload = DesktopAutomationPayload(
            name: draftName, prompt: draftPrompt, targetUrl: draftActionType == "agent_prompt" ? url : "", monitoringType: draftActionType == "agent_prompt" ? draftMonitoringType : "fetch",
            scheduleKind: draftScheduleKind, intervalMinutes: interval, status: selected?.status ?? "active", actionType: draftActionType,
            followRedirects: draftFollowRedirects, userAgent: draftUserAgent.isEmpty ? nil : draftUserAgent,
            expectedDown: draftExpectedDown, upsideDown: draftUpsideDown,
            timeoutSeconds: timeoutSeconds, retryCount: retryCount,
            runAt: draftScheduleKind == "once" ? draftRunAt : nil,
            timezone: draftTimezone, modelName: destinations.first, notificationDestinations: destinations,
            notifyOn: draftNotifyOn, notifyWarnings: draftNotifyWarnings, jsonRule: jsonRule
        )
        busyAction = "save"
        defer { busyAction = "" }
        do {
            let saved = try await model.saveDesktopAutomation(payload, id: selected?.id)
            isEditing = false
            message = "Saved \(saved.name)."
            await load()
            selectedID = saved.id
        } catch {
            if DesktopAutomationEditorRules.shouldRequireCreateReconciliation(wasCreate: wasCreate, error: error) {
                createOutcomeUncertain = true
                message = "The create request’s outcome is unclear. Refresh the list before creating again; it may already have saved."
            } else {
                message = error.localizedDescription
            }
        }
    }

    private var availableActionTypes: [String] {
        DesktopAutomationEditorRules.actions.filter { $0 != "mail_health_check" || canManageSystemAutomations }
    }

    private func canEdit(_ automation: DesktopAutomation) -> Bool {
        DesktopAutomationEditorRules.actions.contains(automation.actionType)
            && (automation.actionType != "mail_health_check" || canManageSystemAutomations)
    }

    private func actionLabel(_ action: String) -> String {
        switch action {
        case "agent_prompt": "Monitoring check"
        case "system_alert": "Scheduled message"
        case "mail_health_check": "Mail health check"
        case "echo": "History reminder"
        default: action
        }
    }

    private func operatorLabel(_ op: String) -> String {
        switch op {
        case "gt": "Greater than (>)"
        case "gte": "Greater than or equal (≥)"
        case "lt": "Less than (<)"
        case "lte": "Less than or equal (≤)"
        case "eq": "Equal (=)"
        case "ne": "Not equal (≠)"
        default: op
        }
    }

    private func setStatus(_ automation: DesktopAutomation, status: String) async {
        busyAction = automation.id
        defer { busyAction = "" }
        do { try await model.setDesktopAutomationStatus(automation.id, status: status); await load() }
        catch { message = error.localizedDescription }
    }

    private func runNow(_ automation: DesktopAutomation) async {
        busyAction = automation.id
        defer { busyAction = "" }
        do { message = try await model.runDesktopAutomation(automation.id); await load() }
        catch { message = error.localizedDescription }
    }

    private func deleteSelected() async {
        guard let selected else { return }
        busyAction = selected.id
        defer { busyAction = "" }
        do { try await model.deleteDesktopAutomation(selected.id); runs = []; selectedID = ""; message = "Deleted \(selected.name)."; await load() }
        catch { message = error.localizedDescription }
    }
}
