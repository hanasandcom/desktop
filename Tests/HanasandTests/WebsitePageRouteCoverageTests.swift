import XCTest
@testable import Hanasand

final class WebsitePageRouteCoverageTests: XCTestCase {
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
            "/sandbox/_browser/browser",
            "/sandbox/_browser/browser/[id]",
            "/sandbox/_browser/browser/report",
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

    func testEveryWebsitePagePatternHasANativeDestination() {
        for pattern in websitePagePatterns {
            let routePath = pattern
                .replacingOccurrences(of: "[...id]", with: "route-sample")
                .replacingOccurrences(of: "[id]", with: "route-sample")
                .replacingOccurrences(of: "[name]", with: "vm-sample")
                .replacingOccurrences(of: "[query]", with: "search")
                .replacingOccurrences(of: "/organizations/[section]", with: "/organizations/alerts")
                .replacingOccurrences(of: "/dashboard/system/[section]", with: "/dashboard/system/containers")
            guard let route = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com\(routePath)") else {
                XCTFail("Website route did not resolve: \(pattern)")
                continue
            }
            XCTAssertTrue(
                BrowserWorkspaceModel.hasNativeDestination(for: route.path),
                "Website route \(pattern) resolves to \(route.path), which has no native screen"
            )
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
            let routePath = pattern
                .replacingOccurrences(of: "[...id]", with: "route-sample")
                .replacingOccurrences(of: "[id]", with: "route-sample")
                .replacingOccurrences(of: "[name]", with: "vm-sample")
                .replacingOccurrences(of: "[query]", with: "search")
                .replacingOccurrences(of: "/organizations/[section]", with: "/organizations/alerts")
                .replacingOccurrences(of: "/dashboard/system/[section]", with: "/dashboard/system/containers")

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
}
