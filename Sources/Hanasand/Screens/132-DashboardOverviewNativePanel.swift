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

struct DashboardOverviewNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State var searchText = ""
    @State var selectedStatus = "all"
    @State private var monitoringOverview = DashboardMonitoringOverviewState.loading
    @State private var monitoringRequestID = UUID()

    let columns = [
        GridItem(.adaptive(minimum: 260), spacing: 12, alignment: .top),
    ]
    let metricColumns = [
        GridItem(.adaptive(minimum: 140), spacing: 10, alignment: .top),
    ]
    let overviewMetricColumns = [
        GridItem(.adaptive(minimum: 240), spacing: 10, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            monitoringPanel

            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                FeatureCard(title: "Overall", value: status?.overall.capitalized ?? "Unknown", icon: statusIcon(status?.overall ?? "unknown"))
                FeatureCard(title: "Checks", value: "\(status?.checks.count ?? 0)", icon: "checklist")
                FeatureCard(title: "Down", value: "\(status?.checks.filter { $0.statusLabel.lowercased() == "down" }.count ?? 0)", icon: "xmark.octagon")
                FeatureCard(title: "Generated", value: status?.generatedLabel ?? "Unknown", icon: "clock")
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    SearchFieldRow(placeholder: "Search services or checks", text: $searchText)
                        .frame(minWidth: 240, maxWidth: .infinity)
                    refreshButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    SearchFieldRow(placeholder: "Search services or checks", text: $searchText)
                    refreshButton
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(statuses, id: \.self) { value in
                        FilterChip(title: value.capitalized, active: selectedStatus == value) {
                            selectedStatus = value
                        }
                    }
                }
            }

            if status == nil {
                NativeEmptyState(title: "Status not loaded", message: "Use Refresh to load service status checks.")
            } else if filteredChecks.isEmpty {
                NativeGroupPanel(title: "No matching checks", subtitle: "Adjust service search or status filters.") {
                    Text("Service checks are loaded, but none match the active filters.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                    ForEach(groupedChecks, id: \.service) { group in
                        serviceCard(service: group.service, checks: group.checks)
                    }
                }
            }
        }
        .task(id: monitoringScopeKey) { await loadMonitoringOverview() }
    }

    var status: DashboardServiceStatus? {
        model.serviceStatus
    }

    private var monitoringScopeKey: String {
        let settings = model.settings
        return [settings.websiteBaseURL, settings.userID, String(settings.authToken.hashValue),
                settings.selectedOrganizationID, settings.selectedOrganizationUserID,
                settings.impersonatingUserID, settings.impersonationToken.isEmpty ? "own-account" : "impersonating"].joined(separator: "|")
    }

    @ViewBuilder
    private var monitoringPanel: some View {
        NativeGroupPanel(
            title: model.selectedOrganizationID.isEmpty ? "Personal monitoring" : "Organization monitoring",
            subtitle: "Monitoring snapshot, alerts, source coverage, and readiness"
        ) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    Text("What Hanasand found for the terms you are watching.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                        .lineLimit(2)
                    Spacer(minLength: 8)
                    openMonitoringButton
                    refreshOverviewButton
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("What Hanasand found for the terms you are watching.")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(theme.textSecondary)
                    HStack(spacing: 8) {
                        openMonitoringButton
                        refreshOverviewButton
                    }
                }
            }

            if monitoringOverview.isLoading && monitoringOverview.snapshot == nil {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Loading monitoring overview…").font(.system(size: 12, weight: .medium)).foregroundStyle(theme.textSecondary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityAddTraits(.updatesFrequently)
            }

            if let message = monitoringOverview.errorMessage {
                NativeNotice(message: message, title: "Monitoring overview unavailable")
            } else if let snapshot = monitoringOverview.snapshot {
                if snapshot.watchlist.isEmpty {
                    NativeEmptyState(title: "Start monitoring", message: "Create a watchlist to monitor companies, domains, brands, and vendors.")
                    ActionButton(title: "Create watchlist", icon: "arrow.right") {
                        model.openNativeDashboard(path: "/watchlists", label: "Watchlists")
                    }
                } else {
                    LazyVGrid(columns: overviewMetricColumns, alignment: .leading, spacing: 10) {
                        monitoringMetric(title: "Active watch terms", value: "\(snapshot.watchlist.count)", detail: snapshot.watchlistDetail, icon: "dot.radiowaves.left.and.right")
                        monitoringMetric(title: "New matches · 7 days", value: "\(snapshot.recentMatchCount)", detail: snapshot.recentMatchDetail, icon: "shield.lefthalf.filled")
                        monitoringMetric(title: "Open alerts", value: "\(snapshot.openAlertCount)", detail: snapshot.openAlertDetail, icon: "bell.badge")
                        monitoringMetric(title: "Open cases", value: monitoringOverview.openCaseValue, detail: monitoringOverview.openCaseDetail, icon: "ticket")
                        monitoringMetric(title: "Source health", value: snapshot.sourceHealthValue, detail: snapshot.sourceHealthDetail, icon: "checkmark.shield")
                        monitoringMetric(title: "Latest evidence", value: snapshot.latestEvidenceValue, detail: snapshot.latestEvidenceDetail, icon: "doc.text.magnifyingglass")
                    }
                    if let latest = snapshot.latestEvidence {
                        Label("Latest evidence: \(latest.sourceName) · \(latest.latestTimestamp ?? "time not reported")", systemImage: "doc.text")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(2)
                            .textSelection(.enabled)
                    }
                    if let casesMessage = monitoringOverview.casesErrorMessage {
                        Text("Open cases: \(casesMessage)")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(theme.textSecondary)
                    }
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Label(snapshot.isReady ? "Collection is active" : "Collection needs setup", systemImage: snapshot.isReady ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(snapshot.isReady ? theme.green : theme.accent)
                        Spacer(minLength: 4)
                        Text("Updated \(overviewAge(snapshot.generatedAt))")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                    if !snapshot.isReady, let blocker = snapshot.readiness.blockers.first, !blocker.isEmpty {
                        Text(blocker).font(.system(size: 11, weight: .medium)).foregroundStyle(theme.textSecondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .accessibilityIdentifier("dashboard.monitoring-overview")
    }

    private var openMonitoringButton: some View {
        ActionButton(title: "Open monitoring", icon: "dot.radiowaves.left.and.right") {
            model.openNativeDashboard(path: "/findings", label: "Findings")
        }
    }

    private func monitoringMetric(title: String, value: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(theme.textTertiary)
                    .textCase(.uppercase)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
            Text(value)
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(theme.text)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .textSelection(.enabled)
            Text(detail)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 98, alignment: .leading)
        .background(theme.cardRaised)
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(theme.divider.opacity(0.7), lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title), \(value), \(detail)")
    }

    private var refreshOverviewButton: some View {
        ActionButton(title: monitoringOverview.isLoading ? "Refreshing…" : "Refresh overview", icon: "arrow.clockwise") {
            Task { await loadMonitoringOverview() }
        }
        .disabled(monitoringOverview.isLoading)
    }

    @MainActor
    private func loadMonitoringOverview() async {
        let requestID = UUID()
        monitoringRequestID = requestID
        monitoringOverview = DashboardMonitoringOverviewState(snapshot: monitoringOverview.snapshot, openCaseCount: monitoringOverview.openCaseCount,
                                                               isLoading: true, errorMessage: nil, casesErrorMessage: nil)
        do {
            let client = try DashboardMonitoringOverviewClient(settings: model.settings)
            async let snapshotResult = client.load()
            async let casesResult = client.loadOpenCaseCount()
            let snapshot = try await snapshotResult
            let cases = await casesResult
            guard monitoringRequestID == requestID else { return }
            switch cases {
            case .success(let count):
                monitoringOverview = DashboardMonitoringOverviewState(snapshot: snapshot, openCaseCount: count, isLoading: false, errorMessage: nil, casesErrorMessage: nil)
            case .failure(let error):
                monitoringOverview = DashboardMonitoringOverviewState(snapshot: snapshot, openCaseCount: nil, isLoading: false, errorMessage: nil, casesErrorMessage: error.localizedDescription)
            }
        } catch {
            guard monitoringRequestID == requestID else { return }
            monitoringOverview = DashboardMonitoringOverviewState(snapshot: nil, openCaseCount: nil, isLoading: false,
                                                                   errorMessage: error.localizedDescription, casesErrorMessage: nil)
        }
    }

    private func overviewAge(_ value: String) -> String {
        guard let date = DashboardMonitoringOverview.date(from: value) else { return "recently" }
        let minutes = max(0, Int(Date().timeIntervalSince(date) / 60))
        if minutes < 1 { return "just now" }
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = minutes / 60
        if hours < 24 { return "\(hours)h ago" }
        return "\(hours / 24)d ago"
    }

    private var refreshButton: some View {
        ActionButton(title: "Refresh", icon: "arrow.clockwise") {
            Task { await model.loadNativeDashboardData() }
        }
    }

    var statuses: [String] {
        ["all"] + Array(Set((status?.checks ?? []).map { $0.statusLabel.lowercased() })).sorted()
    }

    var filteredChecks: [ServiceCheck] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return (status?.checks ?? []).filter { check in
            let statusMatch = selectedStatus == "all" || check.statusLabel.lowercased() == selectedStatus
            let searchable = [
                check.service,
                check.checkLabel,
                check.statusLabel,
                check.message ?? "",
            ].joined(separator: " ").lowercased()
            return statusMatch && (query.isEmpty || searchable.contains(query))
        }
    }

    var groupedChecks: [(service: String, checks: [ServiceCheck])] {
        Dictionary(grouping: filteredChecks, by: \.service)
            .map { (service: $0.key, checks: $0.value.sorted { $0.checkName < $1.checkName }) }
            .sorted { $0.service < $1.service }
    }

    func serviceCard(service: String, checks: [ServiceCheck]) -> some View {
        let worstStatus = checks.contains { $0.statusLabel.lowercased() == "down" }
            ? "down"
            : checks.contains { $0.statusLabel.lowercased() == "degraded" }
                ? "degraded"
                : "up"

        return NativeGroupPanel(title: service, subtitle: "\(checks.count) checks") {
            LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 10) {
                FeatureCard(title: "Status", value: worstStatus.capitalized, icon: statusIcon(worstStatus))
                FeatureCard(title: "Avg latency", value: averageLatencyLabel(checks), icon: "timer")
                FeatureCard(title: "Uptime", value: averageUptimeLabel(checks), icon: "arrow.up.heart")
            }

            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(checks) { check in
                    HStack(alignment: .top, spacing: 10) {
                        Circle()
                            .fill(statusColor(check.statusLabel))
                            .frame(width: 9, height: 9)
                            .padding(.top, 5)
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Text(check.checkLabel)
                                    .font(.system(size: 12, weight: .black))
                                    .foregroundStyle(theme.text)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                Text(check.statusLabel.uppercased())
                                    .font(.system(size: 10, weight: .black))
                                    .foregroundStyle(statusColor(check.statusLabel))
                            }
                            Text([check.latencyLabel, check.uptimeLabel, check.checkedLabel].joined(separator: " · "))
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(theme.textTertiary)
                                .fixedSize(horizontal: false, vertical: true)
                            if let message = check.message, !message.isEmpty {
                                Text(message)
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(theme.textSecondary)
                                    .lineLimit(2)
                            }
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(theme.cardRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
            }
        }
    }

    func averageLatencyLabel(_ checks: [ServiceCheck]) -> String {
        let values = checks.compactMap(\.latencyMs)
        guard !values.isEmpty else { return "Unknown" }
        return "\(Int((values.reduce(0, +) / Double(values.count)).rounded())) ms"
    }

    func averageUptimeLabel(_ checks: [ServiceCheck]) -> String {
        let values = checks.compactMap { Double($0.uptime30d ?? "") }
        guard !values.isEmpty else { return "0%" }
        return "\(String(format: "%.1f", values.reduce(0, +) / Double(values.count)))%"
    }

    func statusIcon(_ value: String) -> String {
        switch value.lowercased() {
        case "up": return "checkmark.circle"
        case "degraded": return "exclamationmark.triangle"
        case "down": return "xmark.octagon"
        default: return "questionmark.circle"
        }
    }

    func statusColor(_ value: String) -> Color {
        switch value.lowercased() {
        case "up": return theme.green
        case "degraded": return theme.accent
        case "down": return theme.danger
        default: return theme.textTertiary
        }
    }
}
