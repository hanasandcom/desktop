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
    let section: String?
    let query: [String: String]
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
        var section: String?
        var caseContext: BrowserCaseHandoffContext?
        var allowsCompositeDetailID = false
        switch host {
        case "cdn.hanasand.com": if path == "/" { path = "/images/library" }
        case "identity.hanasand.com": if path == "/" { path = "/profile" }
        case "internal.hanasand.com": if path == "/" { path = "/system" }
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
        if path == "/", host != "hanasand.com" { path = "/dashboard" }
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }

        // Mirror first-party Next redirects before resolving route parameters.
        // These are old public links that still need to open their canonical
        // native feature without loading the website redirect chain.
        for prefix in ["/dwm", "/dashboard/dwm"] {
            if path == prefix {
                path = "/findings"
                break
            }
            if path.hasPrefix(prefix + "/cases/") {
                path = "/cases/" + String(path.dropFirst((prefix + "/cases/").count))
                break
            }
            if path == prefix + "/cases" {
                path = "/cases"
                break
            }
            if path.hasPrefix(prefix + "/") {
                path = "/findings/" + String(path.dropFirst((prefix + "/").count))
                break
            }
        }
        for prefix in ["/ti/domains", "/dashboard/ti/domains"] {
            if path == prefix {
                path = "/ti/sources"
                break
            }
            if path.hasPrefix(prefix + "/") {
                let sourceID = path.dropFirst((prefix + "/").count).split(separator: "/").first.map(String.init)
                path = "/ti/sources"
                detailID = sourceID
                break
            }
        }

        let websiteAliases: [String: String] = [
            "/prompt": "/ai",
            "/.well-known": "/security.txt",
            "/.well-known/security.txt": "/security.txt",
            "/security.txt": "/security.txt",
            "/vulnerabilities": "/scanner",
            "/automation": "/dashboard/automation",
            "/ai": "/ai",
            "/dashboard/ai": "/ai",
            "/ai/window": "/ai/workspace",
            "/dashboard/articles/create": "/content/articles",
            "/dashboard/thought/create": "/content/thoughts",
            "/dashboard/thoughts/create": "/content/thoughts",
            "/api/openapi": "/api/openapi",
            "/article": "/public-articles",
            "/articles": "/public-articles",
            "/findings/watchlists": "/watchlists",
            "/findings/alerts": "/cases",
            "/findings/cases": "/cases",
            "/findings/sources": "/ti/sources",
            "/api/openapi/ti": "/api/openapi",
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
            "/findings/actors": "/ti/profiles",
            "/findings/actions": "/integrations",
            "/findings/delivery": "/integrations",
            "/dashboard/findings/actions": "/integrations",
            "/dashboard/findings/actors": "/ti/profiles",
            "/dashboard/findings/alerts": "/cases",
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
            "/management/organizations": "/organizations",
            "/management/users": "/users",
            "/management/service-accounts": "/dashboard/management/service-accounts",
            "/dashboard/management/users": "/users",
            "/dashboard/notes": "/notes",
            "/dashboard/overview": "/dashboard",
            "/dashboard/projects": "/repositories",
            "/dashboard/repositories": "/repositories",
            "/dashboard/rules": "/rules/match",
            "/dashboard/rules/[id]": "/rules/detail",
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
            "/dashboard/system/containers": "/system/containers",
            "/dashboard/system/hosts": "/system/hosts",
            "/dashboard/system/ssh-keys": "/profile",
            "/system/virtual-machines": "/vms",
            "/organizations/privacy": "/organization-privacy",
            "/organizations/alerts": "/organizations/events",
            "/organizations/watchlists": "/watchlists",
            "/organizations/api-keys": "/organization-api-keys",
            "/dashboard/system/rates": "/system/rates",
            "/dashboard/system/updates": "/system/updates",
            "/dashboard/thesis": "/thesis",
            "/dashboard/thought": "/content/thoughts",
            "/dashboard/thoughts": "/content/thoughts",
            "/dashboard/ti": "/ti/overview",
            "/dashboard/ti/profiles": "/ti/enrichment",
            "/ti/profiles": "/ti/enrichment",
            "/dashboard/ti/activity": "/ti/activity",
            "/dashboard/ti/control": "/ti/runs",
            "/dashboard/ti/captures": "/ti/captures",
            "/dashboard/ti/enrichment": "/ti/enrichment",
            "/dashboard/ti/evaluation": "/dashboard",
            "/dashboard/ti/runs": "/ti/runs",
            "/dashboard/ti/sources": "/ti/sources",
            "/dashboard/ti/timeliness": "/ti/timeliness",
            "/dashboard/ti/workbench": "/ti/workbench",
            "/dashboard/traffic": "/traffic",
            "/dashboard/traffic/blocklist": "/traffic/blocklist",
            "/dashboard/traffic/map": "/traffic/map",
            "/dashboard/traffic/recent": "/traffic/recent",
            "/dashboard/vm": "/vms",
            "/dashboard/vms": "/vms",
            "/dashboard/vulnerabilities": "/scanner",
            "/gallery": "/images/library",
            "/gallery/albums": "/images/library",
            "/cdn": "/images/library",
            "/developers": "/developers",
            "/g/stats": "/g",
            "/solutions/dwm": "/findings",
            "/solutions/onion-session": "/browser",
            "/status/incidents": "/status",
            "/test/stats": "/test",
            "/thought": "/content/thoughts",
            "/thoughts": "/content/thoughts",
            "/user": "/users",
        ]
        let websiteGalleryAlbumsRoute = host == "hanasand.com" && path == "/gallery/albums"
        let websiteGalleryRoute = host == "hanasand.com" && (path == "/gallery" || websiteGalleryAlbumsRoute)
        path = websiteAliases[path] ?? path
        if websiteGalleryRoute {
            // Preserve the website Gallery's all-media behavior through the
            // shared native Images route. The section value is consumed by its
            // native panel and is not sent to the CDN as a filter.
            section = websiteGalleryAlbumsRoute ? "galleryAlbums" : "gallery"
        }

        let parts = path.split(separator: "/").map(String.init)
        let urlComponents = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let queryItems = urlComponents?.queryItems ?? []
        func queryValue(_ key: String) -> String? { queryItems.first(where: { $0.name == key })?.value }
        var routeQuery = Dictionary(queryItems.compactMap { item in item.value.map { (item.name, $0) } }, uniquingKeysWith: { first, _ in first })
        if let fragment = urlComponents?.fragment, !fragment.isEmpty,
           let fragmentComponents = URLComponents(string: "https://fragment.invalid/?\(fragment)") {
            for item in fragmentComponents.queryItems ?? [] where routeQuery[item.name] == nil {
                if let value = item.value { routeQuery[item.name] = value }
            }
        }

        // The findings landing page selects its native workspace from `panel`.
        // Resolve those links to the same dedicated panels used by the website
        // shortcuts so direct links keep their intended action context.
        if path == "/findings" {
            switch queryValue("panel")?.lowercased() {
            case "watchlists": path = "/watchlists"
            case "sources": path = "/ti/sources"
            case "delivery": path = "/integrations"
            case "actors": path = "/ti/profiles"
            case "actions": path = "/integrations"
            case "alerts": path = "/cases"
            default: break
            }
        }

        // The website keeps these views on the automations URL and selects them
        // from the query string. Resolve them to their dedicated native panels.
        if path == "/dashboard/automations" || path == "/dashboard/automation" {
            switch queryValue("view")?.lowercased() {
            case "health", "checks": path = "/automation/health"
            case "cron", "jobs": path = "/automation/cron"
            default: break
            }
        }

        if parts.count > 2, parts[0] == "management" {
            switch parts[1] {
            case "users":
                path = "/users"
                if parts.count > 2 { detailID = parts.dropFirst(2).joined(separator: "/") }
            case "organizations": path = "/organizations"
            case "service-accounts": path = "/dashboard/management/service-accounts"
            default: path = "/management"
            }
        } else if parts.count > 2, parts[0] == "dashboard", parts[1] == "management" {
            switch parts[2] {
            case "users":
                path = "/users"
                if parts.count > 3 { detailID = parts.dropFirst(3).joined(separator: "/") }
            case "organizations": path = "/organizations"
            case "service-accounts": path = "/dashboard/management/service-accounts"
            default:
                // The website catch-all `/dashboard/management/[...id]` treats
                // the first segment as a VM name, even when more path segments
                // follow it.
                path = "/vms"
                detailID = parts[2]
            }
        } else if path == "/sandbox/_browser/browser" { path = "/sandbox" }
        if path == "/sandbox/report" || path == "/_browser/browser/report" || path == "/sandbox/_browser/browser/report" {
            path = queryValue("run")?.isEmpty == false ? "/sandbox/report" : "/sandbox"
            detailID = queryValue("run")
        } else if path == "/ai/workspace" {
            path = "/ai/workspace"
        } else if path == "/test/stats" || path == "/g/stats" {
            path = path == "/test/stats" ? "/test" : "/g"
        } else if parts.count == 2 {
            switch parts[0] {
            case "test": path = "/test"; detailID = parts[1]
            case "sandbox": path = "/sandbox/result"; detailID = parts[1]
            case "cases": path = "/cases"; detailID = parts[1]
            case "articles", "article": path = "/public-article"; detailID = parts[1]
            case "thoughts", "thought": path = "/content/thoughts"; detailID = parts[1]
            case "s", "p", "project":
                path = "/s"
                detailID = parts[1]
                if parts[0] == "p" || parts[0] == "project" { routeQuery["workspace"] = "project" }
            case "g": path = "/g"; detailID = parts[1]
            case "profile": path = "/profile"; detailID = parts[1]
            case "user": path = "/profile"; detailID = parts[1]
            case "users": path = "/profile"; detailID = parts[1]
            case "ai": path = "/ai"; detailID = parts[1]
            case "ti":
                if ["/ti/overview", "/ti/runs", "/ti/captures", "/ti/timeliness", "/ti/sources", "/ti/profiles", "/ti/enrichment", "/ti/activity", "/ti/workbench"].contains(path) {
                    break
                }
                path = "/ti"; detailID = parts[1]
            case "status": path = "/status"; detailID = parts[1]
            case "files": path = "/cdn/files"; detailID = parts[1]
            case "shared": path = "/shared/album"; detailID = parts[1]
            case "vms": path = "/vms"; detailID = parts[1]
            default: break
            }
        } else if parts.count == 3, parts[0] == "api", parts[1] == "files" {
            path = "/cdn/files"; detailID = parts[2]
        } else if parts.count == 3, parts[0] == "profile" {
            if ["profile", "security", "sessions", "certificates", "ssh-keys", "support"].contains(parts[2]) {
                let profileSection = parts[2] == "certificates" ? "ssh-keys" : parts[2]
                path = profileSection == "support" ? "/support" : "/profile"
                detailID = profileSection == "support" ? nil : parts[1]
                section = profileSection == "support" ? nil : profileSection
            }
        } else if parts.count == 3, parts[0] == "ti", ["sources", "profiles", "runs", "captures"].contains(parts[1]) {
            path = "/ti/\(parts[1])"; detailID = parts[2]
        } else if parts.count == 4, parts[0] == "sandbox", parts[1] == "_browser", parts[2] == "browser" {
            path = "/sandbox/result"; detailID = parts[3]
        } else if parts.count > 2, ["article", "articles", "thought", "thoughts", "test", "user", "users"].contains(parts[0]) {
            switch parts[0] {
            case "article", "articles": path = "/public-article"
            case "thought", "thoughts": path = "/content/thoughts"
            case "test": path = "/test"
            case "user", "users": path = "/profile"
            default: path = "/users"
            }
            detailID = parts[1]
        } else if parts.count > 3, parts[0] == "dashboard", ["article", "articles", "thought", "thoughts"].contains(parts[1]) {
            path = parts[1] == "article" || parts[1] == "articles" ? "/content/articles" : "/content/thoughts"
            detailID = parts[2]
        } else if parts.count > 3, parts[0] == "dashboard", ["vm", "vms"].contains(parts[1]) {
            if ["vm", "vms"].contains(parts[1]), parts[3] == "console" {
                path = "/vms/console"; detailID = parts[2]
            } else {
                path = "/vms"; detailID = parts.dropFirst(2).joined(separator: "/")
                allowsCompositeDetailID = true
            }
        } else if parts.count > 3, parts[0] == "dashboard", parts[1] == "system" {
            path = "/vms"; detailID = parts.dropFirst(2).joined(separator: "/")
        } else if parts.count > 2, ["s", "p", "project"].contains(parts[0]) {
            path = "/s"
            detailID = parts[1]
            section = parts.dropFirst(2).joined(separator: "/")
            if parts[0] == "p" || parts[0] == "project" { routeQuery["workspace"] = "project" }
        } else if parts.count > 2, parts[0] == "g" {
            path = "/g"; detailID = parts[1]
        } else if parts.count == 2, parts[0] == "sandbox" {
            path = "/sandbox"; detailID = parts[1]
        } else if parts.count == 3, parts[0] == "vms", parts[2] == "console" {
            path = "/vms/console"; detailID = parts[1]
        } else if parts.count == 3, parts[0] == "dashboard" {
            switch parts[1] {
            case "cases": path = "/cases"; detailID = parts[2]
            case "articles", "article": path = "/content/articles"; detailID = parts[2]
            case "thoughts", "thought": path = "/content/thoughts"; detailID = parts[2]
            case "vms", "vm": path = "/vms"; detailID = parts[2]
            case "management":
                if parts[2] == "service-accounts" { path = "/dashboard/management/service-accounts" }
                else { path = "/vms"; detailID = parts[2] }
            case "rules": path = "/rules/detail"; detailID = parts[2]
            case "system":
                switch parts[2] {
                case "hosts": path = "/system/hosts"
                case "updates": path = "/system/updates"
                case "ai": path = "/system/ai"
                case "rates": path = "/system/rates"
                case "containers": path = "/system/containers"
                case "virtual-machines": path = "/vms"
                case "console": path = "/system/hosts"
                default: path = "/vms"; detailID = parts[2]
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
                path = "/vms/console"; detailID = parts[2]
            }
        } else if parts.count == 3, parts[0] == "status", parts[1] == "incidents" {
            path = "/status"; detailID = parts[2]
        }

        if path == "/profile", url.path == "/dashboard/system/ssh-keys" {
            section = "ssh-keys"
        }
        if path == "/status", url.path == "/status/incidents" {
            section = "incidents"
        }
        if path == "/status", queryValue("history") == "true" {
            section = "history"
        }
        if path == "/system/hosts", url.path == "/dashboard/system/console" {
            detailID = queryValue("host")
        }
        if path == "/sandbox", let runID = queryValue("run"), !runID.isEmpty {
            path = "/sandbox/report"
            detailID = runID
        }

        if path == "/cases" || path == "/cases/intelligence", detailID != nil {
            caseContext = BrowserCaseHandoffContext(
                organizationID: queryValue("organizationId"),
                alertID: queryValue("alertId"),
                route: queryValue("route")
            )
        }
        if path == "/cases", let currentDetailID = detailID,
           currentDetailID.range(of: #"^MON-[0-9]+$"#, options: [.regularExpression, .caseInsensitive]) != nil {
            // The website redirects old monitoring IDs to the HA namespace.
            // Preserve the numeric suffix while giving the native case screen
            // the same canonical identifier.
            detailID = "HA-" + String(currentDetailID.dropFirst(4))
        }
        if let requestedDetailID = detailID {
            guard let decodedID = requestedDetailID.removingPercentEncoding else { return nil }
            if allowsCompositeDetailID {
                let components = decodedID.split(separator: "/").map(String.init)
                guard !components.isEmpty,
                      components.allSatisfy({ NativeRouteSelection.resolve($0, among: [$0]) != nil }) else { return nil }
            } else {
                guard NativeRouteSelection.resolve(decodedID, among: [decodedID]) != nil else { return nil }
            }
            detailID = decodedID
        }
        // Unknown owned routes still enter the native dashboard container, where its
        // default panel explains that the requested route has no native feature yet.
        let label = path == "/dashboard" ? "Dashboard" : path.split(separator: "/").last.map { $0.replacingOccurrences(of: "-", with: " ").capitalized } ?? "Hanasand"
        return BrowserNativeRoute(path: path, label: label, detailID: detailID, caseContext: caseContext, section: section, query: routeQuery)
    }

    static func hasNativeDestination(for path: String) -> Bool {
        NativeDashboardDetail.hasNativePanel(for: path)
            || NativeAccountRoutePanel.supports(path: path)
            || ["/mail", "/browser", "/ai"].contains(path)
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
