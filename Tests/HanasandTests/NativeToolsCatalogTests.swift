import XCTest
@testable import Hanasand

final class NativeToolsCatalogTests: XCTestCase {
    func testGroupsExistingDashboardRoutesWithoutAddingDestinations() {
        let dashboard = [
            DesktopAction.route("Findings", "Investigate alerts.", "scope", "/findings"),
            DesktopAction.route("Mail", "Open Mail.", "envelope", "/mail"),
            DesktopAction.route("Traffic", "Inspect traffic.", "arrow.left.arrow.right", "/traffic"),
        ]

        let sections = NativeToolsCatalog.sections(dashboard: dashboard, administration: [])

        XCTAssertEqual(sections.map(\.title), ["Security & intelligence", "Infrastructure", "Workspace & content"])
        XCTAssertEqual(sections.flatMap(\.actions).map(\.title), ["Findings", "Traffic", "Mail"])
        XCTAssertEqual(Set(sections.flatMap(\.actions).compactMap(\.routePath)), Set(["/findings", "/mail", "/traffic"]))
    }

    func testSearchMatchesNamesDescriptionsAndCategoryAndOmitsEmptySections() {
        let dashboard = [
            DesktopAction.route("API Reference", "Search endpoint and schema docs.", "doc", "/api"),
            DesktopAction.route("Password Check", "Check a password against breach ranges.", "key", "/pwned"),
            DesktopAction.route("Traffic", "Inspect live traffic and maps.", "map", "/traffic"),
        ]

        XCTAssertEqual(NativeToolsCatalog.sections(dashboard: dashboard, administration: [], query: "schema").flatMap(\.actions).map(\.title), ["API Reference"])
        XCTAssertEqual(NativeToolsCatalog.sections(dashboard: dashboard, administration: [], query: "security").flatMap(\.actions).map(\.title), ["Password Check"])
        XCTAssertEqual(NativeToolsCatalog.sections(dashboard: dashboard, administration: [], query: "nothing").count, 0)
    }

    func testUnclassifiedAndNonRouteActionsDoNotLeakIntoNativeCatalog() {
        let dashboard = [
            DesktopAction.route("External integration", "An unimplemented destination.", "puzzlepiece", "/external-integration"),
            DesktopAction.url("Website", "Open website.", "safari", "https://hanasand.com"),
        ]

        XCTAssertTrue(NativeToolsCatalog.sections(dashboard: dashboard, administration: []).isEmpty)
    }

    func testCollectionRunsAndCaptureHistoryAreNativeDestinations() {
        let intelligence = [
            DesktopAction.route("Collection Runs", "Review global intelligence collection runs.", "clock.arrow.circlepath", "/ti/runs"),
            DesktopAction.route("Capture History", "Review safe source capture metadata.", "doc.text.magnifyingglass", "/ti/captures"),
        ]

        let sections = NativeToolsCatalog.sections(dashboard: intelligence, administration: [])

        XCTAssertEqual(sections.map(\.title), ["Security & intelligence"])
        XCTAssertEqual(sections.flatMap(\.actions).map(\.title), ["Collection Runs", "Capture History"])
        XCTAssertEqual(sections[0].actions.compactMap(\.routePath), ["/ti/runs", "/ti/captures"])
    }

    func testParityRoutesAreDiscoverableInTheirNativeSections() {
        let dashboard = [
            DesktopAction.route("Health Checks", "Monitor services.", "heart", "/automation/health"),
            DesktopAction.route("Sandbox History", "Review saved runs.", "square.stack.3d.up", "/sandbox"),
            DesktopAction.route("Personal Cron Jobs", "Schedule jobs.", "calendar", "/automation/cron"),
            DesktopAction.route("Service Status", "View public checks and incidents.", "heart.text.square", "/status"),
            DesktopAction.route("Security Scanner", "Run organization scans.", "stethoscope", "/scanner"),
            DesktopAction.route("CDN Image Library", "Browse private images.", "photo", "/images/library"),
        ]
        let administration = [
            DesktopAction.route("OpenAPI JSON", "View raw API contract.", "curlybraces", "/api/openapi"),
            DesktopAction.route("Realtime Logs", "Review recent events.", "waveform", "/logs/realtime"),
            DesktopAction.route("Search Logs", "Search log events.", "doc.text.magnifyingglass", "/logs/search"),
            DesktopAction.route("Error History", "Triage application errors.", "ladybug", "/logs/errors"),
            DesktopAction.route("Organization Workspace", "Manage organization settings.", "building", "/organization-workspace"),
            DesktopAction.route("Organization Team", "Manage organization members.", "person.2", "/organizations/team"),
            DesktopAction.route("Organization Settings", "Review organization settings.", "slider", "/organizations/settings"),
            DesktopAction.route("Organization Events", "Review organization events.", "list", "/organizations/events"),
            DesktopAction.route("Organization Activity", "Review organization activity.", "clock", "/organizations/activity"),
        ]

        let sections = NativeToolsCatalog.sections(dashboard: dashboard, administration: administration)
        let routesBySection = Dictionary(uniqueKeysWithValues: sections.map { ($0.title, Set($0.actions.compactMap(\.routePath))) })

        XCTAssertEqual(routesBySection["Workspace & content"], Set(["/automation/health", "/automation/cron", "/images/library"]))
        XCTAssertEqual(routesBySection["Infrastructure"], Set(["/status"]))
        XCTAssertEqual(routesBySection["Security & intelligence"], Set(["/sandbox", "/scanner"]))
        XCTAssertEqual(routesBySection["Administration"], Set(["/logs/realtime", "/logs/search", "/logs/errors"]))
        XCTAssertEqual(routesBySection["Account & API"], Set(["/api/openapi"]))
        XCTAssertEqual(routesBySection["Organization"], Set([
            "/organization-workspace", "/organizations/team", "/organizations/settings", "/organizations/events", "/organizations/activity",
        ]))
    }

    func testAuthenticatorIsDiscoverableInTheNativeToolsCatalog() {
        let action = DesktopAction.route(
            "Authenticator",
            "Generate verification codes stored in this Mac’s Keychain.",
            "key.horizontal",
            "/authenticator"
        )

        let sections = NativeToolsCatalog.sections(dashboard: [action], administration: [], query: "authenticator")

        XCTAssertEqual(sections.flatMap(\.actions).map(\.title), ["Authenticator"])
        XCTAssertTrue(NativeDashboardDetail.hasNativePanel(for: "/authenticator"))
    }
}

private extension DesktopAction {
    var routePath: String? {
        guard case .route(let path) = kind else { return nil }
        return path
    }
}
