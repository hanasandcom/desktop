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

struct BrowserNativeRoute: Equatable {
    let path: String
    let label: String
    let detailID: String?
    let caseContext: BrowserCaseHandoffContext?
}

struct BrowserCaseHandoffContext: Equatable {
    let organizationID: String?
    let alertID: String?
    let route: String?
}

final class BrowserWorkspaceModel: ObservableObject {
    @Published var groups: [BrowserTabGroup] = []
    @Published var selectedGroupID = "operations"
    @Published var selectedTabID: UUID?
    var onOpenNativeRoute: ((BrowserNativeRoute) -> Bool)?
    private var configuredWebsiteBaseURL: String?

    static func isHanasandOwnedURL(_ rawValue: String, configuredWebsiteBaseURL: String? = nil) -> Bool {
        guard let url = URL(string: rawValue),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host?.lowercased() else { return false }
        if host == "hanasand.com" || host.hasSuffix(".hanasand.com") { return true }
        guard let configuredWebsiteBaseURL,
              let configured = URL(string: configuredWebsiteBaseURL),
              let configuredHost = configured.host?.lowercased() else { return false }
        return url.scheme?.lowercased() == configured.scheme?.lowercased()
            && host == configuredHost
            && effectivePort(for: url) == effectivePort(for: configured)
    }

    private static func effectivePort(for url: URL) -> Int? {
        if let port = url.port { return port }
        switch url.scheme?.lowercased() {
        case "http": return 80
        case "https": return 443
        default: return nil
        }
    }

    static func nativeRoute(for rawValue: String, configuredWebsiteBaseURL: String? = nil) -> BrowserNativeRoute? {
        guard isHanasandOwnedURL(rawValue, configuredWebsiteBaseURL: configuredWebsiteBaseURL), let url = URL(string: rawValue) else { return nil }
        if let encodedPath = URLComponents(url: url, resolvingAgainstBaseURL: false)?.percentEncodedPath {
            for segment in encodedPath.split(separator: "/") {
                guard let decodedSegment = String(segment).removingPercentEncoding else { return nil }
                if decodedSegment == "." || decodedSegment == ".." || decodedSegment.contains("/") || decodedSegment.contains("\\") {
                    return nil
                }
            }
        }
        let host = url.host?.lowercased() ?? ""
        var path = url.path.isEmpty ? "/" : url.path
        var detailID: String?
        var caseContext: BrowserCaseHandoffContext?
        switch host {
        case "cdn.hanasand.com": path = "/cdn"
        case "identity.hanasand.com": path = "/identity"
        case "internal.hanasand.com": path = "/internal"
        case "mail.hanasand.com": path = "/mail"
        case "status.hanasand.com": path = "/status"
        case "support.hanasand.com": path = "/support"
        case "scanner.hanasand.com": path = "/scanner"
        case "pwned.hanasand.com": path = "/pwned"
        case "thesis.hanasand.com": path = "/thesis"
        case "api.hanasand.com":
            if path == "/" || path == "/api" { path = "/api" }
        default: break
        }
        if host == "ti.hanasand.com", path.hasPrefix("/dashboard") {
            path = String(path.dropFirst("/dashboard".count))
            if path.isEmpty { path = "/" }
        }
        if host == "ti.hanasand.com", path == "/" { path = "/ti" }
        if path == "/" { path = "/dashboard" }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        let websiteAliases: [String: String] = [
            "/ai": "/ai",
            "/dashboard/ai": "/ai",
            "/ai/window": "/ai",
            "/dashboard/articles/create": "/content/articles",
            "/dashboard/thought/create": "/content/thoughts",
            "/dashboard/thoughts/create": "/content/thoughts",
            "/api/openapi": "/api/openapi",
            "/article": "/content/articles",
            "/articles": "/content/articles",
            "/dashboard/api-docs": "/api",
            "/dashboard/article": "/content/articles",
            "/dashboard/articles": "/content/articles",
            "/dashboard/automation/cron": "/automation/cron",
            "/dashboard/automation/health": "/automation/health",
            "/dashboard/automation/monitoring": "/automation/health",
            "/dashboard/backup": "/db/backups",
            "/dashboard/cases": "/cases",
            "/dashboard/db": "/db",
            "/dashboard/db/backups": "/db/backups",
            "/dashboard/db/restore": "/db/restore",
            "/dashboard/findings": "/findings",
            "/dashboard/findings/actions": "/dashboard/delivery-history",
            "/dashboard/findings/actors": "/ti/profiles",
            "/dashboard/findings/alerts": "/findings",
            "/dashboard/findings/cases": "/cases",
            "/dashboard/findings/delivery": "/dashboard/delivery-history",
            "/dashboard/findings/sources": "/ti/sources",
            "/dashboard/findings/watchlists": "/watchlists",
            "/dashboard/load-testing": "/load-testing",
            "/dashboard/logs": "/logs",
            "/dashboard/logs/errors": "/logs/errors",
            "/dashboard/logs/realtime": "/logs/realtime",
            "/dashboard/logs/search": "/logs/search",
            "/dashboard/mail": "/mail",
            "/dashboard/management": "/management",
            "/dashboard/management/organizations": "/organizations",
            "/dashboard/management/service-accounts": "/dashboard/management/service-accounts",
            "/dashboard/management/users": "/users",
            "/dashboard/notes": "/notes",
            "/dashboard/overview": "/dashboard",
            "/dashboard/projects": "/repositories",
            "/dashboard/repositories": "/repositories",
            "/dashboard/rules": "/rules/match",
            "/dashboard/rules/analysis": "/rules/analysis",
            "/dashboard/rules/detection": "/rules/detection",
            "/dashboard/rules/match": "/rules/match",
            "/dashboard/rules/tuning": "/rules/tuning",
            "/dashboard/scanner": "/scanner",
            "/dashboard/shares": "/s",
            "/dashboard/subscription": "/subscription",
            "/dashboard/system": "/system",
            "/dashboard/system/ai": "/system/ai",
            "/dashboard/system/console": "/system/hosts",
            "/dashboard/system/hosts": "/system/hosts",
            "/dashboard/system/ssh-keys": "/profile",
            "/dashboard/system/rates": "/system/rates",
            "/dashboard/system/updates": "/system/updates",
            "/dashboard/thesis": "/thesis",
            "/dashboard/thought": "/content/thoughts",
            "/dashboard/thoughts": "/content/thoughts",
            "/dashboard/ti": "/ti",
            "/dashboard/ti/activity": "/ti/runs",
            "/dashboard/ti/control": "/ti",
            "/dashboard/ti/enrichment": "/ti",
            "/dashboard/ti/evaluation": "/ti",
            "/dashboard/ti/runs": "/ti/runs",
            "/dashboard/ti/sources": "/ti/sources",
            "/dashboard/ti/timeliness": "/ti/timeliness",
            "/dashboard/ti/workbench": "/ti",
            "/dashboard/traffic": "/traffic",
            "/dashboard/traffic/blocklist": "/traffic/blocklist",
            "/dashboard/traffic/map": "/traffic/map",
            "/dashboard/traffic/recent": "/traffic/recent",
            "/dashboard/vm": "/vms",
            "/dashboard/vms": "/vms",
            "/dashboard/vulnerabilities": "/vulnerabilities",
            "/developers": "/api",
            "/g/stats": "/g",
            "/pricing": "/subscription",
            "/solutions/scanner": "/scanner",
            "/solutions/security-monitoring": "/watchlists",
            "/status/incidents": "/status",
            "/test/stats": "/test",
            "/thought": "/content/thoughts",
            "/thoughts": "/content/thoughts",
        ]
        path = websiteAliases[path] ?? path

        let parts = path.split(separator: "/").map(String.init)
        let queryItems = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func queryValue(_ key: String) -> String? { queryItems.first(where: { $0.name == key })?.value }

        if parts.count == 2 {
            switch parts[0] {
            case "test": path = "/test"; detailID = parts[1]
            case "cases": path = "/cases"; detailID = parts[1]
            case "s": path = "/s"; detailID = parts[1]
            case "g": path = "/g"; detailID = parts[1]
            case "profile", "user", "users": path = "/users"; detailID = parts[1]
            case "articles", "article": path = "/content/articles"; detailID = parts[1]
            case "thoughts", "thought": path = "/content/thoughts"; detailID = parts[1]
            case "ai": path = "/ai"; detailID = parts[1]
            case "ti":
                if path == "/ti/runs" || path == "/ti/captures" || path == "/ti/timeliness" || path == "/ti/sources" || path == "/ti/profiles" {
                    break
                }
                path = "/ti"; detailID = parts[1]
            case "status": path = "/status"; detailID = parts[1]
            default: break
            }
        } else if parts.count == 3, parts[0] == "dashboard" {
            switch parts[1] {
            case "cases": path = "/cases"; detailID = parts[2]
            case "articles", "article": path = "/content/articles"; detailID = parts[2]
            case "thoughts", "thought": path = "/content/thoughts"; detailID = parts[2]
            case "vms", "vm": path = "/vms"; detailID = parts[2]
            case "management": path = "/users"; detailID = parts[2]
            case "rules": path = "/rules/match"; detailID = parts[2]
            case "system":
                switch parts[2] {
                case "hosts": path = "/system/hosts"
                case "updates": path = "/system/updates"
                case "ai": path = "/system/ai"
                case "rates": path = "/system/rates"
                case "containers": path = "/system/containers"
                case "console": path = "/system/hosts"
                default: path = "/system"
                }
            default: break
            }
        } else if parts.count == 4, parts[0] == "dashboard" {
            if parts[1] == "findings", parts[2] == "cases" {
                path = "/cases"; detailID = parts[3]
            } else if parts[1] == "rules", ["match", "analysis", "detection"].contains(parts[2]) {
                path = "/rules/\(parts[2])"; detailID = parts[3]
            } else if parts[1] == "ti", parts[2] == "sources" {
                path = "/ti/sources"; detailID = parts[3]
            } else if ["vm", "vms"].contains(parts[1]), parts[3] == "console" {
                path = "/vms"; detailID = parts[2]
            }
        } else if parts.count == 3, parts[0] == "status", parts[1] == "incidents" {
            path = "/status"; detailID = parts[2]
        }

        if path == "/cases", detailID != nil {
            caseContext = BrowserCaseHandoffContext(
                organizationID: queryValue("organizationId"),
                alertID: queryValue("alertId"),
                route: queryValue("route")
            )
        }
        if let requestedDetailID = detailID {
            guard let decodedID = requestedDetailID.removingPercentEncoding,
                  NativeRouteSelection.resolve(decodedID, among: [decodedID]) != nil else { return nil }
            detailID = decodedID
        }
        // Unknown owned routes still enter the native dashboard container, where its
        // default panel explains that the requested route has no native feature yet.
        let label = path == "/dashboard" ? "Dashboard" : path.split(separator: "/").last.map { $0.replacingOccurrences(of: "-", with: " ").capitalized } ?? "Hanasand"
        return BrowserNativeRoute(path: path, label: label, detailID: detailID, caseContext: caseContext)
    }

    var selectedTab: BrowserTabState? {
        guard let group = selectedGroup else { return nil }
        return group.tabs.first { $0.id == selectedTabID } ?? group.tabs.first
    }

    var selectedGroup: BrowserTabGroup? {
        groups.first { $0.id == selectedGroupID } ?? groups.first
    }

    func configure(settings: HanasandDesktopSettings) {
        configuredWebsiteBaseURL = settings.websiteBaseURL
        guard groups.isEmpty else { return }
        let base = settings.websiteBaseURL.normalizedBaseURL
        let operations = BrowserTabGroup(
            id: "operations",
            title: "Operations",
            icon: "gauge.with.dots.needle",
            tabs: [
                BrowserTabState(label: "Search", url: "https://duckduckgo.com"),
            ],
            destinations: [
                BrowserDestination(title: "Dashboard", subtitle: "Overview", icon: "square.grid.2x2", url: base.appendingPathComponent("dashboard").absoluteString),
                BrowserDestination(title: "Logs", subtitle: "Runtime", icon: "doc.text.magnifyingglass", url: base.appendingPathComponent("logs").absoluteString),
                BrowserDestination(title: "Database", subtitle: "Storage", icon: "externaldrive.connected.to.line.below", url: base.appendingPathComponent("db").absoluteString),
                BrowserDestination(title: "VMs", subtitle: "Machines", icon: "display.2", url: base.appendingPathComponent("vms").absoluteString),
            ]
        )
        let communication = BrowserTabGroup(
            id: "communication",
            title: "Communication",
            icon: "bubble.left.and.bubble.right",
            tabs: [
                BrowserTabState(label: "Search", url: "https://duckduckgo.com"),
            ],
            destinations: [
                BrowserDestination(title: "Mail", subtitle: "Inbox", icon: "envelope", url: "https://mail.hanasand.com"),
                BrowserDestination(title: "Notes", subtitle: "Shared memory", icon: "note.text", url: base.appendingPathComponent("notes").absoluteString),
                BrowserDestination(title: "Articles", subtitle: "Writing", icon: "text.alignleft", url: base.appendingPathComponent("content/articles").absoluteString),
                BrowserDestination(title: "Thoughts", subtitle: "Ideas", icon: "brain.head.profile", url: base.appendingPathComponent("content/thoughts").absoluteString),
            ]
        )
        let research = BrowserTabGroup(
            id: "research",
            title: "Research",
            icon: "magnifyingglass.circle",
            tabs: [
                BrowserTabState(label: "Search", url: "https://duckduckgo.com"),
            ],
            destinations: [
                BrowserDestination(title: "Dashboard", subtitle: "Native overview", icon: "square.grid.2x2", url: base.appendingPathComponent("dashboard").absoluteString),
                BrowserDestination(title: "Sandbox", subtitle: "Isolated browser", icon: "shield.lefthalf.filled", url: base.appendingPathComponent("sandbox").absoluteString),
                BrowserDestination(title: "GitHub", subtitle: "Code", icon: "chevron.left.forwardslash.chevron.right", url: "https://github.com/eirikhanasand"),
                BrowserDestination(title: "DuckDuckGo", subtitle: "Search", icon: "magnifyingglass", url: "https://duckduckgo.com"),
            ]
        )

        groups = [operations, communication, research]
        selectedGroupID = operations.id
        selectedTabID = operations.tabs.first?.id
    }

    func selectGroup(_ id: String) {
        selectedGroupID = id
        selectedTabID = selectedGroup?.tabs.first?.id
    }

    func selectTab(_ id: UUID) {
        selectedTabID = id
    }

    func createGroup() {
        let nextNumber = groups.count + 1
        let tab = BrowserTabState(label: "New tab", url: "https://duckduckgo.com")
        let group = BrowserTabGroup(
            id: UUID().uuidString,
            title: "Group \(nextNumber)",
            icon: "rectangle.stack.badge.plus",
            tabs: [tab],
            destinations: [],
            isCustom: true
        )
        groups.append(group)
        selectedGroupID = group.id
        selectedTabID = tab.id
    }

    func removeSelectedGroup() {
        guard groups.count > 1,
              let removeIndex = groups.firstIndex(where: { $0.id == selectedGroupID }) else { return }
        let removedTabs = groups[removeIndex].tabs
        groups.remove(at: removeIndex)
        let targetIndex = groups.indices.first ?? 0
        groups[targetIndex].tabs.append(contentsOf: removedTabs)
        selectedGroupID = groups[targetIndex].id
        selectedTabID = groups[targetIndex].tabs.first?.id
    }

    func open(_ destination: BrowserDestination) {
        open(label: destination.title, url: destination.url)
    }

    func open(label: String = "New", url: String) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == selectedGroupID }) else { return }
        if Self.isHanasandOwnedURL(url, configuredWebsiteBaseURL: configuredWebsiteBaseURL) {
            if let route = Self.nativeRoute(for: url, configuredWebsiteBaseURL: configuredWebsiteBaseURL) {
                let didOpen = onOpenNativeRoute?(route) ?? false
                selectedTab?.statusText = didOpen ? "Opened in native Desktop" : "This Hanasand page does not have a native Desktop route yet."
            } else {
                selectedTab?.statusText = "This Hanasand page does not have a native Desktop route yet."
            }
            return
        }
        let tab = BrowserTabState(label: label, url: url)
        groups[groupIndex].tabs.append(tab)
        selectedTabID = tab.id
    }

    func open(_ request: BrowserOpenRequest) {
        if Self.isHanasandOwnedURL(request.url, configuredWebsiteBaseURL: configuredWebsiteBaseURL) {
            open(label: request.title, url: request.url)
            return
        }
        if let externalURL = BrowserTargetResolver.externalURL(from: request.url) {
            NSWorkspace.shared.open(externalURL)
            return
        }
        guard let url = URL(string: request.url),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              url.host != nil else {
            selectedTab?.statusText = "Only HTTP and HTTPS pages can open in the workspace."
            return
        }
        if let researchIndex = groups.firstIndex(where: { $0.id == "research" }) {
            selectedGroupID = groups[researchIndex].id
        }
        open(label: request.title, url: request.url)
    }

    func close(_ tab: BrowserTabState) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == selectedGroupID }) else { return }
        guard groups[groupIndex].tabs.count > 1 else { return }
        groups[groupIndex].tabs.removeAll { $0.id == tab.id }
        if selectedTabID == tab.id {
            selectedTabID = groups[groupIndex].tabs.last?.id
        }
    }

    func move(_ tab: BrowserTabState, to groupID: String) {
        guard groupID != selectedGroupID,
              let sourceIndex = groups.firstIndex(where: { $0.id == selectedGroupID }),
              let targetIndex = groups.firstIndex(where: { $0.id == groupID }),
              let tabIndex = groups[sourceIndex].tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        let moved = groups[sourceIndex].tabs.remove(at: tabIndex)
        groups[targetIndex].tabs.append(moved)
        selectedGroupID = groupID
        selectedTabID = moved.id
        if groups[sourceIndex].tabs.isEmpty {
            groups[sourceIndex].tabs.append(BrowserTabState(label: "New tab", url: "https://duckduckgo.com"))
        }
    }
}
