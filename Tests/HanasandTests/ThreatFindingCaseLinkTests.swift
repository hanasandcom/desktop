import XCTest
@testable import Hanasand

final class ThreatFindingCaseLinkTests: XCTestCase {
    func testBuildsNativeScopedCaseDestination() throws {
        let destination = try XCTUnwrap(ThreatFindingCaseDestination.make(
            caseID: "case:@42",
            alertID: "finding-42",
            organizationID: "org:@one"
        ))

        XCTAssertEqual(destination.caseID, "case:@42")
        XCTAssertEqual(destination.alertID, "finding-42")
        XCTAssertEqual(destination.organizationID, "org:@one")
        XCTAssertEqual(destination.query, ["organizationId": "org:@one", "alertId": "finding-42"])
    }

    func testPersonalCaseKeepsAlertContextWithoutOrganizationScope() throws {
        let destination = try XCTUnwrap(ThreatFindingCaseDestination.make(
            caseID: "case-1",
            alertID: "alert-1",
            organizationID: nil
        ))

        XCTAssertEqual(destination.query, ["alertId": "alert-1"])
    }

    func testRejectsMalformedCaseAlertOrOrganizationReferences() {
        XCTAssertNil(ThreatFindingCaseDestination.make(caseID: "../other", alertID: "alert-1", organizationID: nil))
        XCTAssertNil(ThreatFindingCaseDestination.make(caseID: "case-1", alertID: "alert/1", organizationID: nil))
        XCTAssertNil(ThreatFindingCaseDestination.make(caseID: "case-1", alertID: "alert-1", organizationID: "org/other"))
    }
}
