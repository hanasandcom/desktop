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

extension RecentTestsNativePanel {
    func selectedTestPanel(_ test: DashboardRecentTest) -> some View {
        let liveForTest = liveSession.testID == test.id
        let displayedStatus = liveForTest ? (liveSession.completionStatus ?? test.statusLabel) : test.statusLabel
        let displayedLogs = (test.logs ?? []) + (liveForTest ? liveSession.logs : [])
        let displayedErrors = (test.errors ?? []) + (liveForTest ? liveSession.errors : [])
        let displayedSummary = liveForTest ? (liveSession.summary ?? test.activeSummary) : test.activeSummary
        return NativeGroupPanel(title: "Test result", subtitle: "Test \(test.id)") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                FeatureCard(title: "Status", value: displayedStatus.capitalized, icon: statusIcon(displayedStatus))
                FeatureCard(title: "Timeout", value: test.timeout.map { "\($0)s" } ?? "Default", icon: "timer")
                if liveForTest, let duration = liveSession.durationMilliseconds {
                    FeatureCard(title: "Duration", value: "\(duration)ms", icon: "stopwatch")
                }
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
                FeatureCard(title: "Live stream", value: liveForTest ? liveSession.status : "Not listening", icon: liveSession.isListening && liveForTest ? "waveform" : "wifi.slash")
                if liveForTest, let participants = liveSession.participants {
                    FeatureCard(title: "Viewers", value: String(participants), icon: "person.2")
                }
                if liveForTest, let code = liveSession.exitCode {
                    FeatureCard(title: "Exit code", value: String(code), icon: code == 0 ? "checkmark.circle" : "exclamationmark.triangle")
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    liveActionButton(liveForTest: liveForTest)
                    liveStreamNote
                }
                VStack(alignment: .leading, spacing: 8) {
                    liveActionButton(liveForTest: liveForTest)
                    liveStreamNote
                }
            }
            Text(test.displayURL)
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(theme.textSecondary)
                .lineLimit(3)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 8) {
                ActionButton(title: "Refresh detail", icon: "arrow.clockwise") { Task { await openResult(id: test.id) } }
                if !["queued", "running"].contains(test.statusLabel.lowercased()) {
                    ActionButton(title: "Rerun", icon: "play.fill") {
                        guard canRerun else { return }
                        showRerunConfirmation = true
                    }
                    .disabled(!canRerun)
                }
                ActionButton(title: "Copy link", icon: "doc.on.doc") { copyResultLink(test) }
                ActionButton(title: "Open", icon: "arrow.up.right") {
                    guard NativeRouteSelection.resolve(test.id, among: [test.id]) != nil else { return }
                    selectedTest = test
                    model.openNativeDashboard(path: "/test", label: "Test \(test.id)")
                    Task { await openResult(id: test.id) }
                }
            }
            LoadTestSummaryPanel(
                title: "Latest run metrics",
                summary: DashboardLoadTestSummary(value: displayedSummary),
                isCollecting: ["queued", "running", "pending"].contains(displayedStatus.lowercased())
            )
            if let previousSummary = test.previousReportSummary {
                LoadTestSummaryPanel(title: "Previous run for this endpoint", summary: previousSummary, isCollecting: false)
                if let delta = test.p95DeltaMs, delta.isFinite {
                    Label(
                        delta == 0 ? "p95 unchanged from previous run" : "Latest p95 is \(metricNumber(abs(delta)))ms \(delta > 0 ? "faster" : "slower") than previous run",
                        systemImage: delta >= 0 ? "arrow.down.right" : "arrow.up.right"
                    )
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(delta >= 0 ? theme.green : theme.danger)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(delta == 0 ? "p95 unchanged from previous run" : "Latest p95 is \(metricNumber(abs(delta))) milliseconds \(delta > 0 ? "faster" : "slower") than previous run")
                }
            }
            if !displayedErrors.isEmpty {
                if showLiveErrors {
                    NativeGroupPanel(title: "Errors · \(displayedErrors.count)", subtitle: liveForTest && liveSession.outputLimited ? "Output is bounded; refresh stored results for the final record." : "Stored and live output") {
                        ActionButton(title: "Hide errors", icon: "eye.slash") { showLiveErrors = false }
                        ForEach(Array(displayedErrors.suffix(100).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.system(size: 10, weight: .medium, design: .monospaced)).foregroundStyle(theme.danger).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    ActionButton(title: "Show errors · \(displayedErrors.count)", icon: "exclamationmark.triangle") { showLiveErrors = true }
                }
            }
            if !displayedLogs.isEmpty {
                if showLiveLogs {
                    NativeGroupPanel(title: "Output · \(displayedLogs.count)", subtitle: liveForTest && liveSession.outputLimited ? "Live output is bounded; refresh stored results for the final record." : "Stored and live output") {
                        ActionButton(title: "Hide output", icon: "eye.slash") { showLiveLogs = false }
                        ForEach(Array(displayedLogs.suffix(100).enumerated()), id: \.offset) { _, line in
                            Text(line)
                                .font(.system(size: 10, weight: .medium, design: .monospaced))
                                .foregroundStyle(theme.textSecondary)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                } else {
                    ActionButton(title: "Show output · \(displayedLogs.count)", icon: "text.alignleft") { showLiveLogs = true }
                }
            }
        }
    }

    func testCard(_ test: DashboardRecentTest) -> some View {
        NativeGroupPanel(title: test.displayURL, subtitle: "Test \(test.id)") {
            HStack(spacing: 10) {
                FeatureCard(title: "Status", value: test.statusLabel.capitalized, icon: statusIcon(test))
                FeatureCard(title: "p95", value: test.p95Milliseconds.map { "\(Int($0.rounded())) ms" } ?? "Unknown", icon: "timer")
                FeatureCard(title: "Requests", value: test.requestCount.map(String.init) ?? "Unknown", icon: "arrow.left.arrow.right")
            }
            HStack(spacing: 8) {
                if let failureRate = test.failureRatePercent {
                    Text("fail \(String(format: "%.1f", failureRate))%")
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle(failureRate > 1 ? theme.danger : theme.green)
                        .padding(.horizontal, 9).frame(height: 24).background(theme.cardRaised).clipShape(Capsule())
                }
                if let delta = test.p95DeltaLabel {
                    Text(delta)
                        .font(.system(size: 11, weight: .black))
                        .foregroundStyle((test.p95DeltaMs ?? 0) >= 0 ? theme.green : theme.danger)
                        .padding(.horizontal, 9).frame(height: 24).background(theme.cardRaised).clipShape(Capsule())
                }
                Text("\(test.visits ?? 0) visits")
                    .font(.system(size: 11, weight: .bold)).foregroundStyle(theme.textSecondary)
                    .padding(.horizontal, 9).frame(height: 24).background(theme.cardRaised).clipShape(Capsule())
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Image(systemName: "calendar")
                Text(test.createdLabel)
                Spacer(minLength: 4)
                ActionButton(title: "Details", icon: "doc.text.magnifyingglass") { Task { await openResult(id: test.id) } }
                if !["queued", "running"].contains(test.statusLabel.lowercased()) {
                    ActionButton(title: "Rerun", icon: "play.fill") {
                        guard canRerun else { return }
                        selectedTest = test
                        showRerunConfirmation = true
                    }
                    .disabled(!canRerun)
                }
            }
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(theme.textSecondary)
            if let errors = test.errors, !errors.isEmpty {
                NativeNotice(message: errors.prefix(2).joined(separator: "\n"), title: "Test issue")
            }
        }
    }

    private func liveActionButton(liveForTest: Bool) -> some View {
        Group {
            if liveSession.isListening && liveForTest {
                ActionButton(title: "Stop listening", icon: "stop.circle") { liveSession.stopListening() }
            } else {
                ActionButton(title: "Listen to live output", icon: "dot.radiowaves.left.and.right") {
                    guard canJoinLive else { return }
                    showLiveJoinConfirmation = true
                }
                .disabled(!canJoinLive)
            }
        }
    }

    private var liveStreamNote: some View {
        Text("Public stream · manual join · no automatic reconnect")
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(theme.textTertiary)
    }

    var statuses: [String] {
        ["all"] + Array(Set(((selectedLane == .mine ? myTests : recentTests) ?? []).map { $0.statusLabel.lowercased() })).sorted()
    }

    func statusIcon(_ test: DashboardRecentTest) -> String {
        statusIcon(test.statusLabel)
    }

    func statusIcon(_ status: String) -> String {
        switch status.lowercased() {
        case "done", "complete", "completed": return "checkmark.circle"
        case "failed", "error": return "exclamationmark.triangle"
        case "queued": return "clock"
        default: return "waveform.path.ecg"
        }
    }

    func copyResultLink(_ test: DashboardRecentTest) {
        let url = model.settings.websiteBaseURL.normalizedBaseURL.appendingPathComponent("test/\(test.id)").absoluteString
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
        noticeMessage = "Copied result link."
    }
}

private struct LoadTestSummaryPanel: View {
    let title: String
    let summary: DashboardLoadTestSummary?
    let isCollecting: Bool

    private let metricColumns = [GridItem(.adaptive(minimum: 140), spacing: 8, alignment: .top)]

    var body: some View {
        NativeGroupPanel(title: title, subtitle: "Aggregate measurements and chronological samples") {
            if let summary {
                LazyVGrid(columns: metricColumns, alignment: .leading, spacing: 8) {
                    FeatureCard(title: "Requests", value: summary.requests.map(String.init) ?? "Unavailable", icon: "arrow.left.arrow.right")
                    FeatureCard(title: "p95 latency", value: summary.duration("p95").map { "\(metricNumber($0)) ms" } ?? "Unavailable", icon: "waveform.path.ecg")
                    FeatureCard(title: "Failure rate", value: summary.failureRate.map { String(format: "%.1f%%", $0 * 100) } ?? "Unavailable", icon: "exclamationmark.triangle")
                    if let checks = summary.checks {
                        FeatureCard(title: "Checks", value: String(checks), icon: "checklist")
                    }
                    if let failures = summary.failures {
                        FeatureCard(title: "Failures", value: String(failures), icon: failures > 0 ? "xmark.octagon" : "checkmark.circle")
                    }
                    ForEach(Array(summary.durations.filter { $0.0 != "p95" }.enumerated()), id: \.offset) { _, duration in
                        FeatureCard(title: "Duration \(duration.0)", value: "\(metricNumber(duration.1)) ms", icon: "timer")
                    }
                }
                if summary.series.isEmpty {
                    NativeEmptyState(
                        title: isCollecting ? "Chart data is collecting" : "No chart data",
                        message: isCollecting ? "Charts appear as the runner records request, latency, or error samples." : "This run has aggregate measurements but no time-series samples."
                    )
                } else {
                    ForEach(summary.series) { series in
                        LoadTestMetricSeriesPanel(series: series)
                    }
                }
            } else {
                NativeEmptyState(
                    title: isCollecting ? "Metrics are collecting" : "No aggregate metrics",
                    message: isCollecting ? "Keep this result open while the runner reports measurements." : "The run did not return an aggregate summary. Logs and errors may still contain useful evidence."
                )
            }
        }
        .accessibilityIdentifier("load-test.summary.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

private struct LoadTestMetricSeriesPanel: View {
    @Environment(\.desktopTheme) private var theme
    @State private var samplePage = 0

    let series: DashboardLoadTestMetricSeries

    private let pageSize = 25

    private var pageCount: Int {
        max(1, Int(ceil(Double(series.points.count) / Double(pageSize))))
    }

    private var currentPage: Int {
        min(samplePage, pageCount - 1)
    }

    private var visiblePoints: [DashboardLoadTestMetricPoint] {
        Array(series.points.dropFirst(currentPage * pageSize).prefix(pageSize))
    }

    var body: some View {
        NativeGroupPanel(title: series.title, subtitle: "\(series.points.count) chronological samples · showing page \(currentPage + 1) of \(pageCount)") {
            Chart {
                ForEach(Array(series.points.enumerated()), id: \.offset) { index, point in
                    ForEach(series.metricKeys, id: \.self) { key in
                        if let value = point.values[key] {
                            if series.name == "errors" {
                                BarMark(x: .value("Sample", index), y: .value(series.metricLabel(for: key), value))
                                    .foregroundStyle(by: .value("Metric", series.metricLabel(for: key)))
                            } else {
                                LineMark(x: .value("Sample", index), y: .value(series.metricLabel(for: key), value))
                                    .interpolationMethod(.monotone)
                                    .foregroundStyle(by: .value("Metric", series.metricLabel(for: key)))
                            }
                        }
                    }
                }
            }
            .chartLegend(position: .bottom, alignment: .leading)
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine()
                    AxisValueLabel()
                }
            }
            .frame(height: 170)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(series.title) chart, \(series.points.count) chronological samples. Sample values are listed below.")

            if let first = series.points.first?.time, let last = series.points.last?.time {
                Text("\(first)  →  \(last)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.textTertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            LazyVStack(alignment: .leading, spacing: 4) {
                ForEach(visiblePoints) { point in
                    let values = series.metricKeys.compactMap { key in
                        point.values[key].map { "\(series.metricLabel(for: key)): \(metricNumber($0))" }
                    }.joined(separator: " · ")
                    Text("\(point.time) · \(values)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(theme.textSecondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("\(point.time), \(values)")
                }
            }

            if pageCount > 1 {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        pageButtons
                        Spacer(minLength: 4)
                        Text("Samples \(currentPage * pageSize + 1)–\(min((currentPage + 1) * pageSize, series.points.count)) of \(series.points.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        pageButtons
                        Text("Samples \(currentPage * pageSize + 1)–\(min((currentPage + 1) * pageSize, series.points.count)) of \(series.points.count)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(theme.textTertiary)
                    }
                }
            }
        }
        .onChange(of: series.points) { _, _ in samplePage = 0 }
    }

    private var pageButtons: some View {
        HStack(spacing: 8) {
            ActionButton(title: "Previous samples", icon: "chevron.left") { samplePage = max(0, currentPage - 1) }
                .disabled(currentPage == 0)
            ActionButton(title: "Next samples", icon: "chevron.right") { samplePage = min(pageCount - 1, currentPage + 1) }
                .disabled(currentPage + 1 >= pageCount)
        }
    }
}

private func metricNumber(_ value: Double) -> String {
    String(format: "%.0f", value)
}
