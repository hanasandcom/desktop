import XCTest
@testable import Hanasand

final class ThreatFindingCaseLinkTests: XCTestCase {
    func testBuildsScopedAlertQueueCaseRoute() throws {
        let url = try XCTUnwrap(ThreatFindingCaseLink.url(
            siteBaseURL: "https://hanasand.com/",
            caseID: "case:@42",
            alertID: "finding-42",
            organizationID: "org:@one"
        ))

        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(url.scheme, "https")
        XCTAssertEqual(url.host, "hanasand.com")
        XCTAssertEqual(components.percentEncodedPath, "/cases/case%3A%4042")
        XCTAssertEqual(components.queryItems, [
            URLQueryItem(name: "organizationId", value: "org:@one"),
            URLQueryItem(name: "alertId", value: "finding-42"),
            URLQueryItem(name: "route", value: "alert_queue"),
        ])
    }

    func testPersonalCaseOmitsOrganizationScope() throws {
        let url = try XCTUnwrap(ThreatFindingCaseLink.url(
            siteBaseURL: "https://hanasand.com",
            caseID: "case-1",
            alertID: "alert-1",
            organizationID: nil
        ))
        XCTAssertEqual(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems, [
            URLQueryItem(name: "alertId", value: "alert-1"),
            URLQueryItem(name: "route", value: "alert_queue"),
        ])
    }

    func testRejectsInsecureOrMalformedCaseReferences() {
        XCTAssertNil(ThreatFindingCaseLink.url(siteBaseURL: "http://hanasand.com", caseID: "case-1", alertID: "alert-1", organizationID: nil))
        XCTAssertNil(ThreatFindingCaseLink.url(siteBaseURL: "https://user:pass@hanasand.com", caseID: "case-1", alertID: "alert-1", organizationID: nil))
        XCTAssertNil(ThreatFindingCaseLink.url(siteBaseURL: "https://hanasand.com", caseID: "../other", alertID: "alert-1", organizationID: nil))
        XCTAssertNil(ThreatFindingCaseLink.url(siteBaseURL: "https://hanasand.com", caseID: "case-1", alertID: "alert-1", organizationID: "org/other"))
    }
}
