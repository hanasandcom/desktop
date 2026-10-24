import Foundation
import XCTest

@testable import Hanasand

final class MonitoringCaseMutationOutcomeTests: XCTestCase {
    func testOnlyDispatchedUncertainWritesRequireReview() {
        XCTAssertTrue(MonitoringCaseMutationOutcome.needsReview(for: URLError(.timedOut), requestDispatched: true))
        XCTAssertTrue(MonitoringCaseMutationOutcome.needsReview(for: DashboardRequestError.httpStatus(503), requestDispatched: true))
        XCTAssertTrue(MonitoringCaseMutationOutcome.needsReview(for: DashboardRequestError.httpStatus(408), requestDispatched: true))
        XCTAssertTrue(MonitoringCaseMutationOutcome.needsReview(for: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad receipt")), requestDispatched: true))
        XCTAssertFalse(MonitoringCaseMutationOutcome.needsReview(for: DashboardRequestError.httpStatus(403), requestDispatched: true))
        XCTAssertFalse(MonitoringCaseMutationOutcome.needsReview(for: URLError(.timedOut), requestDispatched: false))
    }
}
