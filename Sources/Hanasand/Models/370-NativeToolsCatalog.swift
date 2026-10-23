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
                ["/cases", "/ti", "/ti/profiles", "/ti/sources", "/ti/runs", "/ti/timeliness", "/watchlists", "/dashboard/delivery-history", "/traffic/recent", "/traffic/map", "/findings", "/rules/match", "/rules/analysis", "/rules/detection", "/rules/tuning", "/sandbox", "/pwned", "/scanner"].contains(action.routePath)
            }),
            ("Infrastructure", { action in
                ["/status", "/system/hosts", "/system/updates", "/traffic", "/traffic/blocklist", "/system/ai", "/system/rates", "/system/cron", "/system", "/system/containers", "/vms"].contains(action.routePath)
            }),
            ("Workspace & content", { action in
                ["/dashboard", "/mail", "/support", "/thesis", "/dashboard/automations", "/automation/health", "/automation/cron", "/notes", "/s", "/repositories", "/g", "/dashboard/tests", "/content/articles", "/content/thoughts", "/images/library"].contains(action.routePath)
            }),
            ("Organization", { action in
                ["/organization-privacy", "/subscription", "/organization-api-keys", "/integrations", "/dashboard/management/service-accounts", "/organization-workspace", "/organizations/team", "/organizations/settings", "/organizations/events", "/organizations/activity"].contains(action.routePath)
            }),
            ("Account & API", { action in
                ["/api", "/api/openapi", "/profile"].contains(action.routePath)
            }),
            ("Administration", { action in
                ["/logs", "/logs/realtime", "/logs/search", "/logs/errors", "/db", "/db/backups", "/db/restore", "/vulnerabilities", "/management", "/users", "/role", "/organizations"].contains(action.routePath)
            }),
        ]

        return categories.compactMap { title, belongs in
            let matching = actions.filter { action in
                belongs(action) && (searchableQuery.isEmpty || [action.title, action.subtitle, title]
                    .contains { $0.localizedCaseInsensitiveContains(searchableQuery) })
            }
            return matching.isEmpty ? nil : NativeToolsSection(title: title, actions: matching)
        }
    }
}

private extension DesktopAction {
    var routePath: String {
        switch kind {
        case .route(let path):
            return path
        case .url(let value):
            guard let url = URL(string: value),
                  url.scheme == "https",
                  url.host == "ti.hanasand.com",
                  url.user == nil,
                  url.password == nil,
                  url.port == nil,
                  url.path == "/dashboard/ti/runs",
                  url.query == nil,
                  url.fragment == nil else { return "" }
            return "/ti/runs"
        case .task:
            return ""
        }
    }
}
