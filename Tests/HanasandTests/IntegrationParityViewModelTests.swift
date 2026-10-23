import Foundation
import XCTest
@testable import Hanasand

final class IntegrationParityViewModelTests: XCTestCase {
    func testIntegrationPageDecodesLatestTestDiagnosticsAndBlockers() throws {
        let payload = #"{"destinations":[{"id":"dest_1","orgId":"owner","name":"Alerts","kind":"discord","status":"active","endpointHint":"discord.com/...","lastTestedAt":"2026-10-23T10:00:00Z","lastTestStatus":"failed"}],"destinationLifecycle":[],"destinationTests":[{"destinationId":"dest_1","status":"test_failed","latestTest":{"requestId":"delivery_1","deliveryId":"delivery_1","status":"failed","dryRun":false,"live":true,"responseStatus":502,"error":"Remote service unavailable","attemptedAt":"2026-10-23T10:00:00Z","source":"delivery_ledger"},"access":{"canTest":false},"blockers":[{"code":"test_failed","blocking":true,"message":"Latest destination test failed."},{"code":"audit_missing","blocking":false,"message":"Destination test has no linked audit event yet."}]}],"destinationAdminProof":{"access":{"canManage":true}}}"#

        let page = try JSONDecoder().decode(IntegrationPage.self, from: Data(payload.utf8))
        let destination = try XCTUnwrap(page.destinations.first)
        let test = try XCTUnwrap(page.destinationTests.first)
        let latestTest = try XCTUnwrap(test.latestTest)

        XCTAssertEqual(destination.lastTestStatus, "failed")
        XCTAssertEqual(test.status, "test_failed")
        XCTAssertEqual(latestTest.deliveryId, "delivery_1")
        XCTAssertEqual(latestTest.responseStatus, 502)
        XCTAssertEqual(latestTest.error, "Remote service unavailable")
        XCTAssertEqual(test.blockers?.count, 2)
        XCTAssertEqual(test.blockers?.first?.code, "test_failed")
        XCTAssertEqual(test.blockers?.first?.blocking, true)
    }

    func testIntegrationPageAcceptsOlderDestinationAndTestRows() throws {
        let payload = #"{"destinations":[{"id":"dest_1","orgId":"owner","name":"Alerts","kind":"webhook","status":"active","endpointHint":null,"lastTestedAt":null}],"destinationLifecycle":[],"destinationTests":[{"destinationId":"dest_1","access":{"canTest":true},"blockers":[]}],"destinationAdminProof":{"access":{"canManage":true}}}"#

        let page = try JSONDecoder().decode(IntegrationPage.self, from: Data(payload.utf8))
        XCTAssertNil(page.destinations.first?.lastTestStatus)
        XCTAssertNil(page.destinationTests.first?.status)
        XCTAssertNil(page.destinationTests.first?.latestTest)
        XCTAssertEqual(page.destinationTests.first?.access?.canTest, true)
    }
}
