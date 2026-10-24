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

extension BrowserWorkspace {

    func browserStatusBar(_ browser: BrowserTabState) -> some View {
        HStack(spacing: 8) {
            Image(systemName: browser.webView.url?.scheme == "https" ? "lock.fill" : "globe")
                .font(.system(size: 11, weight: .bold))
            Text(browser.title)
                .lineLimit(1)
            browserUsageSummary
            Spacer()
            Text(browser.statusText)
                .lineLimit(1)
        }
        .font(.system(size: 12, weight: .semibold))
        .foregroundStyle(theme.textTertiary)
        .padding(.horizontal, 18)
        .frame(height: 28)
        .background(theme.commandBar.opacity(0.72))
        .task(id: browserUsageCredentialKey) { await pollBrowserUsage() }
    }

    private var browserUsageSummary: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                browserAccountUsageSummary
                Rectangle().fill(theme.divider).frame(width: 1, height: 14)
                browserGlobalStatsSummary
            }
            HStack(spacing: 6) {
                browserAccountUsageCompactSummary
                Text("·").foregroundStyle(theme.textTertiary)
                browserGlobalStatsCompactSummary
            }
            HStack(spacing: 5) {
                browserAccountUsageMinimalSummary
                Text("·").foregroundStyle(theme.textTertiary)
                browserGlobalStatsMinimalSummary
            }
        }
    }

    @ViewBuilder
    private var browserAccountUsageSummary: some View {
        switch browserUsageState {
        case .loading:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Account usage…")
            }
            .accessibilityLabel("Loading account Browser usage")
        case .ready(let usage):
            Label("Account: \(usage.runsToday) today · \(usage.activeRuns) active", systemImage: "chart.bar")
            .help("Authenticated account usage for the current day and active runs")
            .accessibilityIdentifier("browser-account-usage")
        case .signedOut:
            Text("Account: sign in")
                .accessibilityIdentifier("browser-account-usage-signed-out")
        case .unavailable(let message):
            HStack(spacing: 5) {
                Text("Account: unavailable")
                Button {
                    Task { await refreshBrowserUsage() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(message)
                .accessibilityLabel("Retry Browser usage")
            }
            .accessibilityIdentifier("browser-account-usage-unavailable")
        }
    }

    @ViewBuilder
    private var browserAccountUsageCompactSummary: some View {
        if case .ready(let usage) = browserUsageState {
            Text("Acct \(usage.runsToday) today · \(usage.activeRuns) active")
                .help("Authenticated account usage for the current day and active runs")
                .accessibilityIdentifier("browser-account-usage-compact")
        } else {
            browserAccountUsageSummary
        }
    }

    @ViewBuilder
    private var browserAccountUsageMinimalSummary: some View {
        if case .ready(let usage) = browserUsageState {
            Text("Acct \(usage.runsToday)/\(usage.activeRuns)")
                .help("Authenticated account runs today / active runs")
                .accessibilityIdentifier("browser-account-usage-minimal")
        } else {
            browserAccountUsageSummary
        }
    }

    @ViewBuilder
    private var browserGlobalStatsSummary: some View {
        switch browserGlobalStatsState {
        case .loading:
            HStack(spacing: 5) {
                ProgressView().controlSize(.mini)
                Text("Aggregate 24h…")
            }
            .accessibilityLabel("Loading aggregate Browser statistics")
        case .ready(let stats):
            Label("All 24h: \(stats.runs24h) · Darkweb \(stats.darkwebRuns24h)", systemImage: "globe.americas")
                .help("Public aggregate Browser runs in the last 24 hours; no account or target details")
                .accessibilityIdentifier("browser-global-stats")
        case .unavailable(let message):
            HStack(spacing: 5) {
                Text("All 24h: unavailable")
                Button {
                    Task { await refreshBrowserGlobalStats() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .help(message)
                .accessibilityLabel("Retry aggregate Browser statistics")
            }
            .accessibilityIdentifier("browser-global-stats-unavailable")
        }
    }

    @ViewBuilder
    private var browserGlobalStatsCompactSummary: some View {
        if case .ready(let stats) = browserGlobalStatsState {
            Text("All 24h \(stats.runs24h) · Darkweb \(stats.darkwebRuns24h)")
                .help("Public aggregate Browser runs in the last 24 hours; no account or target details")
                .accessibilityIdentifier("browser-global-stats-compact")
        } else {
            browserGlobalStatsSummary
        }
    }

    @ViewBuilder
    private var browserGlobalStatsMinimalSummary: some View {
        if case .ready(let stats) = browserGlobalStatsState {
            Text("All \(stats.runs24h)/\(stats.darkwebRuns24h)")
                .help("Aggregate runs / darkweb runs in the last 24 hours")
                .accessibilityIdentifier("browser-global-stats-minimal")
        } else {
            browserGlobalStatsSummary
        }
    }

    @MainActor
    private func pollBrowserUsage() async {
        while !Task.isCancelled {
            await refreshBrowserUsage()
            await refreshBrowserGlobalStats()
            do {
                try await Task.sleep(nanoseconds: 30_000_000_000)
            } catch {
                return
            }
        }
    }

    @MainActor
    private func refreshBrowserGlobalStats() async {
        do {
            let stats = try await BrowserUsageClient.loadGlobalStats()
            guard !Task.isCancelled else { return }
            browserGlobalStatsState = .ready(stats)
        } catch {
            guard !Task.isCancelled else { return }
            browserGlobalStatsState = .unavailable(error.localizedDescription)
        }
    }

    @MainActor
    private func refreshBrowserUsage() async {
        guard model.hasHanasandAuth else {
            browserUsageState = .signedOut
            return
        }
        guard model.settings.impersonationToken.isEmpty && model.settings.impersonatingUserID.isEmpty else {
            browserUsageState = .unavailable("Account usage is hidden while impersonating another user.")
            return
        }
        do {
            let client = try BrowserUsageClient(
                userID: model.userIDForRequests,
                token: model.authTokenForRequests
            )
            let usage = try await client.load()
            guard !Task.isCancelled else { return }
            browserUsageState = .ready(usage)
        } catch {
            guard !Task.isCancelled else { return }
            browserUsageState = .unavailable(error.localizedDescription)
        }
    }
}
