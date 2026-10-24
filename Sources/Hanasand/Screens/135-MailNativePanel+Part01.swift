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

enum MailNativePanelLayout {
    static let stackedBreakpoint: CGFloat = 560
    static let originalColumnsBreakpoint: CGFloat = 660
    static let expandedColumnsBreakpoint: CGFloat = 1120
    static let horizontalChromeWidth: CGFloat = 34
    static let quickFilterMinimumColumnWidth: CGFloat = 160

    enum Mode: Equatable { case stacked, compact, expanded }

    static func mode(contentWidth: CGFloat) -> Mode {
        if contentWidth >= expandedColumnsBreakpoint { return .expanded }
        if contentWidth >= stackedBreakpoint { return .compact }
        return .stacked
    }

    static func compactSidebarWidth(contentWidth: CGFloat) -> CGFloat {
        min(238, max(170, contentWidth * 0.24))
    }

    static func compactPaneWidths(contentWidth: CGFloat) -> (mailboxes: CGFloat, messages: CGFloat, reader: CGFloat) {
        let paneWidth = max(0, contentWidth - horizontalChromeWidth)
        let mailboxes = min(238, max(120, paneWidth * 0.23))
        let messages = min(440, max(180, paneWidth * 0.34))
        return (mailboxes, messages, max(0, paneWidth - mailboxes - messages))
    }
}

extension MailNativePanel {

    var overview: MailOverviewEnvelope? { model.mailOverview }

    var selectedMessage: MailOverviewEnvelope.Message? { model.selectedMailMessage }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            headerBar

            if let overview {
                GeometryReader { geometry in
                    Group {
                        if MailNativePanelLayout.mode(contentWidth: geometry.size.width) == .expanded {
                            HStack(alignment: .top, spacing: 0) {
                                mailboxSidebar(overview)
                                    .frame(minWidth: 160, idealWidth: 200, maxWidth: 238)

                                Divider()
                                    .overlay(theme.divider)
                                    .padding(.horizontal, 10)

                                threadedMessageList(overview)
                                    .frame(minWidth: 220, idealWidth: 300, maxWidth: 440)

                                Divider()
                                    .overlay(theme.divider)
                                    .padding(.horizontal, 10)

                                messageReader(overview)
                                    .frame(minWidth: 240, maxWidth: .infinity)
                            }
                        } else if MailNativePanelLayout.mode(contentWidth: geometry.size.width) == .compact {
                            let sidebarWidth = MailNativePanelLayout.compactSidebarWidth(contentWidth: geometry.size.width)
                            HStack(alignment: .top, spacing: 8) {
                                mailboxSidebar(overview)
                                    .frame(width: sidebarWidth, alignment: .topLeading)

                                Divider()
                                    .overlay(theme.divider)
                                    .frame(width: 1)

                                VStack(alignment: .leading, spacing: 12) {
                                    threadedMessageList(overview)
                                        .frame(minHeight: 470, maxHeight: 600, alignment: .topLeading)
                                    messageReader(overview)
                                        .frame(minHeight: 360, alignment: .topLeading)
                                }
                                .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        } else {
                            VStack(alignment: .leading, spacing: 12) {
                                mailboxSidebar(overview)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                threadedMessageList(overview)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                                messageReader(overview)
                                    .frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(minHeight: 590)

                mailSyncBanner

                if model.mailComposerExpanded {
                    composeSheet(overview)
                }
        } else {
            NativeGroupPanel(title: "Connect Mail", subtitle: "Inbox, compose, accounts") {
                    HStack(spacing: 10) {
                        ActionButton(title: "Load inbox", icon: "tray.full") {
                            Task { await model.loadMailOverview() }
                        }
                        ActionButton(title: "Setup", icon: "gearshape") {
                            showAccountSetup.toggle()
                        }
                    }
                    NativeEmptyState(title: "No mailbox", message: "Add API settings, then Load inbox.")
                }
            }
        }
        .focusable()
        .onKeyPress(.downArrow) {
            Task { await model.selectNextMailMessage(offset: 1) }
            return .handled
        }
        .onKeyPress(.upArrow) {
            Task { await model.selectNextMailMessage(offset: -1) }
            return .handled
        }
        .task {
            if model.mailOverview == nil {
                await model.loadMailOverview()
            }
        }
        .task(id: "\(overview?.mailboxUser ?? "")|\(selectedMessage?.id ?? "")") {
            await loadSelectedMessageReputation()
        }
        .task(id: "\(searchText)|\(model.selectedMailboxID)") {
            let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else {
                model.resetMailSearch()
                return
            }
            model.resetMailSearch()
            model.mailSearchPending = true
            do {
                try await Task.sleep(nanoseconds: 250_000_000)
            } catch {
                return
            }
            await model.searchMail(query)
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                now = Date()
                guard model.mailAutoRefreshEnabled, model.mailOverview != nil else { continue }
                await model.loadMailOverview(silent: true)
            }
        }
    }

    var headerBar: some View {
        NativeGroupPanel(title: "Mail", subtitle: model.mailSummary) {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 125), spacing: 8)], alignment: .leading, spacing: 8) {
                Label("\(overview?.messages.count ?? 0) messages", systemImage: "envelope")
                Label("\(overview?.messages.filter { $0.isRead != true }.count ?? 0) unread", systemImage: "envelope.badge")
                Label("\(model.selectedMailMessageIDs.count) selected", systemImage: "checkmark.circle")
                Label(overview?.health?.status.capitalized ?? "Offline", systemImage: connectionIcon)
                    .foregroundStyle(overview?.health?.status.lowercased() == "healthy" ? theme.green : theme.textSecondary)
            }
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(theme.textSecondary)

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)], alignment: .leading, spacing: 8) {
                SearchFieldRow(placeholder: "Search mail", text: $searchText)
                    .focused($searchFocused)
                    .frame(minWidth: 132)
                ActionButton(title: "Refresh", icon: "arrow.clockwise") {
                    Task { await model.loadMailOverview() }
                }
                ActionButton(title: "Compose", icon: "square.and.pencil") {
                    guard !model.mailSendIsInFlight else { return }
                    if model.mailComposerExpanded {
                        model.mailComposerExpanded = false
                    } else {
                        model.beginNewMailDraft()
                        model.mailComposerExpanded = true
                    }
                }
                .disabled(model.mailSendIsInFlight)
                Button {
                    model.mailAutoRefreshEnabled.toggle()
                } label: {
                    Label(model.mailAutoRefreshEnabled ? "Live" : "Paused", systemImage: model.mailAutoRefreshEnabled ? "arrow.triangle.2.circlepath" : "pause.circle")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(model.mailAutoRefreshEnabled ? theme.green : theme.textSecondary)
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(theme.cardRaised)
                        .clipShape(Capsule())
                }
                .buttonStyle(.plain)
                ActionButton(title: "Setup", icon: "gearshape") {
                    showAccountSetup.toggle()
                }
            }

            if showAccountSetup {
                accountSetupPanel
            }
        }
    }

    @ViewBuilder

    var mailSyncBanner: some View {
        if let last = model.mailLastSuccessAt {
            let age = now.timeIntervalSince(last)
            if age > 300 || !model.mailBackgroundIssue.isEmpty {
                NativeGroupPanel(title: "Mail sync", subtitle: model.mailAutoRefreshEnabled ? "Background refresh" : "Paused") {
                    HStack(spacing: 10) {
                        Image(systemName: model.mailBackgroundIssue.isEmpty ? "clock.badge.exclamationmark" : "exclamationmark.triangle")
                            .foregroundStyle(model.mailBackgroundIssue.isEmpty ? theme.accent : theme.danger)
                        Text(model.mailBackgroundIssue.isEmpty ? "Last refreshed \(relativeAge(age)) ago." : "Background sync issue: \(model.mailBackgroundIssue)")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(theme.textSecondary)
                        Spacer()
                        ActionButton(title: "Refresh now", icon: "arrow.clockwise") {
                            Task { await model.loadMailOverview() }
                        }
                    }
                }
            }
        }
    }

    func relativeAge(_ seconds: TimeInterval) -> String {
        if seconds < 60 { return "\(max(0, Int(seconds)))s" }
        if seconds < 3600 { return "\(Int(seconds / 60))m" }
        return "\(Int(seconds / 3600))h"
    }

    var connectionIcon: String {
        switch overview?.health?.status.lowercased() {
        case "healthy": return "checkmark.icloud"
        case "warning": return "exclamationmark.icloud"
        case "error": return "xmark.icloud"
        default: return "icloud.slash"
        }
    }

    var mailToolbarActionColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 88), spacing: 8)]
    }

    func mailToolbarActionLabel(title: String, icon: String, tone: ActionTone = .normal) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 12, weight: .bold))
            .lineLimit(1)
            .minimumScaleFactor(0.86)
            .foregroundStyle(tone == .danger ? theme.danger : theme.text)
            .padding(.horizontal, 8)
            .frame(maxWidth: .infinity, minHeight: 34)
            .background(tone == .danger ? theme.danger.opacity(0.12) : theme.cardRaised)
            .overlay(
                Capsule()
                    .stroke(tone == .danger ? theme.danger.opacity(0.28) : theme.divider.opacity(0.8), lineWidth: 1)
            )
            .clipShape(Capsule())
    }

    func mailToolbarActionButton(
        title: String,
        icon: String,
        tone: ActionTone = .normal,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            mailToolbarActionLabel(title: title, icon: icon, tone: tone)
        }
        .buttonStyle(.plain)
    }
}
