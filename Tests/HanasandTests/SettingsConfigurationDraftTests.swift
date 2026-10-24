import XCTest
@testable import Hanasand

final class SettingsConfigurationDraftTests: XCTestCase {
    func testDraftAppliesConfigurationWithoutReplacingSessionState() {
        var current = HanasandDesktopSettings()
        current.authToken = "current-session-token"
        current.userID = "current-user"
        current.impersonationToken = "current-impersonation-token"
        current.selectedOrganizationID = "organization-current"

        var draft = NativeSettingsConfigurationDraft(settings: current)
        draft.apiBaseURL = "https://api.example.test/v2"
        draft.rdpHost = "desktop.example.test:5900"

        let updated = draft.applying(to: current)

        XCTAssertEqual(updated.apiBaseURL, "https://api.example.test/v2")
        XCTAssertEqual(updated.rdpHost, "desktop.example.test:5900")
        XCTAssertEqual(updated.authToken, "current-session-token")
        XCTAssertEqual(updated.userID, "current-user")
        XCTAssertEqual(updated.impersonationToken, "current-impersonation-token")
        XCTAssertEqual(updated.selectedOrganizationID, "organization-current")
        XCTAssertEqual(current.apiBaseURL, HanasandDesktopSettings().apiBaseURL, "Editing the draft must not mutate live settings.")
    }

    func testInvalidEndpointDraftFailsValidationAndEmptyOptionalServerIsAllowed() {
        let current = HanasandDesktopSettings()
        var draft = NativeSettingsConfigurationDraft(settings: current)
        draft.apiBaseURL = "not a secure endpoint"

        XCTAssertFalse(draft.applying(to: current).hasValidEndpoints)

        draft.apiBaseURL = current.apiBaseURL
        draft.serverBaseURL = ""
        XCTAssertTrue(draft.applying(to: current).hasValidEndpoints)
    }
}
