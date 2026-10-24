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

struct SystemCronNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State private var jobs: [DesktopCronJob] = []
    @State private var selectedID = ""
    @State private var searchText = ""
    @State private var selectedStatus = "all"
    @State private var scheduleDraft = ""
    @State private var isLoading = false
    @State private var busyID = ""
    @State private var message = ""
    @State private var readinessRetry: Task<Void, Never>?
    @State private var pendingUpdate: (job: DesktopCronJob, payload: DesktopCronUpdatePayload)?
    @State private var confirmsUpdate = false

    private var selected: DesktopCronJob? { jobs.first { $0.id == selectedID } }
    private var attentionJobs: [DesktopCronJob] { jobs.filter { $0.failureCount > 0 || ["failed", "blocked"].contains($0.status.lowercased()) } }
    private var runnableJob: DesktopCronJob? {
        jobs.first { job in
            job.controls.contains("run_now") && !attentionJobs.contains(where: { $0.id == job.id }) && !job.running
        }
    }
    private var filtered: [DesktopCronJob] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return jobs.filter { job in
            let textMatch = query.isEmpty || "\(job.name) \(job.category) \(job.description) \(job.service)".lowercased().contains(query)
            let statusMatch = selectedStatus == "all" || job.status == selectedStatus
            return textMatch && statusMatch
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                SearchFieldRow(placeholder: "Search scheduled jobs", text: $searchText)
                    .layoutPriority(1)
                compactControl(title: isLoading ? "Refreshing" : "Refresh", icon: "arrow.clockwise", label: "Refresh scheduled jobs", isDisabled: isLoading) {
                    Task { await load() }
                }
            }

            if !message.isEmpty && !jobs.isEmpty {
                Text(message).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            }

            if isLoading && jobs.isEmpty {
                NativeEmptyState(title: "Loading system jobs", message: "Reading the managed schedule inventory.")
            } else if jobs.isEmpty {
                NativeEmptyState(
                    title: message.isEmpty ? "No system jobs" : (message.hasPrefix("Showing the job registry") ? "Loading system jobs" : "Couldn’t load system jobs"),
                    message: message.isEmpty ? "No scheduled jobs were returned." : message
                )
            } else {
                VStack(alignment: .leading, spacing: 12) {
                    operationsSummary
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: 14) {
                            schedulePanel.frame(minWidth: 270, maxWidth: 340)
                            if let selected {
                                detail(selected).frame(minWidth: 380, maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        VStack(alignment: .leading, spacing: 14) {
                            schedulePanel.frame(maxWidth: .infinity)
                            if let selected {
                                detail(selected).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }
                }
            }
        }
        .task { await load() }
        .onDisappear { readinessRetry?.cancel() }
        .confirmationDialog("Confirm scheduled job change?", isPresented: $confirmsUpdate, titleVisibility: .visible) {
            Button("Confirm", role: .destructive) {
                guard let pendingUpdate else { return }
                Task { await update(pendingUpdate.job, payload: pendingUpdate.payload) }
            }
            Button("Cancel", role: .cancel) { pendingUpdate = nil }
        } message: {
            Text(confirmationMessage)
        }
    }

    private var schedulePanel: some View {
        NativeGroupPanel(title: "Schedule", subtitle: "") {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(["all", "failed", "blocked", "running", "enabled", "paused", "observable"], id: \.self) { status in
                        statusFilter(status)
                    }
                }
            }
            if filtered.isEmpty {
                Text("No jobs match the active filters.").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
            } else {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(filtered) { job in
                        Button { select(job) } label: { row(job) }
                            .buttonStyle(.plain)
                            .accessibilityLabel("\(job.name), \(job.status), \(job.category), \(job.schedule)")
                    }
                }
            }
        }
    }

    private var operationsSummary: some View {
        let enabled = jobs.filter(\.enabled).count
        let running = jobs.filter { $0.running || $0.status == "running" }.count
        let estimatedDailyCosts = jobs.compactMap { $0.costEstimate?.dailyUsd }
        let dailyCost = estimatedDailyCosts.isEmpty ? "Metering" : "$\(String(format: "%.2f", estimatedDailyCosts.reduce(0, +)))/day estimated"
        let failed = jobs.filter { $0.failureCount > 0 || ["failed", "blocked"].contains($0.status.lowercased()) }.count
        let pending = jobs.filter { $0.status == "unknown" }.count
        let headline: String
        if jobs.isEmpty { headline = "No scheduled jobs available" }
        else if pending > 0 { headline = "Live job state is loading" }
        else if failed == 1 { headline = "1 job needs review" }
        else if failed > 1 { headline = "\(failed) jobs need review" }
        else if running > 0 { headline = "\(running) job\(running == 1 ? "" : "s") running now" }
        else { headline = "All scheduled jobs operating normally" }
        return NativeGroupPanel(title: headline, subtitle: "\(enabled)/\(jobs.count) enabled · \(running) running · \(dailyCost)") {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 12) {
                    attentionSummary.frame(maxWidth: .infinity, alignment: .leading)
                    nextSafeAction.frame(maxWidth: .infinity, alignment: .leading)
                }
                VStack(alignment: .leading, spacing: 12) {
                    attentionSummary
                    nextSafeAction
                }
            }
        }
    }

    private var attentionSummary: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Needs attention", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
                Spacer()
                Text(String(attentionJobs.count)).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
            }
            if attentionJobs.isEmpty {
                Text("No blocked or failing jobs in the current inventory.").font(.system(size: 10)).foregroundStyle(theme.textSecondary)
            } else {
                ForEach(attentionJobs.prefix(3)) { job in
                    Button { select(job) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(job.name).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.text)
                            Text(job.lastError ?? "\(job.status.capitalized) · \(job.category)").font(.system(size: 9)).foregroundStyle(theme.textSecondary).lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(7)
                        .background(theme.cardRaised)
                        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    }.buttonStyle(.plain)
                }
            }
        }
        .padding(8)
        .background(theme.cardRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private var nextSafeAction: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Next safe action", systemImage: "play.circle")
                .font(.system(size: 11, weight: .semibold)).foregroundStyle(theme.text)
            if let runnableJob {
                Text("\(runnableJob.name) can be run once without changing its schedule.")
                    .font(.system(size: 10)).foregroundStyle(theme.textSecondary)
                ActionButton(title: "Run selected job", icon: "bolt.fill") {
                    requestUpdate(runnableJob, payload: DesktopCronUpdatePayload(action: "run_now"))
                }.disabled(busyID == runnableJob.id)
            } else {
                Text("No manual run action is available from this snapshot.").font(.system(size: 10)).foregroundStyle(theme.textSecondary)
            }
        }
        .padding(8)
        .background(theme.cardRaised)
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func row(_ job: DesktopCronJob) -> some View {
        HStack(spacing: 9) {
            Circle().fill(color(for: job.status)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.name).font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text).lineLimit(1)
                Text("\(job.category) · \(job.schedule)").font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).lineLimit(1)
            }
            Spacer(minLength: 0)
            if job.running { Image(systemName: "waveform.path").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.accent) }
        }
        .padding(.horizontal, 9).padding(.vertical, 8)
        .background(selectedID == job.id ? theme.accentSoft : theme.cardRaised)
        .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }

    private func detail(_ job: DesktopCronJob) -> some View {
        NativeGroupPanel(title: job.name, subtitle: "\(job.category) · \(job.service)") {
            labeled("Status", value: job.status.capitalized)
            labeled("Failures", value: "\(job.failureCount)")
            if let averageRuntimeMs = job.averageRuntimeMs {
                labeled("Average run", value: duration(averageRuntimeMs))
            }
            Text(job.description).font(.system(size: 12, weight: .regular)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
            labeled("Schedule", value: job.schedule)
            labeled("Last run", value: job.lastRunAt ?? "Not recorded")
            labeled("Last success", value: job.lastSuccessAt ?? "Not recorded")
            labeled("Next run", value: job.nextRunAt ?? "Not scheduled")

            if job.controls.contains("edit_schedule") {
                HStack(spacing: 8) {
                    TextField("Cron schedule", text: $scheduleDraft).textFieldStyle(.plain).font(.system(size: 12, weight: .medium, design: .monospaced))
                        .padding(10).background(theme.field).clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
                    ActionButton(title: "Save schedule", icon: "checkmark") { requestUpdate(job, payload: DesktopCronUpdatePayload(schedule: scheduleDraft)) }
                        .disabled(busyID == job.id || scheduleDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

            if let error = job.lastError, !error.isEmpty {
                Text(error).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.danger).textSelection(.enabled)
            } else if let excerpt = job.logExcerpt, !excerpt.isEmpty {
                Text(excerpt).font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary).lineLimit(5).textSelection(.enabled)
            }

            HStack(spacing: 8) {
                if job.controls.contains("enable") || job.controls.contains("resume") || job.controls.contains("disable") || job.controls.contains("pause") {
                    ActionButton(title: job.enabled ? "Pause" : "Enable", icon: job.enabled ? "pause.fill" : "play.fill") {
                        requestUpdate(job, payload: DesktopCronUpdatePayload(enabled: !job.enabled))
                    }.disabled(busyID == job.id)
                }
                if job.controls.contains("run_now") {
                    ActionButton(title: "Run now", icon: "bolt.fill") {
                        requestUpdate(job, payload: DesktopCronUpdatePayload(action: "run_now"))
                    }.disabled(busyID == job.id || job.running)
                }
                if job.controlMode == "observable_only" {
                    Text("View only").font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
                }
            }

            if let usage = job.resourceUsage {
                Divider().overlay(theme.divider)
                Text("Resource use").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                if let scope = usage.scope { labeled("Scope", value: scope) }
                if let cpu = usage.cpuPercent { labeled("CPU", value: String(format: "%.1f%%", cpu)) }
                if let memory = usage.memoryRssMb ?? usage.memoryUsedMb { labeled("Memory", value: String(format: "%.0f MB", memory)) }
                if let queue = usage.queueDepth { labeled("Queue", value: String(queue)) }
                if let note = usage.note, !note.isEmpty { Text(note).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary) }
            }

            if let estimate = job.costEstimate {
                Divider().overlay(theme.divider)
                Text("Cost estimate").font(.system(size: 12, weight: .semibold)).foregroundStyle(theme.text)
                if let hourly = estimate.hourlyUsd { labeled("Hourly", value: String(format: "$%.4f / hour", hourly)) }
                if let daily = estimate.dailyUsd { labeled("Daily", value: String(format: "$%.2f / day", daily)) }
                if let scope = estimate.scope, !scope.isEmpty { labeled("Scope", value: scope) }
                if let assumption = estimate.assumption, !assumption.isEmpty {
                    Text(assumption).font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                }
            }
        }
        .frame(minWidth: 330, maxWidth: .infinity, alignment: .leading)
    }

    private func labeled(_ label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(label).font(.system(size: 10, weight: .semibold)).foregroundStyle(theme.textTertiary)
            Spacer()
            Text(value).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).lineLimit(2).textSelection(.enabled)
        }
    }

    private func statusFilter(_ status: String) -> some View {
        let isSelected = selectedStatus == status
        return Button {
            selectedStatus = status
        } label: {
            Text(status.capitalized)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(isSelected ? theme.text : theme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 27)
                .background(
                    isSelected ? theme.cardRaised : Color.clear,
                    in: RoundedRectangle(cornerRadius: 7, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Filter by \(status == "all" ? "all" : status) jobs")
        .accessibilityValue(isSelected ? "Selected" : "Not selected")
    }

    private func compactControl(
        title: String,
        icon: String,
        label: String,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .padding(.horizontal, 9)
                .frame(height: 30)
                .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .disabled(isDisabled)
    }

    private func load() async {
        readinessRetry?.cancel()
        readinessRetry = nil
        isLoading = true
        defer { isLoading = false }
        do {
            let envelope = try await model.fetchDesktopCronJobs()
            jobs = envelope.jobs
            if selectedID.isEmpty || !jobs.contains(where: { $0.id == selectedID }) { selectedID = jobs.first?.id ?? "" }
            if let selected { scheduleDraft = selected.schedule }
            if envelope.ready == false {
                message = "Showing the job registry while live scheduler state loads."
                readinessRetry = Task {
                    do { try await Task.sleep(for: .seconds(1)) }
                    catch { return }
                    guard !Task.isCancelled else { return }
                    await load()
                }
            } else {
                message = ""
            }
        } catch { message = error.localizedDescription }
    }

    private func select(_ job: DesktopCronJob) {
        selectedID = job.id
        scheduleDraft = job.schedule
    }

    private func update(_ job: DesktopCronJob, payload: DesktopCronUpdatePayload) async {
        busyID = job.id
        defer { busyID = "" }
        do {
            let envelope = try await model.updateDesktopCronJob(job.id, payload: payload)
            jobs = envelope.jobs
            if !jobs.contains(where: { $0.id == selectedID }) { selectedID = jobs.first?.id ?? "" }
            if let selected { scheduleDraft = selected.schedule }
            message = payload.action == "run_now" ? "Run requested for \(job.name)." : "Saved \(job.name)."
        } catch { message = error.localizedDescription }
    }

    private var confirmationMessage: String {
        guard let pendingUpdate else { return "Review the change before it is sent." }
        if let schedule = pendingUpdate.payload.schedule {
            return "Change \(pendingUpdate.job.name)’s schedule to \(schedule)?"
        }
        if let enabled = pendingUpdate.payload.enabled {
            return "\(enabled ? "Enable" : "Pause") \(pendingUpdate.job.name)?"
        }
        return "Run \(pendingUpdate.job.name) now? This starts a one-time run without changing its schedule."
    }

    private func requestUpdate(_ job: DesktopCronJob, payload: DesktopCronUpdatePayload) {
        pendingUpdate = (job, payload)
        confirmsUpdate = true
    }

    private func color(for status: String) -> Color {
        switch status {
        case "failed", "blocked": return theme.danger
        case "running": return theme.accent
        case "enabled": return theme.green
        default: return theme.textTertiary
        }
    }

    private func duration(_ milliseconds: Double?) -> String {
        guard let milliseconds else { return "—" }
        if milliseconds < 1_000 { return "\(Int(milliseconds)) ms" }
        return String(format: "%.1f s", milliseconds / 1_000)
    }
}
