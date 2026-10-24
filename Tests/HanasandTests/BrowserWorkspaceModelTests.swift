import XCTest
@testable import Hanasand

final class BrowserWorkspaceModelTests: XCTestCase {
    func testResearchGroupProvidesConfiguredSandboxDestination() {
        var settings = HanasandDesktopSettings()
        settings.websiteBaseURL = "https://example.test/"
        let workspace = BrowserWorkspaceModel()

        workspace.configure(settings: settings)

        let sandbox = workspace.groups.first(where: { $0.id == "research" })?.destinations.first(where: { $0.title == "Sandbox" })
        XCTAssertEqual(sandbox?.subtitle, "Isolated browser")
        XCTAssertEqual(sandbox?.url, "https://example.test/sandbox")
    }

    func testSandboxDestinationIsAddedOnlyOnceWhenWorkspaceIsConfiguredAgain() {
        let workspace = BrowserWorkspaceModel()
        let settings = HanasandDesktopSettings()

        workspace.configure(settings: settings)
        workspace.configure(settings: settings)

        let sandboxDestinations = workspace.groups
            .first(where: { $0.id == "research" })?.destinations
            .filter { $0.title == "Sandbox" } ?? []
        XCTAssertEqual(sandboxDestinations.count, 1)
    }
}
