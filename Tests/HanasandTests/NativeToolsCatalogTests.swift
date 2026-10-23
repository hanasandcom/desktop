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

    func testParityRoutesAreDiscoverableInTheirNativeSections() {
        let dashboard = [
            DesktopAction.route("Health Checks", "Monitor services.", "heart", "/automation/health"),
            DesktopAction.route("Personal Cron Jobs", "Schedule jobs.", "calendar", "/automation/cron"),
        ]
        let administration = [
            DesktopAction.route("Realtime Logs", "Review recent events.", "waveform", "/logs/realtime"),
            DesktopAction.route("Organization Workspace", "Manage organization settings.", "building", "/organization-workspace"),
            DesktopAction.route("Organization Settings", "Review organization settings.", "slider", "/organizations/settings"),
            DesktopAction.route("Organization Events", "Review organization events.", "list", "/organizations/events"),
            DesktopAction.route("Organization Activity", "Review organization activity.", "clock", "/organizations/activity"),
        ]

        let sections = NativeToolsCatalog.sections(dashboard: dashboard, administration: administration)
        let routesBySection = Dictionary(uniqueKeysWithValues: sections.map { ($0.title, Set($0.actions.compactMap(\.routePath))) })

        XCTAssertEqual(routesBySection["Workspace & content"], Set(["/automation/health", "/automation/cron"]))
        XCTAssertEqual(routesBySection["Administration"], Set(["/logs/realtime"]))
        XCTAssertEqual(routesBySection["Organization"], Set([
            "/organization-workspace", "/organizations/settings", "/organizations/events", "/organizations/activity",
        ]))
    }
}

private extension DesktopAction {
    var routePath: String? {
        guard case .route(let path) = kind else { return nil }
        return path
    }
}
