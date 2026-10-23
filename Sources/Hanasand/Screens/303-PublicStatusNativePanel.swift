import SwiftUI

private enum PublicStatusSection: String, CaseIterable, Identifiable {
    case overview = "Overview"
    case incidents = "Incidents"
    case history = "Daily history"
    var id: String { rawValue }
}

struct PublicStatusNativePanel: View {
    @Environment(\.desktopTheme) private var theme
    @StateObject private var model = PublicStatusViewModel()
    @State private var section: PublicStatusSection = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Picker("Status view", selection: $section) {
                    ForEach(PublicStatusSection.allCases) { item in
                        Text(item.rawValue).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 360)

                Spacer()
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(.bordered)
                .disabled(model.isLoading)
            }

            if model.isLoading && model.payload == nil {
                NativeEmptyState(title: "Loading public status", message: "Retrieving the latest verified checks and service history.")
            } else if let error = model.errorMessage, model.payload == nil {
                NativeEmptyState(title: "Status unavailable", message: error)
                Button("Try again") { Task { await model.refresh() } }
            } else if let payload = model.payload {
                if let error = model.errorMessage {
                    NativeNotice(message: "Refresh failed. Showing the last results. \(error)")
                }
                switch section {
                case .overview:
                    overview(payload)
                case .incidents:
                    incidents(payload)
                case .history:
                    history(payload)
                }
            } else {
                NativeEmptyState(title: "No status data", message: "No public status snapshot is available yet.")
            }
        }
        .task { await model.refresh() }
    }

    @ViewBuilder private func overview(_ payload: PublicStatusPayload) -> some View {
        NativeGroupPanel(title: "Overall service status", subtitle: statusDescription(payload)) {
            HStack(spacing: 12) {
                Image(systemName: statusSymbol(payload.overall))
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(statusColor(payload.overall))
                VStack(alignment: .leading, spacing: 3) {
                    Text(statusLabel(payload.overall))
                        .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(theme.text)
                    Text(payload.monitoring == "unavailable" ? "Showing the last received results" : "Public monitoring feed")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                }
                Spacer(minLength: 8)
                if model.isLoading { ProgressView().controlSize(.small) }
            }
            Text(payload.lastVerifiedAt.map { "Last verified \($0)" } ?? "No verified snapshot is available yet.")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .textSelection(.enabled)
        }

        if payload.checks.isEmpty {
            NativeEmptyState(title: "No service checks", message: "The public status feed has no current checks.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(payload.checks) { check in
                    NativeGroupPanel(title: check.checkName, subtitle: check.service) {
                        HStack {
                            Label(statusLabel(check.status), systemImage: statusSymbol(check.status))
                                .font(.system(size: 12, weight: .semibold))
                                .foregroundStyle(statusColor(check.status))
                            Spacer()
                            Text(check.latencyMilliseconds.map { "\($0) ms" } ?? "Latency unavailable")
                                .font(.system(size: 11, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                        }
                        Text(check.message.flatMap { $0.isEmpty ? nil : $0 } ?? "No additional check message.")
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .textSelection(.enabled)
                        HStack {
                            Text("90 day uptime: \(check.uptime30Days ?? "unverified")")
                            Spacer()
                            Text(check.checkedAt ?? "Not verified")
                        }
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textTertiary)
                        .textSelection(.enabled)
                    }
                }
            }
        }
    }

    @ViewBuilder private func incidents(_ payload: PublicStatusPayload) -> some View {
        if let incident = model.selectedIncident {
            NativeGroupPanel(title: incident.title, subtitle: "\(incident.service) · \(incident.checkName)") {
                Button {
                    model.clearSelectedIncident()
                } label: { Label("All incidents", systemImage: "chevron.left") }
                .buttonStyle(.plain)
                Label("\(incident.impact) · \(incident.status.capitalized)", systemImage: statusSymbol(incident.status == "resolved" ? "up" : "degraded"))
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(statusColor(incident.status == "resolved" ? "up" : "degraded"))
                Text(incident.summary).font(.system(size: 13, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                Text("Started: \(incident.startedAt)\nResolved: \(incident.resolvedAt ?? "Still open")\nCause: \(incident.cause ?? "Not provided")")
                    .font(.system(size: 11, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                if let error = model.incidentError { NativeNotice(message: "Could not load incident details: \(error)") }
                if model.isLoadingIncident { ProgressView("Loading incident details…").controlSize(.small) }
                if incident.updates.isEmpty {
                    Text("No incident updates are available.").font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textTertiary)
                } else {
                    ForEach(incident.updates) { update in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(update.status) · \(update.at)").font(.system(size: 10, weight: .semibold, design: .monospaced)).foregroundStyle(theme.textTertiary)
                            Text(update.message).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).textSelection(.enabled)
                            if let evidence = update.evidence, !evidence.isEmpty {
                                Text(evidence).font(.system(size: 11, weight: .regular)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                            }
                        }
                    }
                }
            }
        } else if payload.incidents.isEmpty {
            NativeEmptyState(title: "No incidents", message: "No incidents are reported in the available status data.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 280), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(payload.incidents) { incident in
                    NativeGroupPanel(title: incident.title, subtitle: "\(incident.service) · \(incident.impact) · \(incident.status.capitalized)") {
                        Text(incident.summary).font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary).lineLimit(4).textSelection(.enabled)
                        Text("Started \(incident.startedAt) · \(incident.resolvedAt ?? "Ongoing")")
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.textTertiary)
                        Button {
                            Task { await model.selectIncident(incident) }
                        } label: {
                            Label(model.isLoadingIncident && model.selectedIncident?.id == incident.id ? "Loading details" : "View details", systemImage: "arrow.right")
                        }
                        .buttonStyle(.bordered)
                    }
                }
            }
        }
    }

    @ViewBuilder private func history(_ payload: PublicStatusPayload) -> some View {
        if payload.historyAvailable == false {
            NativeNotice(message: "Daily history is temporarily unavailable. The current checks remain available.")
        }
        if payload.history.isEmpty {
            NativeEmptyState(title: "No daily history", message: "Daily check history has not been published in the available snapshot.")
        } else {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 12, alignment: .top)], alignment: .leading, spacing: 12) {
                ForEach(payload.history) { day in
                    NativeGroupPanel(title: day.checkName, subtitle: "\(day.service) · \(day.date)") {
                        Label(statusLabel(day.status), systemImage: statusSymbol(day.status))
                            .font(.system(size: 12, weight: .semibold)).foregroundStyle(statusColor(day.status))
                        Text("Samples: \(day.samples.map { String($0) } ?? "—") · Healthy: \(day.healthySamples.map { String($0) } ?? "—") · Degraded: \(day.degradedSamples.map { String($0) } ?? "—") · Failed: \(day.failedSamples.map { String($0) } ?? "—")")
                            .font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.textSecondary)
                            .textSelection(.enabled)
                        Text(day.incidentIDs.isEmpty ? "No linked incidents" : "Linked incidents: \(day.incidentIDs.count)")
                            .font(.system(size: 10, weight: .medium)).foregroundStyle(theme.textTertiary).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private func statusDescription(_ payload: PublicStatusPayload) -> String {
        payload.lastVerifiedAt.map { "Public monitoring · last verified \($0)" } ?? "Public monitoring snapshot"
    }

    private func statusLabel(_ value: String) -> String {
        switch value.lowercased() {
        case "up", "normal": return "Normal"
        case "degraded", "investigating": return value == "investigating" ? "Investigating" : "Degraded"
        case "down", "outage": return "Down"
        default: return "Unverified"
        }
    }

    private func statusSymbol(_ value: String) -> String {
        switch value.lowercased() {
        case "up", "normal", "resolved": return "checkmark.circle.fill"
        case "degraded", "investigating": return "exclamationmark.triangle.fill"
        case "down", "outage": return "xmark.circle.fill"
        default: return "questionmark.circle"
        }
    }

    private func statusColor(_ value: String) -> Color {
        switch value.lowercased() {
        case "up", "normal", "resolved": return theme.green
        case "degraded", "investigating": return theme.accent
        case "down", "outage": return theme.danger
        default: return theme.textTertiary
        }
    }
}
