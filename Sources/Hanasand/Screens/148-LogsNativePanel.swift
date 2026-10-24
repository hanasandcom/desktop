import AppKit
import ApplicationServices
import Charts
import Combine
import CryptoKit
import Darwin
import Foundation
import Network
import PDFKit
import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct LogsNativePanel: View {
    @EnvironmentObject var model: DesktopAgentModel
    @Environment(\.desktopTheme) var theme
    @State var searchText = ""
    @State var selectedService = "all"
    @State var selectedLevel = "all"
    @State var expandedIDs: Set<String> = []
    @State private var dashboardData: LogsSearchPage?
    @State private var dashboardSummary: LogsDashboardSummary?
    @State private var throughput: LogsThroughputMetrics?
    @State private var dashboardLoadError = ""
    @State private var summaryLoadError = ""
    @State private var throughputLoadError = ""
    @State private var showingTotalCounts = false
    @State private var selectedHours = 24
    @State private var copiedEventID = ""

    init(initialServiceFilter: String? = nil) {
        let service = initialServiceFilter?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        _selectedService = State(initialValue: service.isEmpty ? "all" : service)
    }

    let columns = [
        GridItem(.adaptive(minimum: 220), spacing: 12, alignment: .top),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let dashboardData {
                dashboardAnalytics(dashboardData)
            } else if !dashboardLoadError.isEmpty {
                NativeGroupPanel(title: "Log analytics unavailable", subtitle: dashboardLoadError) {
                    ActionButton(title: "Retry analytics", icon: "arrow.clockwise") {
                        Task { await refreshDashboardAnalytics() }
                    }
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                FeatureCard(title: "Logs", value: "\(model.logs.count)", icon: "doc.text.magnifyingglass")
                FeatureCard(title: "Errors", value: "\(model.logs.filter(\.isError).count)", icon: "exclamationmark.triangle")
                FeatureCard(title: "Services", value: "\(services.count)", icon: "server.rack")
                FeatureCard(title: "Native", value: "\(model.logs.filter { $0.source == "native" }.count)", icon: "lock.shield")
            }

            HStack(spacing: 10) {
                SearchFieldRow(placeholder: "Search logs by service, host, message, or metadata", text: $searchText)
                ActionButton(title: "Refresh", icon: "arrow.clockwise") {
                    Task {
                        await model.loadNativeDashboardData()
                        await refreshDashboardAnalytics()
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach([24, 168, 720, 2160], id: \.self) { hours in
                        FilterChip(title: hours == 24 ? "24 hours" : "\(hours / 24) days", active: selectedHours == hours) {
                            selectedHours = hours
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    FilterChip(title: "All services", active: selectedService == "all") {
                        selectedService = "all"
                    }
                    ForEach(displayedServices, id: \.self) { service in
                        FilterChip(title: service, active: selectedService == service) {
                            selectedService = service
                        }
                    }
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(DashboardLogLevelFilter.options, id: \.self) { level in
                        FilterChip(title: level == "high" ? "High severity" : level.capitalized, active: selectedLevel == level) {
                            selectedLevel = level
                        }
                    }
                }
            }

            if let dashboardData, !dashboardData.rows.isEmpty {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredSearchLogs.prefix(200)) { log in
                        searchLogRow(log)
                    }
                }
            } else if dashboardData != nil {
                NativeEmptyState(title: "No matching logs", message: "Adjust service, level, search, or time filters.")
            } else if model.logs.isEmpty {
                NativeEmptyState(title: "No logs loaded", message: "Use Refresh to load application logs. Try the Logs dashboard after configuring auth in Settings.")
            } else if filteredLogs.isEmpty {
                NativeGroupPanel(title: "No matching logs", subtitle: "Adjust service, level, or search filters.") {
                    Text("The native log viewer has data loaded, but none of the entries match the active filters.")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(theme.textSecondary)
                }
            } else {
                LazyVStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredLogs.prefix(120)) { log in
                        logRow(log)
                    }
                }
            }
        }
        .task(id: "\(model.settings.apiBaseURL)|\(model.userIDForRequests)|\(selectedHours)|\(selectedService)|\(selectedLevel)|\(searchText)") {
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                await refreshDashboardAnalytics()
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
            }
        }
    }

    var services: [String] {
        Array(Set(model.logs.map(\.service))).sorted()
    }

    @ViewBuilder
    private func dashboardAnalytics(_ data: LogsSearchPage) -> some View {
        HStack {
            Text("Severity counts")
                .font(.system(size: 14, weight: .bold))
                .foregroundStyle(theme.text)
            Spacer()
            Picker("Count range", selection: $showingTotalCounts) {
                Text("24 hours").tag(false)
                Text("Total").tag(true)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)
        }
        LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
            ForEach(["low", "medium", "high", "critical"], id: \.self) { severity in
                let summary = showingTotalCounts
                    ? dashboardSummary?.total.severities[severity]
                    : (dashboardSummary?.last24Hours.severities[severity]
                        ?? data.counts.first(where: { $0.severity == severity })?.count)
                FeatureCard(title: "\(severity.capitalized) · \(showingTotalCounts ? "total" : "24h")", value: summary.map(String.init) ?? "—", icon: severity == "critical" ? "exclamationmark.octagon" : "chart.bar")
            }
        }
        if let progress = data.processing?.catchup, progress.remaining > 1_000 {
            NativeGroupPanel(title: "Log processing lag", subtitle: "\(progress.remaining.formatted()) logs remain · \(progress.processed.formatted()) of \(progress.total.formatted()) processed") {
                ProgressView(value: progress.total > 0 ? Double(progress.processed) / Double(progress.total) : 0)
                Text(progress.lastError ?? "Checked \(progress.updatedAt)")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
        } else if let error = data.processing?.lastError, !error.hasSuffix("Waiting for active log writes; will retry.") {
            NativeGroupPanel(title: "Log processor delayed", subtitle: error) {
                Text("Processor status checked \(data.processing?.updatedAt ?? "recently")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
        } else if data.processing == nil {
            NativeGroupPanel(title: "Log processor status unavailable", subtitle: "The processor has not reported a recent check-in.") {
                Text("Dashboard data checked \(data.generatedAt ?? "recently")")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
            }
        }
        if let throughput {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                FeatureCard(title: "Events checked / sec", value: throughput.current.pps.formatted(.number.precision(.fractionLength(1))), icon: "checkmark.circle")
                FeatureCard(title: "Incoming / sec", value: throughput.current.eps.formatted(.number.precision(.fractionLength(1))), icon: "arrow.down.circle")
                FeatureCard(title: "Backlog / sec", value: throughput.current.historicalEps.formatted(.number.precision(.fractionLength(1))), icon: "clock.arrow.circlepath")
                FeatureCard(title: "Logs remaining", value: throughput.current.remaining.formatted(), icon: "tray.full")
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 12) {
                throughputChart("Incoming logs / sec", keyPath: \.eps, data: throughput.history)
                throughputChart("Checked events / sec", keyPath: \.pps, data: throughput.history)
                throughputChart("Backlog / sec", keyPath: \.npps, data: throughput.history)
            }
        } else if !throughputLoadError.isEmpty {
            Text("Throughput metrics are temporarily unavailable: \(throughputLoadError)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
        if let summary = dashboardSummary, !(showingTotalCounts ? summary.total.services : summary.last24Hours.services).isEmpty {
            NativeGroupPanel(title: "Most active services · \(showingTotalCounts ? "total" : "24 hours")", subtitle: "Top services by log volume") {
                ForEach((showingTotalCounts ? summary.total.services : summary.last24Hours.services).prefix(10), id: \.service) { item in
                    HStack {
                        Text(item.service).lineLimit(1)
                        Spacer()
                        Text(item.count.formatted()).monospacedDigit()
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                }
            }
        } else if !summaryLoadError.isEmpty {
            Text("Most active service counts are temporarily unavailable: \(summaryLoadError)")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.textSecondary)
        }
    }

    @ViewBuilder
    private func throughputChart(
        _ title: String, keyPath: KeyPath<LogsThroughputMetrics.Point, Double>,
        data: [LogsThroughputMetrics.Point]
    ) -> some View {
        NativeGroupPanel(title: title, subtitle: "Five-minute average · 24 hours") {
            if data.isEmpty {
                Text("Collecting throughput samples…")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.textSecondary)
                    .frame(maxWidth: .infinity, minHeight: 110)
            } else {
                Chart(data, id: \.sampledAt) { point in
                    if let date = ISO8601DateFormatter().date(from: point.sampledAt) {
                        AreaMark(x: .value("Time", date), y: .value("Rate", point[keyPath: keyPath]))
                            .foregroundStyle(theme.accent.opacity(0.12))
                        LineMark(x: .value("Time", date), y: .value("Rate", point[keyPath: keyPath]))
                            .foregroundStyle(theme.accent)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: true))
                .frame(height: 120)
            }
        }
    }

    @MainActor
    private func refreshDashboardAnalytics() async {
        do {
            let accountID = model.userIDForRequests
            let accountToken = model.authTokenForRequests
            let apiAddress = model.settings.apiBaseURL
            let client = try LogsSearchClient(
                apiBaseURL: apiAddress.normalizedBaseURL,
                userID: accountID,
                token: accountToken,
                impersonationToken: model.settings.impersonationToken,
                impersonatingUserID: model.settings.impersonatingUserID
            )
            let severity = ["low", "medium", "critical"].contains(selectedLevel) ? selectedLevel : "all"
            let filters = LogsSearchFilters(
                hours: selectedHours,
                service: selectedService == "all" ? "" : selectedService,
                severity: severity,
                search: searchText,
                dashboardStats: true
            )
            async let dashboard = captureResult { try await client.load(filters: filters) }
            async let summary = captureResult { try await client.loadDashboardSummary() }
            async let metrics = captureResult { try await client.loadPublicThroughputMetrics() }
            let dashboardResult = await dashboard
            let summaryResult = await summary
            let metricsResult = await metrics
            guard !Task.isCancelled, accountID == model.userIDForRequests,
                  accountToken == model.authTokenForRequests, apiAddress == model.settings.apiBaseURL
            else { return }
            switch dashboardResult {
            case .success(let value): dashboardData = value; dashboardLoadError = ""
            case .failure(let error): dashboardLoadError = error.localizedDescription
            }
            switch summaryResult {
            case .success(let value): dashboardSummary = value; summaryLoadError = ""
            case .failure(let error): summaryLoadError = error.localizedDescription
            }
            switch metricsResult {
            case .success(let value): throughput = value; throughputLoadError = ""
            case .failure(let error): throughputLoadError = error.localizedDescription
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled else { return }
            dashboardLoadError = error.localizedDescription
        }
    }

    private func captureResult<Value>(_ operation: () async throws -> Value) async -> Result<Value, Error> {
        do { return .success(try await operation()) }
        catch { return .failure(error) }
    }

    private var displayedServices: [String] {
        let visible = Array(services.prefix(12))
        guard selectedService != "all", !visible.contains(selectedService) else { return visible }
        return [selectedService] + visible
    }

    private var filteredSearchLogs: [LogsSearchEvent] {
        (dashboardData?.rows ?? []).filter { DashboardLogLevelFilter.matches(level: $0.level, filter: selectedLevel) }
    }

    private func searchLogRow(_ log: LogsSearchEvent) -> some View {
        let isOpen = expandedIDs.contains(log.id)
        return HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(log.service)
                        .font(.system(size: 12, weight: .black))
                        .foregroundStyle(theme.text)
                    Text(log.level.uppercased())
                        .font(.system(size: 10, weight: .black))
                        .foregroundStyle(log.severity == "high" || log.severity == "critical" ? theme.danger : theme.textTertiary)
                    Text(log.timestamp)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    Spacer()
                    if !log.host.isEmpty {
                        Text(log.host)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                }
                Text(log.message.isEmpty ? "No message" : log.message)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(isOpen ? nil : 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if isOpen { expandedIDs.remove(log.id) } else { expandedIDs.insert(log.id) }
            }
            .textSelection(.enabled)
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(log.copyJSON, forType: .string)
                copiedEventID = log.id
            } label: {
                Image(systemName: copiedEventID == log.id ? "checkmark" : "doc.on.doc")
                    .foregroundStyle(theme.textTertiary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copiedEventID == log.id ? "Copied log JSON" : "Copy log JSON")
            .help("Copy event JSON")
        }
        .padding(13)
        .background(theme.card)
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(log.severity == "high" || log.severity == "critical" ? theme.danger.opacity(0.45) : theme.divider, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    var filteredLogs: [DashboardLogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return model.logs.filter { log in
            let serviceMatch = selectedService == "all" || log.service == selectedService
            let levelMatch = DashboardLogLevelFilter.matches(level: log.level, filter: selectedLevel)
            let searchable = [
                log.service,
                log.host ?? "",
                log.level,
                log.message,
                log.source ?? "",
                log.metadata?.pretty ?? "",
            ].joined(separator: " ").lowercased()
            return serviceMatch && levelMatch && (query.isEmpty || searchable.contains(query))
        }
    }

    @ViewBuilder
    func logRow(_ log: DashboardLogEntry) -> some View {
        let isOpen = expandedIDs.contains(log.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: log.isError ? "exclamationmark.triangle.fill" : "terminal")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(log.isError ? theme.danger : theme.accent)
                    .frame(width: 34, height: 34)
                    .background(theme.cardRaised)
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))

                Button {
                    if isOpen {
                        expandedIDs.remove(log.id)
                    } else {
                        expandedIDs.insert(log.id)
                    }
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(spacing: 8) {
                            Text(log.service)
                                .font(.system(size: 12, weight: .black))
                                .foregroundStyle(theme.text)
                            Text(log.level.uppercased())
                                .font(.system(size: 10, weight: .black))
                                .foregroundStyle(log.isError ? theme.danger : theme.textTertiary)
                            if let source = log.source {
                                Text(source)
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(theme.textTertiary)
                            }
                        }
                        Text(log.message.isEmpty ? "No message" : log.message)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                            .lineLimit(isOpen ? nil : 2)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .buttonStyle(.plain)

                Spacer()
                VStack(alignment: .trailing, spacing: 5) {
                    Text(log.createdLabel)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(theme.textTertiary)
                    if let host = log.host, !host.isEmpty {
                        Text(host)
                            .font(.system(size: 10, weight: .semibold, design: .monospaced))
                            .foregroundStyle(theme.textTertiary)
                            .lineLimit(1)
                    }
                }
            }

            if isOpen, let metadata = log.metadata {
                Text(metadata.pretty)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .textSelection(.enabled)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.backgroundElevated.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
        .padding(13)
        .background(theme.card)
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(log.isError ? theme.danger.opacity(0.45) : theme.divider, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
