import XCTest
@testable import Hanasand

final class MonitoringCaseTests: XCTestCase {
    private func decode(_ json: String) throws -> MonitoringCase {
        try JSONDecoder().decode(MonitoringCase.self, from: Data(json.utf8))
    }

    func testDecodesVerifiedMonitoringCaseAndSearchesExpectedFields() throws {
        let item = try decode("""
        {"id":"HA-7","source":"monitoring","organizationId":null,"title":"HA-7 · API health","summary":"Connection timed out","status":"open","severity":"high","canManage":true,"assignedOwner":"user-a","automationId":"auto-1","createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-02T00:00:00Z","lastSeenAt":"2026-01-02T00:00:00Z","resolvedAt":"","occurrences":3,"notificationsEnabled":true,"resolution":null}
        """)
        XCTAssertTrue(item.contains("timed out"))
        XCTAssertTrue(item.contains("user-a"))
        XCTAssertTrue(item.contains("HA-7"))
        XCTAssertFalse(item.contains("not present"))
        XCTAssertEqual(item.status, "open")
    }

    func testRejectsCasesOutsideExpectedScopeOrWithInvalidState() throws {
        let valid = """
        {"id":"HA-7","source":"monitoring","organizationId":null,"status":"open","severity":"high","canManage":true,"occurrences":1,"notificationsEnabled":true}
        """
        for json in [
            valid.replacingOccurrences(of: "monitoring", with: "intelligence"),
            valid.replacingOccurrences(of: "\"open\"", with: "\"unknown\""),
            valid.replacingOccurrences(of: "HA-7", with: "case-7"),
        ] {
            XCTAssertThrowsError(try decode(json))
        }
    }

    func testAcceptsSelectedOrganizationCasesAndRejectsMissingOrForeignScope() throws {
        let organizationCase = try decode("""
        {"id":"HA-7","source":"monitoring","organizationId":"org-1","status":"open","severity":"high","canManage":true,"occurrences":1,"notificationsEnabled":true}
        """)
        XCTAssertTrue(MonitoringCase.matchesOrganizationScope(organizationId: organizationCase.organizationId, selectedOrganizationID: "org-1"))
        XCTAssertFalse(MonitoringCase.matchesOrganizationScope(organizationId: nil, selectedOrganizationID: "org-1"))
        XCTAssertFalse(MonitoringCase.matchesOrganizationScope(organizationId: "org-other", selectedOrganizationID: "org-1"))
    }

    func testPersonalScopeStillRequiresUnownedMonitoringCase() throws {
        let personalCase = try decode("""
        {"id":"HA-7","source":"monitoring","organizationId":null,"status":"open","severity":"high","canManage":true,"occurrences":1,"notificationsEnabled":true}
        """)
        XCTAssertTrue(MonitoringCase.matchesOrganizationScope(organizationId: personalCase.organizationId, selectedOrganizationID: "personal"))
        XCTAssertTrue(MonitoringCase.matchesOrganizationScope(organizationId: personalCase.organizationId, selectedOrganizationID: ""))
        XCTAssertFalse(MonitoringCase.matchesOrganizationScope(organizationId: "org-1", selectedOrganizationID: "personal"))
    }

    func testAcceptsEveryWebsiteCaseStatusFilterValue() throws {
        let base = """
        {"id":"HA-7","source":"monitoring","organizationId":null,"severity":"high","canManage":true,"occurrences":1,"notificationsEnabled":true}
        """
        for status in ["open", "in_progress", "escalated", "resolved", "closed", "suppressed", "false_positive"] {
            let item = try decode(base.replacingOccurrences(of: "\"severity\":", with: "\"status\":\"\(status)\",\"severity\":"))
            XCTAssertEqual(item.status, status)
        }
    }

    func testAIResolutionMethodRequiresResolvedOrClosedStatus() {
        XCTAssertTrue(MonitoringCaseResolutionPolicy.allowsResolutionMethod(nil, status: "open"))
        XCTAssertTrue(MonitoringCaseResolutionPolicy.allowsResolutionMethod("ai", status: "resolved"))
        XCTAssertTrue(MonitoringCaseResolutionPolicy.allowsResolutionMethod("ai", status: "closed"))
        XCTAssertFalse(MonitoringCaseResolutionPolicy.allowsResolutionMethod("ai", status: "open"))
        XCTAssertFalse(MonitoringCaseResolutionPolicy.allowsResolutionMethod("human", status: "resolved"))
        XCTAssertFalse(MonitoringCaseResolutionPolicy.allowsResolutionMethod("ai", status: nil))
    }

    func testHealthCheckLinkUsesNativeMonitorRouteContract() {
        XCTAssertEqual(MonitoringCaseNativeRoute.healthCheckPath, "/automation/health")
        XCTAssertEqual(MonitoringCaseNativeRoute.healthCheckQuery(automationID: "health-check-71"), ["monitor": "health-check-71"])
        XCTAssertNil(MonitoringCaseNativeRoute.healthCheckQuery(automationID: "  "))
    }

    func testOrganizationQueryMatchesMobileScopeAndOmitsPersonalScope() {
        XCTAssertEqual(MonitoringCaseNativeRoute.organizationQuery(selectedOrganizationID: " org-1 "), [URLQueryItem(name: "organizationId", value: "org-1")])
        XCTAssertTrue(MonitoringCaseNativeRoute.organizationQuery(selectedOrganizationID: "personal").isEmpty)
        XCTAssertTrue(MonitoringCaseNativeRoute.organizationQuery(selectedOrganizationID: "").isEmpty)
    }

    func testDetectsPendingHumanReviewOnlyForUnconfirmedAiOrAutomationResolution() throws {
        let base = """
        {"id":"HA-7","source":"monitoring","organizationId":null,"status":"resolved","severity":"medium","canManage":false,"occurrences":1,"notificationsEnabled":true,"resolution":{"id":"event-1","type":"ai"}}
        """
        XCTAssertTrue(try decode(base).needsHumanReview)
        XCTAssertFalse(try decode(base.replacingOccurrences(of: "\"type\":\"ai\"", with: "\"type\":\"human\"" )).needsHumanReview)
        XCTAssertFalse(try decode(base.replacingOccurrences(of: "\"type\":\"ai\"", with: "\"type\":\"ai\",\"confirmedAt\":\"2026-01-01T00:00:00Z\"" )).needsHumanReview)
    }
}
