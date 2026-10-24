import XCTest
@testable import Hanasand

final class WebsitePageRouteCoverageTests: XCTestCase {
    private struct ExpectedRoute {
        let path: String
        var detailID: String? = nil
        var section: String? = nil
    }
    // Generated from the website's App Router page inventory on 2026-10-24.
    // Dynamic templates are exercised with representative values so every page
    // family must resolve to a native screen rather than the route fallback.
    private let websitePagePatterns = [
            "/about",
            "/account-pending-deletion",
            "/activity",
            "/ai",
            "/ai/[id]",
            "/ai/window",
            "/api",
            "/api/openapi",
            "/article",
            "/article/[...id]",
            "/articles",
            "/articles/[id]",
            "/contact",
            "/cookie-settings",
            "/cookies",
            "/dashboard",
            "/dashboard/api-docs",
            "/dashboard/article",
            "/dashboard/article/[...id]",
            "/dashboard/articles",
            "/dashboard/articles/[...id]",
            "/dashboard/articles/create",
            "/dashboard/automation",
            "/dashboard/automation/cron",
            "/dashboard/automation/health",
            "/dashboard/automation/monitoring",
            "/dashboard/backup",
            "/dashboard/cases",
            "/dashboard/cases/[id]",
            "/dashboard/db",
            "/dashboard/db/backups",
            "/dashboard/db/restore",
            "/dashboard/findings",
            "/dashboard/findings/actions",
            "/dashboard/findings/actors",
            "/dashboard/findings/alerts",
            "/dashboard/findings/cases",
            "/dashboard/findings/cases/[id]",
            "/dashboard/findings/delivery",
            "/dashboard/findings/sources",
            "/dashboard/findings/watchlists",
            "/dashboard/load-testing",
            "/dashboard/logs",
            "/dashboard/logs/errors",
            "/dashboard/logs/realtime",
            "/dashboard/logs/search",
            "/dashboard/mail",
            "/dashboard/management",
            "/dashboard/management/[...id]",
            "/dashboard/management/organizations",
            "/dashboard/management/service-accounts",
            "/dashboard/management/users",
            "/dashboard/notes",
            "/dashboard/overview",
            "/dashboard/projects",
            "/dashboard/repositories",
            "/dashboard/rules",
            "/dashboard/rules/[id]",
            "/dashboard/rules/analysis",
            "/dashboard/rules/analysis/[id]",
            "/dashboard/rules/detection",
            "/dashboard/rules/detection/[id]",
            "/dashboard/rules/match",
            "/dashboard/rules/match/[id]",
            "/dashboard/rules/tuning",
            "/dashboard/scanner",
            "/dashboard/shares",
            "/dashboard/subscription",
            "/dashboard/system",
            "/dashboard/system/[...id]",
            "/dashboard/system/[section]",
            "/dashboard/system/ai",
            "/dashboard/system/console",
            "/dashboard/system/hosts",
            "/dashboard/system/rates",
            "/dashboard/system/ssh-keys",
            "/dashboard/system/updates",
            "/dashboard/thesis",
            "/dashboard/thought",
            "/dashboard/thought/[...id]",
            "/dashboard/thought/create",
            "/dashboard/thoughts",
            "/dashboard/thoughts/[...id]",
            "/dashboard/thoughts/create",
            "/dashboard/ti",
            "/dashboard/ti/activity",
            "/dashboard/ti/control",
            "/dashboard/ti/enrichment",
            "/dashboard/ti/evaluation",
            "/dashboard/ti/runs",
            "/dashboard/ti/sources",
            "/dashboard/ti/sources/[id]",
            "/dashboard/ti/timeliness",
            "/dashboard/ti/workbench",
            "/dashboard/traffic",
            "/dashboard/traffic/blocklist",
            "/dashboard/traffic/map",
            "/dashboard/traffic/recent",
            "/dashboard/vm",
            "/dashboard/vm/[...id]",
            "/dashboard/vms",
            "/dashboard/vms/[...id]",
            "/dashboard/vms/[name]/console",
            "/dashboard/vulnerabilities",
            "/developers",
            "/faq",
            "/g",
            "/g/[...id]",
            "/g/stats",
            "/gallery",
            "/login",
            "/logout",
            "/monitor",
            "/notes",
            "/organizations",
            "/organizations/[section]",
            "/organizations/activity",
            "/organizations/events",
            "/organizations/settings",
            "/organizations/team",
            "/organizations/watchlists",
            "/organizations/api-keys",
            "/organizations/privacy",
            "/p/[...id]",
            "/",
            "/pricing",
            "/privacy",
            "/profile",
            "/profile/[...id]",
            "/project/[...id]",
            "/pwned",
            "/register",
            "/reserved-usernames",
            "/reset-password",
            "/reset-password-again",
            "/s",
            "/s/[...id]",
            "/sandbox",
            "/sandbox/[id]",
            "/sandbox/report",
            "/secure-account",
            "/signup",
            "/solutions/scanner",
            "/solutions/security-monitoring",
            "/status",
            "/status/incidents",
            "/status/incidents/[id]",
            "/support",
            "/switch-account",
            "/terms",
            "/test",
            "/test/[...id]",
            "/test/stats",
            "/thesis",
            "/thought/[...id]",
            "/thoughts/[...id]",
            "/ti",
            "/ti/[query]",
            "/ti/darkweb/index",
            "/upload",
            "/user",
            "/user/[...id]",
            "/users",
            "/users/[...id]",
    ]

    // Explicit App Router template -> native destination crosswalk. Grouping
    // templates by destination keeps the inventory reviewable while ensuring
    // every website page has a deliberate native feature mapping.
    private var expectedNativeRoutes: [String: ExpectedRoute] {
        var routes: [String: ExpectedRoute] = [:]
        func add(_ path: String, _ patterns: [String]) {
            for pattern in patterns { routes[pattern] = ExpectedRoute(path: path) }
        }
        add("/about", ["/about"])
        add("/account-pending-deletion", ["/account-pending-deletion"])
        add("/activity", ["/activity"])
        add("/ai", ["/ai", "/ai/[id]"])
        add("/ai/workspace", ["/ai/window"])
        add("/api", ["/api", "/dashboard/api-docs"])
        add("/api/openapi", ["/api/openapi"])
        add("/public-articles", ["/article", "/articles"])
        add("/public-article", ["/article/[...id]", "/articles/[id]"])
        add("/contact", ["/contact"])
        add("/cookie-settings", ["/cookie-settings"])
        add("/cookies", ["/cookies"])
        add("/dashboard", ["/dashboard", "/dashboard/overview", "/dashboard/ti/evaluation"])
        add("/content/articles", ["/dashboard/article", "/dashboard/article/[...id]", "/dashboard/articles", "/dashboard/articles/[...id]", "/dashboard/articles/create"])
        add("/automation/cron", ["/dashboard/automation/cron"])
        add("/automation/health", ["/dashboard/automation/health", "/dashboard/automation/monitoring"])
        add("/dashboard/automation", ["/dashboard/automation"])
        add("/db/backups", ["/dashboard/backup", "/dashboard/db/backups"])
        add("/cases", ["/dashboard/cases", "/dashboard/cases/[id]", "/dashboard/findings/alerts", "/dashboard/findings/cases", "/dashboard/findings/cases/[id]"])
        add("/db", ["/dashboard/db"])
        add("/db/restore", ["/dashboard/db/restore"])
        add("/findings", ["/dashboard/findings"])
        add("/findings/actions", ["/dashboard/findings/actions"])
        add("/dashboard/delivery-history", ["/dashboard/findings/delivery"])
        add("/ti/profiles", ["/dashboard/findings/actors"])
        add("/watchlists", ["/dashboard/findings/watchlists"])
        add("/ti/sources", ["/dashboard/findings/sources"])
        add("/load-testing", ["/dashboard/load-testing"])
        add("/logs", ["/dashboard/logs"])
        add("/logs/errors", ["/dashboard/logs/errors"])
        add("/logs/realtime", ["/dashboard/logs/realtime"])
        add("/logs/search", ["/dashboard/logs/search"])
        add("/mail", ["/dashboard/mail"])
        add("/management", ["/dashboard/management"])
        add("/vms", ["/dashboard/management/[...id]"])
        add("/organizations", ["/dashboard/management/organizations"])
        add("/dashboard/management/service-accounts", ["/dashboard/management/service-accounts"])
        add("/users", ["/dashboard/management/users"])
        add("/notes", ["/dashboard/notes", "/notes"])
        add("/repositories", ["/dashboard/projects", "/dashboard/repositories"])
        add("/rules/match", ["/dashboard/rules"])
        add("/rules/detail", ["/dashboard/rules/[id]"])
        add("/rules/analysis", ["/dashboard/rules/analysis", "/dashboard/rules/analysis/[id]"])
        add("/rules/detection", ["/dashboard/rules/detection", "/dashboard/rules/detection/[id]"])
        add("/rules/match", ["/dashboard/rules/match", "/dashboard/rules/match/[id]"])
        add("/rules/tuning", ["/dashboard/rules/tuning"])
        add("/scanner", ["/dashboard/scanner", "/dashboard/vulnerabilities"])
        add("/repositories", ["/dashboard/shares"])
        add("/subscription", ["/dashboard/subscription"])
        add("/system", ["/dashboard/system"])
        add("/vms", ["/dashboard/system/[...id]"])
        add("/system/containers", ["/dashboard/system/[section]"])
        add("/system/ai", ["/dashboard/system/ai"])
        add("/system/hosts", ["/dashboard/system/console", "/dashboard/system/hosts"])
        add("/system/rates", ["/dashboard/system/rates"])
        add("/profile", ["/dashboard/system/ssh-keys"])
        add("/system/updates", ["/dashboard/system/updates"])
        add("/thesis", ["/dashboard/thesis", "/thesis"])
        add("/content/thoughts", ["/dashboard/thought", "/dashboard/thought/[...id]", "/dashboard/thought/create", "/dashboard/thoughts", "/dashboard/thoughts/[...id]", "/dashboard/thoughts/create"])
        add("/notes", ["/thought/[...id]", "/thoughts/[...id]"])
        add("/ti/overview", ["/dashboard/ti"])
        add("/ti/activity", ["/dashboard/ti/activity"])
        add("/ti/runs", ["/dashboard/ti/control", "/dashboard/ti/runs"])
        add("/ti/enrichment", ["/dashboard/ti/enrichment"])
        add("/ti/sources", ["/dashboard/ti/sources", "/dashboard/ti/sources/[id]"])
        add("/ti/timeliness", ["/dashboard/ti/timeliness"])
        add("/ti/workbench", ["/dashboard/ti/workbench"])
        add("/traffic", ["/dashboard/traffic"])
        add("/traffic/blocklist", ["/dashboard/traffic/blocklist"])
        add("/traffic/map", ["/dashboard/traffic/map"])
        add("/traffic/recent", ["/dashboard/traffic/recent"])
        add("/vms", ["/dashboard/vm", "/dashboard/vms"])
        add("/vms/console", ["/dashboard/vm/[...id]", "/dashboard/vms/[...id]"])
        add("/vms/console", ["/dashboard/vms/[name]/console"])
        add("/developers", ["/developers"])
        add("/faq", ["/faq"])
        add("/g", ["/g", "/g/stats", "/g/[...id]"])
        add("/images/library", ["/gallery"])
        add("/login", ["/login"])
        add("/logout", ["/logout"])
        add("/monitor", ["/monitor"])
        add("/organizations", ["/organizations"])
        add("/organizations/events", ["/organizations/[section]"])
        add("/organizations/activity", ["/organizations/activity"])
        add("/organizations/events", ["/organizations/events"])
        add("/organizations/settings", ["/organizations/settings"])
        add("/organizations/team", ["/organizations/team"])
        add("/watchlists", ["/organizations/watchlists"])
        add("/organization-api-keys", ["/organizations/api-keys"])
        add("/organization-privacy", ["/organizations/privacy"])
        add("/s", ["/p/[...id]", "/s", "/s/[...id]"])
        add("/", ["/"])
        add("/pricing", ["/pricing"])
        add("/privacy", ["/privacy"])
        add("/profile", ["/profile", "/profile/[...id]"])
        add("/s", ["/project/[...id]"])
        add("/pwned", ["/pwned"])
        add("/register", ["/register"])
        add("/signup", ["/signup"])
        add("/reserved-usernames", ["/reserved-usernames"])
        add("/reset-password", ["/reset-password"])
        add("/reset-password-again", ["/reset-password-again"])
        add("/sandbox", ["/sandbox"])
        add("/sandbox/result", ["/sandbox/[id]"])
        add("/sandbox/report", ["/sandbox/report"])
        add("/secure-account", ["/secure-account"])
        add("/solutions/scanner", ["/solutions/scanner"])
        add("/solutions/security-monitoring", ["/solutions/security-monitoring"])
        add("/status", ["/status"])
        add("/status", ["/status/incidents", "/status/incidents/[id]"])
        add("/support", ["/support"])
        add("/switch-account", ["/switch-account"])
        add("/terms", ["/terms"])
        add("/test", ["/test", "/test/[...id]", "/test/stats"])
        add("/ti", ["/ti", "/ti/[query]"])
        add("/ti/darkweb/index", ["/ti/darkweb/index"])
        add("/upload", ["/upload"])
        add("/dashboard", ["/user", "/users"])
        add("/profile", ["/user/[...id]", "/users/[...id]"])
        return routes
    }

    private func examplePath(for pattern: String) -> String {
        let path = pattern
            .replacingOccurrences(of: "/dashboard/vms/[...id]", with: "/dashboard/vms/vm-sample/console")
            .replacingOccurrences(of: "/dashboard/vm/[...id]", with: "/dashboard/vm/vm-sample/console")
            .replacingOccurrences(of: "/dashboard/system/[...id]", with: "/dashboard/system/vm-sample")
            .replacingOccurrences(of: "/dashboard/management/[...id]", with: "/dashboard/management/vm-sample/console")
            .replacingOccurrences(of: "/dashboard/articles/[...id]", with: "/dashboard/articles/article-sample/section")
            .replacingOccurrences(of: "/dashboard/thoughts/[...id]", with: "/dashboard/thoughts/thought-sample/section")
            .replacingOccurrences(of: "/dashboard/thought/[...id]", with: "/dashboard/thought/thought-sample/section")
            .replacingOccurrences(of: "/g/[...id]", with: "/g/folder-sample/entry-sample")
            .replacingOccurrences(of: "/s/[...id]", with: "/s/share-sample/folder/entry")
            .replacingOccurrences(of: "/p/[...id]", with: "/p/project-sample/folder/entry")
            .replacingOccurrences(of: "/project/[...id]", with: "/project/project-sample/folder/entry")
            .replacingOccurrences(of: "/profile/[...id]", with: "/profile/user-sample/sessions")
            .replacingOccurrences(of: "/user/[...id]", with: "/user/user-sample/folder/entry")
            .replacingOccurrences(of: "/users/[...id]", with: "/users/user-sample/folder/entry")
            .replacingOccurrences(of: "/thoughts/[...id]", with: "/thoughts/thought-sample/section")
            .replacingOccurrences(of: "/thought/[...id]", with: "/thought/thought-sample/section")
            .replacingOccurrences(of: "/article/[...id]", with: "/article/article-sample/section")
            .replacingOccurrences(of: "/test/[...id]", with: "/test/run-sample/section")
            .replacingOccurrences(of: "[...id]", with: "route-sample")
            .replacingOccurrences(of: "[id]", with: "route-sample")
            .replacingOccurrences(of: "[name]", with: "vm-sample")
            .replacingOccurrences(of: "[query]", with: "search")
            .replacingOccurrences(of: "/organizations/[section]", with: "/organizations/alerts")
            .replacingOccurrences(of: "/dashboard/system/[section]", with: "/dashboard/system/containers")
        if pattern == "/sandbox/report" { return path + "?run=run-sample&token=report-token" }
        return path
    }

    func testEveryWebsitePagePatternHasANativeDestination() {
        let expectedRoutes = expectedNativeRoutes
        XCTAssertEqual(Set(expectedRoutes.keys), Set(websitePagePatterns), "Every website template must have exactly one explicit native destination")
        for pattern in websitePagePatterns {
            guard let expected = expectedRoutes[pattern] else { continue }
            let routePath = examplePath(for: pattern)
            guard let route = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com\(routePath)") else {
                XCTFail("Website route did not resolve: \(pattern)")
                continue
            }
            XCTAssertEqual(route.path, expected.path, "Website route \(pattern) should hand off to its deliberate native feature")
            XCTAssertTrue(
                BrowserWorkspaceModel.hasNativeDestination(for: route.path),
                "Website route \(pattern) resolves to \(route.path), which has no native screen"
            )
            switch pattern {
            case "/ai/[id]": XCTAssertEqual(route.detailID, "route-sample", pattern)
            case "/article/[...id]": XCTAssertEqual(route.detailID, "article-sample", pattern)
            case "/articles/[id]": XCTAssertEqual(route.detailID, "route-sample", pattern)
            case "/dashboard/cases/[id]", "/dashboard/findings/cases/[id]", "/dashboard/rules/[id]", "/dashboard/rules/analysis/[id]", "/dashboard/rules/detection/[id]", "/dashboard/rules/match/[id]", "/dashboard/ti/sources/[id]":
                XCTAssertEqual(route.detailID, "route-sample", pattern)
            case "/dashboard/articles/[...id]": XCTAssertEqual(route.detailID, "article-sample", pattern)
            case "/dashboard/thought/[...id]", "/dashboard/thoughts/[...id]": XCTAssertEqual(route.detailID, "thought-sample", pattern)
            case "/dashboard/management/[...id]": XCTAssertEqual(route.detailID, "vm-sample", pattern)
            case "/dashboard/system/[...id]": XCTAssertEqual(route.detailID, "vm-sample", pattern)
            case "/dashboard/vm/[...id]", "/dashboard/vms/[...id]":
                XCTAssertEqual(route.detailID, "vm-sample", pattern)
                XCTAssertEqual(route.path, "/vms/console", pattern)
            case "/dashboard/vms/[name]/console": XCTAssertEqual(route.detailID, "vm-sample", pattern)
            case "/g/[...id]":
                XCTAssertEqual(route.detailID, "folder-sample", pattern)
            case "/p/[...id]", "/project/[...id]", "/s/[...id]":
                XCTAssertEqual(route.detailID, pattern == "/s/[...id]" ? "share-sample" : "project-sample", pattern)
                XCTAssertEqual(route.section, "folder/entry", pattern)
            case "/profile/[...id]":
                XCTAssertEqual(route.detailID, "user-sample", pattern)
                XCTAssertEqual(route.section, "sessions", pattern)
            case "/thought/[...id]", "/thoughts/[...id]":
                XCTAssertNil(route.detailID, "The website redirects public thought URLs to /notes without preserving the ID")
                XCTAssertEqual(route.path, "/notes", pattern)
            case "/test/[...id]": XCTAssertEqual(route.detailID, "run-sample", pattern)
            case "/user/[...id]", "/users/[...id]": XCTAssertEqual(route.detailID, "user-sample", pattern)
            case "/organizations/[section]": XCTAssertEqual(route.path, "/organizations/events", pattern)
            case "/dashboard/system/[section]": XCTAssertEqual(route.path, "/system/containers", pattern)
            default: break
            }
        }
    }

    func testEveryWebsitePagePatternHandsOffNativelyWithoutOpeningAWebTab() {
        let workspace = BrowserWorkspaceModel()
        workspace.configure(settings: HanasandDesktopSettings())
        let initialTabCount = workspace.groups.flatMap(\.tabs).count
        var receivedRoutes: [BrowserNativeRoute] = []
        workspace.onOpenNativeRoute = { route in
            receivedRoutes.append(route)
            return BrowserWorkspaceModel.hasNativeDestination(for: route.path)
        }

        for pattern in websitePagePatterns {
            let routePath = examplePath(for: pattern)

            workspace.open(label: "Website route", url: "https://hanasand.com\(routePath)")

            XCTAssertEqual(workspace.groups.flatMap(\.tabs).count, initialTabCount, "\(pattern) opened a web tab")
            XCTAssertEqual(workspace.selectedTab?.statusText, "Opened in native Desktop", "\(pattern) did not complete the native handoff")
        }

        XCTAssertEqual(receivedRoutes.count, websitePagePatterns.count)
    }

    func testLegacyWebsiteRedirectRoutesAlsoHandOffToNativeFeatures() {
        let legacyURLs = [
            "https://hanasand.com/prompt",
            "https://hanasand.com/.well-known",
            "https://hanasand.com/.well-known/security.txt",
            "https://hanasand.com/findings/watchlists",
            "https://hanasand.com/ti/enrichment",
            "https://hanasand.com/ti/profiles",
            "https://hanasand.com/ti/domains/example.com",
            "https://hanasand.com/dashboard/ti/domains/example.com",
            "https://hanasand.com/api/openapi/ti",
            "https://hanasand.com/cases/MON-42",
            "https://hanasand.com/dashboard/cases/MON-42",
            "https://hanasand.com/dwm",
            "https://hanasand.com/dwm/cases/HA-42",
            "https://hanasand.com/dashboard/dwm/cases/HA-43",
            "https://hanasand.com/solutions/dwm",
            "https://hanasand.com/solutions/onion-session",
            "https://hanasand.com/vulnerabilities",
        ]
        let workspace = BrowserWorkspaceModel()
        workspace.configure(settings: HanasandDesktopSettings())
        let initialTabCount = workspace.groups.flatMap(\.tabs).count
        var handedOffPaths: [String] = []
        workspace.onOpenNativeRoute = { route in
            handedOffPaths.append(route.path)
            return BrowserWorkspaceModel.hasNativeDestination(for: route.path)
        }

        for url in legacyURLs {
            guard let route = BrowserWorkspaceModel.nativeRoute(for: url) else {
                XCTFail("Legacy website redirect did not resolve: \(url)")
                continue
            }
            XCTAssertTrue(BrowserWorkspaceModel.hasNativeDestination(for: route.path), "\(url) resolves to unsupported native route \(route.path)")
            workspace.open(label: "Legacy route", url: url)
            XCTAssertEqual(workspace.groups.flatMap(\.tabs).count, initialTabCount, "\(url) opened a web tab")
            XCTAssertEqual(workspace.selectedTab?.statusText, "Opened in native Desktop", "\(url) did not complete native handoff")
        }

        XCTAssertEqual(handedOffPaths, [
            "/ai", "/security.txt", "/security.txt", "/watchlists", "/ti/enrichment", "/ti/enrichment",
            "/ti/sources", "/ti/sources", "/api/openapi", "/cases", "/cases", "/findings", "/cases",
            "/cases", "/findings", "/browser", "/scanner",
        ])
    }

    func testCanonicalWebsiteRedirectsResolveToNativeDestinationsAndPreserveContext() {
        let redirects: [(url: String, path: String, detailID: String?, query: [String: String])] = [
            ("https://hanasand.com/thoughts/thought-42", "/notes", nil, [:]),
            ("https://hanasand.com/thought/thought-42", "/notes", nil, [:]),
            ("https://hanasand.com/dashboard/shares", "/repositories", nil, [:]),
            ("https://hanasand.com/users", "/dashboard", nil, [:]),
            ("https://hanasand.com/user", "/dashboard", nil, [:]),
            ("https://hanasand.com/dashboard/findings?panel=actions&org=org-7", "/integrations", nil, ["panel": "actions", "org": "org-7"]),
            ("https://hanasand.com/dashboard/findings?panel=alerts&organizationId=org-7", "/cases", nil, ["panel": "alerts", "organizationId": "org-7"]),
        ]
        let workspace = BrowserWorkspaceModel()
        workspace.configure(settings: HanasandDesktopSettings())
        let initialTabCount = workspace.groups.flatMap(\.tabs).count
        workspace.onOpenNativeRoute = { BrowserWorkspaceModel.hasNativeDestination(for: $0.path) }

        for redirect in redirects {
            guard let route = BrowserWorkspaceModel.nativeRoute(for: redirect.url) else {
                XCTFail("Website redirect did not resolve: \(redirect.url)")
                continue
            }
            XCTAssertEqual(route.path, redirect.path, redirect.url)
            XCTAssertEqual(route.detailID, redirect.detailID, redirect.url)
            XCTAssertEqual(route.query, redirect.query, redirect.url)
            XCTAssertTrue(BrowserWorkspaceModel.hasNativeDestination(for: route.path), redirect.url)

            workspace.open(label: "Canonical redirect", url: redirect.url)
            XCTAssertEqual(workspace.groups.flatMap(\.tabs).count, initialTabCount, "\(redirect.url) opened a web tab")
            XCTAssertEqual(workspace.selectedTab?.statusText, "Opened in native Desktop", redirect.url)
        }
    }
}
