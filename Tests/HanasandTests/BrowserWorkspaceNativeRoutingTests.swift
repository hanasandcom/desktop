import XCTest
@testable import Hanasand

final class BrowserWorkspaceNativeRoutingTests: XCTestCase {
    func testCasesWorkspaceAndPluralPublicProfileRoutesKeepTheirNativeTargets() {
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/cases")?.path, "/cases")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/findings/cases")?.path, "/cases")
        let websiteDetail = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/cases/HA-41?organizationId=org-5")
        XCTAssertEqual(websiteDetail?.path, "/cases")
        XCTAssertEqual(websiteDetail?.detailID, "HA-41")
        XCTAssertEqual(websiteDetail?.caseContext?.organizationID, "org-5")
        let monitoringDetail = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/cases/MON-42")
        XCTAssertEqual(monitoringDetail?.path, "/cases")
        XCTAssertEqual(monitoringDetail?.detailID, "MON-42")
        let intelligenceDetail = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/findings/cases/case-43")
        XCTAssertEqual(intelligenceDetail?.path, "/cases")
        XCTAssertEqual(intelligenceDetail?.detailID, "case-43")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/users/person-44")?.path, "/profile")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/users/person-44")?.detailID, "person-44")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/user")?.path, "/users")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/management/users")?.path, "/users")
        let managementUser = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/management/users/user-45")
        XCTAssertEqual(managementUser?.path, "/users")
        XCTAssertEqual(managementUser?.detailID, "user-45")
        let dashboardManagementUser = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/management/users/user-46")
        XCTAssertEqual(dashboardManagementUser?.path, "/users")
        XCTAssertEqual(dashboardManagementUser?.detailID, "user-46")
        let nestedDashboardManagementVM = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/management/vm-47/console")
        XCTAssertEqual(nestedDashboardManagementVM?.path, "/vms")
        XCTAssertEqual(nestedDashboardManagementVM?.detailID, "vm-47")
        let nestedVM = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/vms/cluster-1/node-2")
        XCTAssertEqual(nestedVM?.path, "/vms")
        XCTAssertEqual(nestedVM?.detailID, "cluster-1/node-2")
    }

    func testInternalWebsiteURLsResolveToNativeRoutesOrNativeFallbacks() {
        XCTAssertEqual(
            BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/automations?view=health")?.path,
            "/automation/health"
        )
        XCTAssertEqual(
            BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/automations?view=cron")?.path,
            "/automation/cron"
        )
        XCTAssertEqual(
            BrowserWorkspaceModel.nativeRoute(for: "https://mail.hanasand.com")?.path,
            "/mail"
        )
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://status.hanasand.com/api/status?history=true")?.path, "/status")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://status.hanasand.com/api/status?history=true")?.section, "history")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/status/incidents")?.section, "incidents")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://support.hanasand.com/tickets")?.path, "/support")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://scanner.hanasand.com/api")?.path, "/scanner")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://identity.hanasand.com")?.path, "/profile")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com")?.path, "/")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/about")?.path, "/about")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/developers")?.path, "/developers")
        let destinations = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/findings/actions?org=org-22")
        XCTAssertEqual(destinations?.path, "/integrations")
        XCTAssertEqual(destinations?.query["org"], "org-22")
        let organizationCases = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/findings/alerts?organizationId=org-23")
        XCTAssertEqual(organizationCases?.path, "/cases")
        XCTAssertEqual(organizationCases?.query["organizationId"], "org-23")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/pricing")?.path, "/pricing")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/solutions/security-monitoring")?.path, "/solutions/security-monitoring")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/solutions/scanner")?.path, "/solutions/scanner")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/vulnerabilities")?.path, "/scanner")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/solutions/dwm")?.path, "/findings")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/solutions/onion-session")?.path, "/browser")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/ai/window")?.path, "/ai/workspace")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/user")?.path, "/users")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/user/user-42")?.path, "/profile")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/user/user-42")?.detailID, "user-42")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/users/user-42")?.path, "/profile")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/users/user-42")?.detailID, "user-42")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/organizations/alerts")?.path, "/organizations/events")
        let organizationWatchlists = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/organizations/watchlists?organizationId=org-24")
        XCTAssertEqual(organizationWatchlists?.path, "/watchlists")
        XCTAssertEqual(organizationWatchlists?.query["organizationId"], "org-24")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/system/containers")?.path, "/system/containers")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/ti/darkweb/index")?.path, "/ti/darkweb/index")
        let incident = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/status/incidents/incident-42")
        XCTAssertEqual(incident?.path, "/status")
        XCTAssertEqual(incident?.detailID, "incident-42")
        XCTAssertEqual(
            BrowserWorkspaceModel.nativeRoute(for: "https://ti.hanasand.com/dashboard/ti/runs")?.path,
            "/ti/runs"
        )
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/test/run-123"), BrowserNativeRoute(path: "/test", label: "Test", detailID: "run-123", caseContext: nil, section: nil, query: [:]))
        let caseRoute = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/cases/MON-123?organizationId=org-9&alertId=alert-7&route=alert_queue")
        XCTAssertEqual(caseRoute?.path, "/cases")
        XCTAssertEqual(caseRoute?.detailID, "MON-123")
        XCTAssertEqual(caseRoute?.caseContext, BrowserCaseHandoffContext(organizationID: "org-9", alertID: "alert-7", route: "alert_queue"))
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/s/share-123")?.detailID, "share-123")
        let projectFile = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/p/project-1?file=file-9")
        XCTAssertEqual(projectFile?.path, "/s")
        XCTAssertEqual(projectFile?.detailID, "project-1")
        XCTAssertEqual(projectFile?.query["file"], "file-9")
        XCTAssertEqual(projectFile?.query["workspace"], "project")
        let shareChat = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/s/share-123?chat=1&new=1")
        XCTAssertEqual(shareChat?.query["chat"], "1")
        XCTAssertEqual(shareChat?.query["new"], "1")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/g/gallery-123")?.detailID, "gallery-123")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://cdn.hanasand.com/files/file-123")?.path, "/cdn/files")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://cdn.hanasand.com/files/file-123")?.detailID, "file-123")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://cdn.hanasand.com/api/files/file-123")?.path, "/cdn/files")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://cdn.hanasand.com/shared/01234567890123456789012345678901")?.path, "/shared/album")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/profile/user-123")?.path, "/profile")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/profile/user-123")?.detailID, "user-123")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/articles/article-123")?.path, "/content/articles")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/articles/article-123")?.detailID, "article-123")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/thoughts/thought-123")?.path, "/content/thoughts")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/thoughts/thought-123")?.detailID, "thought-123")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/not-native-yet")?.path, "/not-native-yet")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/logs/search")?.path, "/logs/search")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/rules/match/rule-123")?.path, "/rules/match")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/cases")?.path, "/cases")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/cases/case-123")?.path, "/cases")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/cases/case-123")?.detailID, "case-123")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/findings/cases/case-456")?.path, "/cases")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/findings/cases/case-456")?.detailID, "case-456")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/ti/enrichment")?.path, "/ti/enrichment")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/ti/activity")?.path, "/ti/activity")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/ti/workbench")?.path, "/ti/workbench")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/ti")?.path, "/ti/overview")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/ti/control")?.path, "/ti/runs")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/ti/evaluation")?.path, "/dashboard")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/ti/captures")?.path, "/ti/captures")
        let watchlists = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/findings?panel=watchlists&organizationId=org-8")
        XCTAssertEqual(watchlists?.path, "/watchlists")
        XCTAssertEqual(watchlists?.query["organizationId"], "org-8")
        let sources = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/findings?panel=sources&org=org-6")
        XCTAssertEqual(sources?.path, "/ti/sources")
        XCTAssertEqual(sources?.query["org"], "org-6")
        let deliveries = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/findings?panel=delivery&org=org-9")
        XCTAssertEqual(deliveries?.path, "/integrations")
        XCTAssertEqual(deliveries?.query["org"], "org-9")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/findings?panel=actors")?.path, "/ti/profiles")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/documents/scanner")?.path, "/documents/scanner")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/cases/MON-123")?.path, "/cases")
        XCTAssertNil(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/g/%2E%2E"))
        XCTAssertNil(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/g/a%2Fb"))
        XCTAssertNil(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com.evil.example/dashboard"))
        XCTAssertNil(BrowserWorkspaceModel.nativeRoute(for: "https://example.com/dashboard"))
    }

    func testCanonicalMobileNavigationPathsResolveToTheirNativeWorkflows() {
        let routes: [(String, String)] = [
            ("https://hanasand.com/findings/actors", "/ti/profiles"),
            ("https://hanasand.com/findings/actions", "/integrations"),
            ("https://hanasand.com/findings/delivery", "/integrations"),
            ("https://hanasand.com/organizations/privacy", "/organization-privacy"),
            ("https://hanasand.com/organizations/api-keys", "/organization-api-keys"),
            ("https://hanasand.com/management/organizations", "/organizations"),
            ("https://hanasand.com/management/users", "/users"),
            ("https://hanasand.com/management/service-accounts", "/dashboard/management/service-accounts"),
            ("https://hanasand.com/system/virtual-machines", "/vms"),
            ("https://hanasand.com/gallery", "/images/library"),
            ("https://hanasand.com/gallery/albums", "/images/library"),
                        ("https://cdn.hanasand.com/", "/images/library"),
        ]

        for (url, expectedPath) in routes {
            XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: url)?.path, expectedPath, url)
        }
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/gallery/albums")?.section, "albums")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/upload")?.path, "/upload")

        let selfProfile = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/profile/user-123")
        XCTAssertEqual(selfProfile?.path, "/profile")
        XCTAssertEqual(selfProfile?.detailID, "user-123")

        let sessions = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/profile/user-123/sessions")
        XCTAssertEqual(sessions?.path, "/profile")
        XCTAssertEqual(sessions?.detailID, "user-123")
        XCTAssertEqual(sessions?.section, "sessions")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/profile/user-123/ssh-keys")?.section, "ssh-keys")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/profile/user-123/certificates")?.section, "ssh-keys")

        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/profile/user-123/support")?.path, "/support")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/ti/sources/source-42")?.detailID, "source-42")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/sandbox/123e4567-e89b-12d3-a456-426614174000")?.detailID, "123e4567-e89b-12d3-a456-426614174000")
        XCTAssertNil(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/test/stats")?.detailID)
        XCTAssertNil(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/g/stats")?.detailID)

        let console = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/system/console?host=ovh")
        XCTAssertEqual(console?.path, "/system/hosts")
        XCTAssertEqual(console?.detailID, "ovh")
        let vmConsole = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/vms/vm-17/console?provisioning=1")
        XCTAssertEqual(vmConsole?.path, "/vms/console")
        XCTAssertEqual(vmConsole?.detailID, "vm-17")
        XCTAssertEqual(vmConsole?.query["provisioning"], "1")
        let directVMConsole = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/vms/vm-17/console")
        XCTAssertEqual(directVMConsole?.path, "/vms/console")
        XCTAssertEqual(directVMConsole?.detailID, "vm-17")

        let storedResult = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/sandbox/123e4567-e89b-12d3-a456-426614174000?run=run-7")
        XCTAssertEqual(storedResult?.path, "/sandbox/result")
        XCTAssertEqual(storedResult?.detailID, "123e4567-e89b-12d3-a456-426614174000")
        XCTAssertEqual(storedResult?.query["run"], "run-7")
        let browserResult = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/sandbox/_browser/browser/123e4567-e89b-12d3-a456-426614174000?run=run-7")
        XCTAssertEqual(browserResult?.path, "/sandbox/result")
        XCTAssertEqual(browserResult?.detailID, "123e4567-e89b-12d3-a456-426614174000")
        XCTAssertEqual(browserResult?.query["run"], "run-7")

        let sharedReport = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/sandbox/report?run=run-7&token=report-123")
        XCTAssertEqual(sharedReport?.path, "/sandbox/report")
        XCTAssertEqual(sharedReport?.detailID, "run-7")
        XCTAssertEqual(sharedReport?.query["token"], "report-123")
    }

    func testQueryAndIdentifierContextSurvivesNativeFeatureHandoffs() {
        let actorDirectory = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/findings/actors?organizationId=org-9")
        XCTAssertEqual(actorDirectory?.path, "/ti/profiles")
        XCTAssertEqual(actorDirectory?.query["organizationId"], "org-9")

        let logs = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/logs?service=discord-bot")
        XCTAssertEqual(logs?.path, "/logs")
        XCTAssertEqual(logs?.query["service"], "discord-bot")

        let source = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/ti/sources/source-42?scope=global")
        XCTAssertEqual(source?.path, "/ti/sources")
        XCTAssertEqual(source?.detailID, "source-42")
        XCTAssertEqual(source?.query["scope"], "global")
    }

    func testAccountReturnAndResetTokensSurviveNativeRouteResolutionWithoutBeingDropped() {
        let login = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/login?path=%2Forganizations&expired=true")
        XCTAssertEqual(login?.path, "/login")
        XCTAssertEqual(login?.query["path"], "/organizations")
        XCTAssertEqual(login?.query["expired"], "true")

        let reset = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/reset-password#id=user-17&token=reset-token-abc")
        XCTAssertEqual(reset?.path, "/reset-password")
        XCTAssertEqual(reset?.query["id"], "user-17")
        XCTAssertEqual(reset?.query["token"], "reset-token-abc")
    }

    func testEveryCanonicalDashboardNavigationRouteResolvesToANativeScreenRoute() {
        let routes: [(String, String)] = [
            ("/cases", "/cases"), ("/ti", "/ti"), ("/ti/activity", "/ti/activity"),
            ("/findings/actors", "/ti/profiles"), ("/ti/profiles", "/ti/profiles"),
            ("/watchlists", "/watchlists"), ("/findings", "/findings"),
            ("/findings/actions", "/integrations"),
            ("/system/virtual-machines", "/vms"), ("/repositories", "/repositories"),
            ("/ti/sources", "/ti/sources"), ("/ti/runs", "/ti/runs"),
            ("/ti/timeliness", "/ti/timeliness"), ("/sandbox", "/sandbox"),
            ("/scanner", "/scanner"), ("/pwned", "/pwned"), ("/test", "/test"),
            ("/logs", "/logs"), ("/logs/realtime", "/logs/realtime"),
            ("/logs/search", "/logs/search"), ("/logs/errors", "/logs/errors"),
            ("/traffic", "/traffic"), ("/traffic/recent", "/traffic/recent"),
            ("/traffic/map", "/traffic/map"), ("/traffic/blocklist", "/traffic/blocklist"),
            ("/rules/match", "/rules/match"), ("/rules/analysis", "/rules/analysis"),
            ("/rules/detection", "/rules/detection"), ("/rules/tuning", "/rules/tuning"),
            ("/system", "/system"), ("/system/containers", "/system/containers"),
            ("/system/hosts", "/system/hosts"), ("/vms", "/vms"),
            ("/system/updates", "/system/updates"), ("/system/ai", "/system/ai"),
            ("/system/rates", "/system/rates"), ("/load-testing", "/load-testing"),
            ("/db", "/db"), ("/db/backups", "/db/backups"),
            ("/automation/health", "/automation/health"), ("/automation/cron", "/automation/cron"),
            ("/notes", "/notes"), ("/content/articles", "/content/articles"),
            ("/content/thoughts", "/content/thoughts"), ("/gallery", "/images/library"),
            ("/gallery/albums", "/images/library"), ("/upload", "/upload"),
            ("/mail", "/mail"), ("/support", "/support"),
            ("/organizations", "/organizations"), ("/organizations/settings", "/organizations/settings"),
            ("/organizations/privacy", "/organization-privacy"), ("/subscription", "/subscription"),
            ("/organizations/team", "/organizations/team"), ("/organizations/api-keys", "/organization-api-keys"),
            ("/management/service-accounts", "/dashboard/management/service-accounts"),
            ("/findings/delivery", "/integrations"), ("/organizations/events", "/organizations/events"),
            ("/organizations/activity", "/organizations/activity"),
            ("/management/organizations", "/organizations"), ("/management/users", "/users"),
            ("/api", "/api"), ("/api/openapi", "/api/openapi"),
            ("/profile/account-1", "/profile"), ("/profile/account-1/security", "/profile"),
            ("/profile/account-1/sessions", "/profile"), ("/profile/account-1/ssh-keys", "/profile"),
            ("/profile/account-1/support", "/support"),
        ]

        for (path, expectedNativePath) in routes {
            let route = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com\(path)")
            XCTAssertEqual(route?.path, expectedNativePath, path)
        }
    }

    func testConfiguredWebsiteOriginUsesTheSameNativeRouteClassifier() {
        let baseURL = "https://staging.example.test/"

        XCTAssertTrue(BrowserWorkspaceModel.isHanasandOwnedURL("https://staging.example.test/notes", configuredWebsiteBaseURL: baseURL))
        XCTAssertEqual(
            BrowserWorkspaceModel.nativeRoute(for: "https://staging.example.test/notes", configuredWebsiteBaseURL: baseURL)?.path,
            "/notes"
        )
        XCTAssertFalse(BrowserWorkspaceModel.isHanasandOwnedURL("https://other.example.test/notes", configuredWebsiteBaseURL: baseURL))
    }

    func testDefaultBrowserTabsDoNotLoadHanasandPages() {
        let workspace = BrowserWorkspaceModel()
        workspace.configure(settings: HanasandDesktopSettings())

        let addresses = workspace.groups.flatMap(\.tabs).map(\.address)
        XCTAssertFalse(addresses.isEmpty)
        XCTAssertFalse(addresses.contains(where: { BrowserWorkspaceModel.isHanasandOwnedURL($0) }))
    }

    func testOpeningNativeRouteHandsOffWithoutCreatingBrowserTab() {
        let workspace = BrowserWorkspaceModel()
        workspace.configure(settings: HanasandDesktopSettings())
        var opened: BrowserNativeRoute?
        workspace.onOpenNativeRoute = { route in
            opened = route
            return true
        }
        let initialTabCount = workspace.selectedGroup?.tabs.count

        workspace.open(BrowserDestination(title: "Mail", subtitle: "Inbox", icon: "envelope", url: "https://mail.hanasand.com"))

        XCTAssertEqual(opened?.path, "/mail")
        XCTAssertEqual(opened?.label, "Mail")
        XCTAssertEqual(workspace.selectedGroup?.tabs.count, initialTabCount)
        XCTAssertEqual(workspace.selectedTab?.statusText, "Opened in native Desktop")
    }

    func testUnsupportedInternalRouteIsBlockedInsteadOfOpeningInBrowser() {
        let workspace = BrowserWorkspaceModel()
        workspace.configure(settings: HanasandDesktopSettings())
        let initialTabCount = workspace.selectedGroup?.tabs.count

        workspace.open(label: "Internal page", url: "https://hanasand.com/not-native-yet")

        XCTAssertEqual(workspace.selectedGroup?.tabs.count, initialTabCount)
        XCTAssertEqual(workspace.selectedTab?.statusText, "This Hanasand page does not have a native Desktop route yet.")
    }
}
