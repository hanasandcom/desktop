import Foundation

struct NativeToolsSection: Identifiable {
    let title: String
    let actions: [DesktopAction]

    var id: String { title }
}

enum NativeToolsCatalog {
    static func sections(dashboard: [DesktopAction], administration: [DesktopAction], query: String = "") -> [NativeToolsSection] {
        let searchableQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let actions = dashboard + administration
        let categories: [(String, (DesktopAction) -> Bool)] = [
            ("Security & intelligence", { action in
                ["/cases", "/ti", "/ti/activity", "/ti/profiles", "/ti/sources", "/ti/runs", "/ti/captures", "/ti/timeliness", "/watchlists", "/dashboard/delivery-history", "/traffic/recent", "/traffic/map", "/findings", "/findings/actions", "/rules/match", "/rules/analysis", "/rules/detection", "/rules/tuning", "/sandbox", "/pwned", "/scanner", "/authenticator"].contains(action.routePath)
            }),
            ("Infrastructure", { action in
                ["/status", "/system/hosts", "/system/updates", "/traffic", "/traffic/blocklist", "/system/ai", "/system/rates", "/system/cron", "/system", "/system/containers", "/vms"].contains(action.routePath)
            }),
            ("Workspace & content", { action in
                ["/dashboard", "/mail", "/support", "/thesis", "/dashboard/automations", "/automation/health", "/automation/cron", "/notes", "/s", "/repositories", "/g", "/dashboard/tests", "/content/articles", "/content/thoughts", "/images/library", "/scan"].contains(action.routePath)
            }),
            ("Organization", { action in
                ["/organization-privacy", "/subscription", "/organization-api-keys", "/integrations", "/dashboard/management/service-accounts", "/organization-workspace", "/organizations/team", "/organizations/settings", "/organizations/events", "/organizations/activity"].contains(action.routePath)
            }),
            ("Account & API", { action in
                ["/api", "/api/openapi", "/profile"].contains(action.routePath)
            }),
            ("Administration", { action in
                ["/logs", "/logs/realtime", "/logs/search", "/logs/errors", "/db", "/db/backups", "/db/restore", "/vulnerability-findings", "/management", "/users", "/role", "/organizations"].contains(action.routePath)
            }),
        ]

        return categories.compactMap { title, belongs in
            let matching = actions.filter { action in
                guard belongs(action) else { return false }
                guard !searchableQuery.isEmpty else { return true }
                let searchTerms = [action.title, action.subtitle, title] + searchAliases(for: action)
                return searchTerms.contains { $0.localizedCaseInsensitiveContains(searchableQuery) }
            }
            return matching.isEmpty ? nil : NativeToolsSection(title: title, actions: matching)
        }
    }

    private static func searchAliases(for action: DesktopAction) -> [String] {
        switch action.routePath {
        case "/ti": ["Threat Search"]
        case "/ti/profiles": ["Actors"]
        case "/ti/sources": ["Feeds"]
        case "/dashboard/delivery-history": ["Delivery"]
        case "/traffic/map": ["Live map"]
        case "/pwned": ["Check Password"]
        case "/support": ["Support Chats"]
        case "/organization-privacy": ["Privacy & Retention"]
        case "/api": ["API Docs"]
        default: []
        }
    }
}

private extension DesktopAction {
    var routePath: String {
        switch kind {
        case .route(let path):
            return path
        case .url(let value):
            _ = value
            return ""
        case .task:
            return ""
        }
    }
}
