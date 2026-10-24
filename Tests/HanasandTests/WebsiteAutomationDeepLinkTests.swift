import XCTest
@testable import Hanasand

final class WebsiteAutomationDeepLinkTests: XCTestCase {
    func testAutomationSetupAliasKeepsQueryForNativeCreateFlow() throws {
        let route = try XCTUnwrap(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/automation?setup=dwm"))

        XCTAssertEqual(route.path, "/dashboard/automation")
        XCTAssertEqual(route.query["setup"], "dwm")
        XCTAssertTrue(NativeDashboardDetail.hasNativePanel(for: route.path))
        XCTAssertEqual(
            NativeAutomationRoute.resolve(path: route.path, query: route.query),
            .overview(initialAutomationID: nil, startsInCreate: true)
        )
    }

    func testHealthMonitorDeepLinkSelectsNativeCheck() throws {
        let route = try XCTUnwrap(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/automation/health?monitor=check-42"))

        XCTAssertEqual(route.path, "/automation/health")
        XCTAssertTrue(NativeDashboardDetail.hasNativePanel(for: route.path))
        XCTAssertEqual(
            NativeAutomationRoute.resolve(path: route.path, query: route.query),
            .health(initialAutomationID: "check-42", startsInCreate: false)
        )
    }

    func testSystemCronScopeOpensSystemPanelNatively() throws {
        let route = try XCTUnwrap(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/automation/cron?scope=system"))

        XCTAssertEqual(route.path, "/automation/cron")
        XCTAssertTrue(NativeDashboardDetail.hasNativePanel(for: route.path))
        XCTAssertEqual(NativeAutomationRoute.resolve(path: route.path, query: route.query), .systemCron)
    }
}
