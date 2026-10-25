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
        NativeGroupPanel(title: "Test result", subtitle: "Test \(test.id)") {
            LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
                FeatureCard(title: "Status", value: test.statusLabel.capitalized, icon: statusIcon(test))
                FeatureCard(title: "Timeout", value: test.timeout.map { "\($0)s" } ?? "Default", icon: "timer")
                FeatureCard(title: "Requests", value: test.requestCount.map(String.init) ?? "Unknown", icon: "arrow.left.arrow.right")
                FeatureCard(title: "p95", value: test.p95Milliseconds.map { "\(Int($0.rounded())) ms" } ?? "Collecting", icon: "waveform.path.ecg")
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
            if let summary = test.activeSummary {
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
            if let errors = test.errors, !errors.isEmpty {
                NativeNotice(message: errors.prefix(4).joined(separator: "\n"), title: "Test errors")
            }
            if let logs = test.logs, !logs.isEmpty {
                NativeGroupPanel(title: "Recent output", subtitle: "Most recent saved lines") {
                    ForEach(Array(logs.suffix(8).enumerated()), id: \.offset) { _, line in
                        Text(line)
                            .font(.system(size: 10, weight: .medium, design: .monospaced))
                            .foregroundStyle(theme.textSecondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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

    var statuses: [String] {
        ["all"] + Array(Set(((selectedLane == .mine ? myTests : recentTests) ?? []).map { $0.statusLabel.lowercased() })).sorted()
    }

    func statusIcon(_ test: DashboardRecentTest) -> String {
        switch test.statusLabel.lowercased() {
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
