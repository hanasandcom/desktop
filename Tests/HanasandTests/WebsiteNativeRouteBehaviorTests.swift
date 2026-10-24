import XCTest
@testable import Hanasand

final class WebsiteNativeRouteBehaviorTests: XCTestCase {
    func testRepresentativeWebsiteContextsArriveAtRegisteredNativeDestinations() {
        let cases = [
            HandoffCase(
                url: "https://hanasand.com/dashboard/findings/cases/case-54?organizationId=org-9&alertId=alert-8&route=alert_queue",
                path: "/cases",
                detailID: "case-54",
                query: ["organizationId": "org-9", "alertId": "alert-8", "route": "alert_queue"],
                caseContext: BrowserCaseHandoffContext(organizationID: "org-9", alertID: "alert-8", route: "alert_queue")
            ),
            HandoffCase(
                url: "https://hanasand.com/profile/user-31/sessions",
                path: "/profile",
                detailID: "user-31",
                section: "sessions"
            ),
            HandoffCase(
                url: "https://hanasand.com/dashboard/ti/sources/source-42?organizationId=org-12&scope=global",
                path: "/ti/sources",
                detailID: "source-42",
                query: ["organizationId": "org-12", "scope": "global"]
            ),
            HandoffCase(
                url: "https://hanasand.com/dashboard/vms/vm-84/console?provisioning=1",
                path: "/vms/console",
                detailID: "vm-84",
                query: ["provisioning": "1"]
            ),
            HandoffCase(
                url: "https://hanasand.com/dashboard/system/console?host=host-17",
                path: "/system/hosts",
                detailID: "host-17",
                query: ["host": "host-17"]
            ),
            HandoffCase(
                url: "https://hanasand.com/dashboard/automations?view=cron",
                path: "/automation/cron",
                query: ["view": "cron"]
            ),
            HandoffCase(
                url: "https://hanasand.com/status/incidents/incident-25",
                path: "/status",
                detailID: "incident-25"
            )
        ]

        for handoffCase in cases {
            let workspace = BrowserWorkspaceModel()
            workspace.configure(settings: HanasandDesktopSettings())
            let startingTabCount = workspace.groups.flatMap(\.tabs).count
            var receivedRoute: BrowserNativeRoute?
            workspace.onOpenNativeRoute = { route in
                receivedRoute = route
                return NativeDashboardDetail.hasNativePanel(for: route.path)
            }

            workspace.open(label: "Website route", url: handoffCase.url)

            XCTAssertEqual(receivedRoute?.path, handoffCase.path, handoffCase.url)
            XCTAssertEqual(receivedRoute?.detailID, handoffCase.detailID, handoffCase.url)
            XCTAssertEqual(receivedRoute?.section, handoffCase.section, handoffCase.url)
            XCTAssertEqual(receivedRoute?.query, handoffCase.query, handoffCase.url)
            XCTAssertEqual(receivedRoute?.caseContext, handoffCase.caseContext, handoffCase.url)
            XCTAssertTrue(NativeDashboardDetail.hasNativePanel(for: handoffCase.path), handoffCase.url)
            XCTAssertEqual(workspace.groups.flatMap(\.tabs).count, startingTabCount, handoffCase.url)
            XCTAssertEqual(workspace.selectedTab?.statusText, "Opened in native Desktop", handoffCase.url)
        }
    }

    func testProfileSubroutesPreserveTheSelectedSectionAtNativeHandoff() {
        let sections = ["profile", "security", "sessions", "ssh-keys"]

        for section in sections {
            let workspace = BrowserWorkspaceModel()
            workspace.configure(settings: HanasandDesktopSettings())
            var receivedRoute: BrowserNativeRoute?
            workspace.onOpenNativeRoute = { route in
                receivedRoute = route
                return NativeDashboardDetail.hasNativePanel(for: route.path)
            }

            workspace.open(label: "Profile section", url: "https://hanasand.com/profile/user-23/\(section)")

            XCTAssertEqual(receivedRoute?.path, "/profile", section)
            XCTAssertEqual(receivedRoute?.detailID, "user-23", section)
            XCTAssertEqual(receivedRoute?.section, section, section)
            XCTAssertTrue(NativeDashboardDetail.hasNativePanel(for: receivedRoute?.path ?? ""), section)
            XCTAssertEqual(workspace.selectedTab?.statusText, "Opened in native Desktop", section)
        }
    }

    @MainActor
    func testProfileSubrouteHandoffKeepsAccountIdentitySeparateFromSection() {
        let model = DesktopAgentModel()
        let originalSettings = model.settings
        var testSettings = originalSettings
        testSettings.userID = "user-23"
        testSettings.authToken = ""
        model.settings = testSettings
        defer { model.settings = originalSettings }

        let routes: [(url: String, expectedSection: String)] = [
            ("https://hanasand.com/profile/user-23/sessions?source=route-test", "sessions"),
            ("https://hanasand.com/profile/user-23/security?source=route-test", "security"),
            ("https://hanasand.com/profile/user-23/ssh-keys?source=route-test", "ssh-keys"),
            ("https://hanasand.com/dashboard/system/ssh-keys?source=route-test", "ssh-keys"),
        ]

        for item in routes {
            guard let route = BrowserWorkspaceModel.nativeRoute(for: item.url) else {
                XCTFail("Expected native route for \(item.url)")
                continue
            }

            XCTAssertTrue(model.openNativeHanasandRoute(route, loadData: false), item.url)
            XCTAssertEqual(model.selectedDashboardPath, "/profile", item.url)
            XCTAssertEqual(model.selectedNativeDashboardDetailID, "user-23", item.url)
            XCTAssertEqual(model.selectedNativeDashboardQuery["section"], item.expectedSection, item.url)
            XCTAssertEqual(model.selectedNativeDashboardQuery["source"], "route-test", item.url)
        }
    }

    @MainActor
    func testNonSelfProfileSubrouteHandoffKeepsPublicUserIdentityAndQuery() {
        let model = DesktopAgentModel()
        let originalSettings = model.settings
        var testSettings = originalSettings
        testSettings.userID = "user-23"
        testSettings.authToken = ""
        model.settings = testSettings
        defer { model.settings = originalSettings }

        let url = "https://hanasand.com/profile/user-99/sessions?source=route-test"
        guard let route = BrowserWorkspaceModel.nativeRoute(for: url) else {
            XCTFail("Expected native route for \(url)")
            return
        }

        XCTAssertTrue(model.openNativeHanasandRoute(route, loadData: false), url)
        XCTAssertEqual(model.selectedDashboardPath, "/public-profile", url)
        XCTAssertEqual(model.selectedNativeDashboardDetailID, "user-99", url)
        XCTAssertEqual(model.selectedNativeDashboardQuery["source"], "route-test", url)
    }
}

private struct HandoffCase {
    let url: String
    let path: String
    var detailID: String? = nil
    var section: String? = nil
    var query: [String: String] = [:]
    var caseContext: BrowserCaseHandoffContext? = nil
}
