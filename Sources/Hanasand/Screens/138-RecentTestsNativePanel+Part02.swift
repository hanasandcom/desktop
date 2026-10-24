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
                FeatureCard(title: "Requests", value: displayedSummary?.numberValue(for: ["requests"]).map { String(Int($0)) } ?? "Unknown", icon: "arrow.left.arrow.right")
                FeatureCard(title: "p95", value: displayedSummary?.numberValue(for: ["duration", "p95"]).map { "\(Int($0.rounded())) ms" } ?? "Collecting", icon: "waveform.path.ecg")
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
            if let summary = displayedSummary {
                Text(summary.pretty)
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(theme.textSecondary)
                    .lineLimit(10)
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(theme.backgroundElevated.opacity(0.72))
                    .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
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
