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

extension DesktopAgentModel {

    func openNativeDashboard(path: String, label: String, detailID: String? = nil, query: [String: String] = [:]) {
        selectedDashboardPath = path
        selectedDashboardTitle = label
        selectedNativeDashboardDetailID = detailID ?? ""
        selectedNativeDashboardQuery = query
        if path != "/cases" && path != "/cases/intelligence" { nativeCaseHandoffContext = nil }
        selectedSection = .dashboard
        append(meta: "Dashboard", body: "Opened native \(label)", kind: .command)
        recordRun(title: label, detail: path, kind: .command)
        Task { await loadNativeDashboardData() }
    }

    func closeNativeDashboardPage() {
        selectedDashboardPath = nil
        selectedDashboardTitle = "Dashboard"
        nativeDashboardPayload = "Select a dashboard card to load native data."
        nativeDashboardStatus = "Ready"
        backupServices = []
        backupFiles = []
        notes = []
        selectedNoteID = ""
        noteDraftTitle = ""
        noteDraftContent = ""
        vulnerabilityReport = nil
        databaseOverview = nil
        trafficMetrics = nil
    }

    @discardableResult
    func openNativeHanasandRoute(_ route: BrowserNativeRoute) -> Bool {
        var query = route.query
        if let section = route.section { query["section"] = section }
        nativeCaseHandoffContext = route.path == "/cases" || route.path == "/cases/intelligence" ? route.caseContext : nil
        if route.path == "/cases" || route.path == "/cases/intelligence" {
            let requestedOrganizationID = route.caseContext?.organizationID
                ?? query["org"] ?? query["organizationId"] ?? query["orgId"]
            if let requestedOrganizationID, !requestedOrganizationID.isEmpty {
                nativeCaseHandoffContext = BrowserCaseHandoffContext(
                    organizationID: requestedOrganizationID,
                    alertID: route.caseContext?.alertID,
                    route: route.caseContext?.route
                )
            }
        }
        if let detailID = route.detailID {
            switch route.path {
            case "/s": selectedShareID = detailID
            case "/content/articles": selectedArticleID = detailID
            case "/content/thoughts": selectedThoughtID = detailID
            case "/users": selectedUserID = detailID; selectedUserProfileID = detailID; selectedUserProfile = nil
            case "/g":
                linkDraftID = detailID
                linkLookupID = detailID
            default: break
            }
        }
        if route.path == "/mail" {
            selectedSection = .mail
        } else if route.path == "/browser" {
            selectedSection = .browser
        } else if route.path == "/ai" {
            openNativeDashboard(path: "/ai/workspace", label: route.label, detailID: route.detailID, query: query)
        } else if route.path == "/profile" {
            if let requestedUserID = route.detailID, requestedUserID != userIDForRequests {
                openNativeDashboard(path: "/public-profile", label: route.label, detailID: requestedUserID)
            } else {
                openNativeDashboard(path: "/profile", label: route.label, detailID: route.section, query: query)
            }
        } else {
            openNativeDashboard(path: route.path, label: route.label, detailID: route.detailID, query: query)
            if route.path == "/g", route.detailID != nil {
                Task {
                    guard let link = await lookupShortcutLink(),
                          let destination = shortcutDestinationURL(link.path) else { return }
                    if destination.host?.lowercased() == "hanasand.com",
                       destination.path == "/g" || destination.path.hasPrefix("/g/") {
                        nativeDashboardStatus = "This shortcut points to another shortcut. Open its destination from the Links panel."
                        return
                    }
                    openURL(destination.absoluteString, label: "Shortcut destination")
                }
            }
        }
        return true
    }

    private func shortcutDestinationURL(_ rawPath: String) -> URL? {
        let value = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        let candidate: URL?
        if value.hasPrefix("/") {
            candidate = URL(string: value, relativeTo: settings.websiteBaseURL.normalizedBaseURL)?.absoluteURL
        } else if let parsed = URL(string: value), parsed.scheme != nil {
            candidate = parsed
        } else {
            candidate = URL(string: "https://\(value)")
        }
        guard let candidate,
              ["http", "https"].contains(candidate.scheme?.lowercased() ?? ""),
              candidate.host != nil, candidate.user == nil, candidate.password == nil else { return nil }
        return candidate
    }

    func openURL(_ rawValue: String, label: String) {
        guard let url = URL(string: rawValue) else {
            append(meta: label, body: "Invalid URL: \(rawValue)", kind: .error)
            return
        }
        if BrowserWorkspaceModel.isHanasandOwnedURL(rawValue, configuredWebsiteBaseURL: settings.websiteBaseURL) {
            guard let route = BrowserWorkspaceModel.nativeRoute(for: rawValue, configuredWebsiteBaseURL: settings.websiteBaseURL) else {
                append(meta: label, body: "This Hanasand page does not have a native Desktop route yet.", kind: .note)
                return
            }
            _ = openNativeHanasandRoute(BrowserNativeRoute(
                path: route.path,
                label: route.label.isEmpty ? label : route.label,
                detailID: route.detailID,
                caseContext: route.caseContext,
                section: route.section,
                query: route.query
            ))
            return
        }
        NSWorkspace.shared.open(url)
        append(meta: "Opened \(label)", body: url.absoluteString, kind: .command)
    }

    func copyCurrentContext() {
        let context = currentShareContext()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(context, forType: .string)
        append(meta: "Copied", body: context, kind: .command)
        recordRun(title: "Copied context", detail: context, kind: .command)
    }

    func shareCurrentContext() {
        let context = currentShareContext()
        guard let window = NSApplication.shared.keyWindow,
              let contentView = window.contentView else {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(context, forType: .string)
            append(meta: "Share", body: "Copied context because no window was available.", kind: .note)
            return
        }

        let picker = NSSharingServicePicker(items: [context])
        picker.show(relativeTo: contentView.bounds, of: contentView, preferredEdge: .minY)
        append(meta: "Share", body: context, kind: .command)
    }

    func currentShareContext() -> String {
        switch selectedSection {
        case .control:
            return prompt.isEmpty ? "Hanasand Control: \(currentTaskState)" : prompt
        case .mail:
            return selectedMailMessage?.subject ?? mailSummary
        case .documents:
            return "Hanasand Documents: \(documentPages.count) page\(documentPages.count == 1 ? "" : "s")"
        case .images:
            return "Hanasand Images: \(imageReviewItems.count) image\(imageReviewItems.count == 1 ? "" : "s"), \(imageReviewDecisions.count) decided"
        case .dashboard:
            return "\(selectedDashboardTitle): \(selectedDashboardPath ?? "dashboard")"
        case .server:
            return "Hanasand Server: \(serverSummary)"
        case .mac:
            return "\(status.hostname) \(status.platform) \(status.cwd)"
        case .command:
            return "Hanasand AI: \(aiSummary)"
        case .updates:
            return "Hanasand Desktop \(Self.appVersion): \(updateStatus.title) \(updateStatus.message)"
        default:
            return "Hanasand \(selectedSection.title)"
        }
    }

    func importFileProviders(_ providers: [NSItemProvider], completion: @escaping @MainActor ([URL]) -> Void) {
        var urls: [URL] = []
        let group = DispatchGroup()

        for provider in providers {
            group.enter()
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                defer { group.leave() }
                if let url = item as? URL {
                    urls.append(url)
                } else if let data = item as? Data,
                          let value = String(data: data, encoding: .utf8),
                          let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    urls.append(url)
                } else if let value = item as? String,
                          let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    urls.append(url)
                }
            }
        }

        group.notify(queue: .main) {
            Task { @MainActor in
                completion(urls)
            }
        }
    }

    func openServerLogsPage() {
        selectedSection = .server
        append(meta: "Server logs", body: "Loading logs in the native Server workspace.", kind: .command)
        Task { await checkServerLogs() }
    }

    func configureMacMiniRemoteDesktop() {
        settings.vncHost = "localhost:5900"
        settings.rdpUser = "macmini"
        settings.remoteDesktopProtocol = RemoteDesktopProtocol.screenSharing.rawValue
        settings.remoteDesktopTunnelCommand = HanasandDesktopSettings.macMiniTunnelCommand
        remoteControlSummary = "Mac mini Screen Sharing profile is ready."
        remoteControlLastCommand = "Mac mini profile"
        append(meta: "Remote desktop", body: "Mac mini profile ready. Start the tunnel, then connect.", kind: .change)
    }

    func activateForRemoteControl() {
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.windows.first?.makeKeyAndOrderFront(nil)
    }

    func markRemoteDesktopCommand(_ title: String, detail: String, kind: AgentEvent.Kind = .command) {
        remoteControlRequests += 1
        remoteControlLastCommand = title
        remoteControlSummary = detail
        append(meta: "Remote desktop", body: detail, kind: kind)
        recordRun(title: title, detail: detail, kind: kind)
    }

    func showRemoteDesktopStatus(source: String = "Hanasand app") {
        selectedSection = .server
        activateForRemoteControl()
        markRemoteDesktopCommand(
            "Status from \(source)",
            detail: "\(remoteDesktopProtocolLabel) ready for \(remoteDesktopTargetSummary).",
            kind: .command
        )
        currentTaskState = "Remote status shown"
    }
}
