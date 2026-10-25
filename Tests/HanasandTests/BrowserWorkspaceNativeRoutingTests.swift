import XCTest
@testable import Hanasand

final class BrowserWorkspaceNativeRoutingTests: XCTestCase {
    func testInternalWebsiteURLsResolveToNativeRoutesOrNativeFallbacks() {
        XCTAssertEqual(
            BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/automations?view=health")?.path,
            "/dashboard/automations"
        )
        XCTAssertEqual(
            BrowserWorkspaceModel.nativeRoute(for: "https://mail.hanasand.com")?.path,
            "/mail"
        )
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://status.hanasand.com/api/status?history=true")?.path, "/status")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://support.hanasand.com/tickets")?.path, "/support")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://scanner.hanasand.com/api")?.path, "/scanner")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://identity.hanasand.com")?.path, "/identity")
        XCTAssertEqual(
            BrowserWorkspaceModel.nativeRoute(for: "https://ti.hanasand.com/dashboard/ti/runs")?.path,
            "/ti/runs"
        )
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/test/run-123"), BrowserNativeRoute(path: "/test", label: "Test", detailID: "run-123", caseContext: nil))
        let caseRoute = BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/cases/MON-123?organizationId=org-9&alertId=alert-7&route=alert_queue")
        XCTAssertEqual(caseRoute?.path, "/cases")
        XCTAssertEqual(caseRoute?.detailID, "MON-123")
        XCTAssertEqual(caseRoute?.caseContext, BrowserCaseHandoffContext(organizationID: "org-9", alertID: "alert-7", route: "alert_queue"))
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/s/share-123")?.detailID, "share-123")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/g/gallery-123")?.detailID, "gallery-123")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/profile/user-123")?.path, "/users")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/profile/user-123")?.detailID, "user-123")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/articles/article-123")?.path, "/content/articles")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/articles/article-123")?.detailID, "article-123")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/thoughts/thought-123")?.path, "/content/thoughts")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/thoughts/thought-123")?.detailID, "thought-123")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/not-native-yet")?.path, "/not-native-yet")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/logs/search")?.path, "/logs/search")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/rules/match/rule-123")?.path, "/rules/match")
        XCTAssertEqual(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/dashboard/cases/case-123")?.path, "/cases")
        XCTAssertNil(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/g/%2E%2E"))
        XCTAssertNil(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com/g/a%2Fb"))
        XCTAssertNil(BrowserWorkspaceModel.nativeRoute(for: "https://hanasand.com.evil.example/dashboard"))
        XCTAssertNil(BrowserWorkspaceModel.nativeRoute(for: "https://example.com/dashboard"))
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
