import Foundation
import XCTest
@testable import Hanasand

final class SystemCronRecoveryActionTests: XCTestCase {
    func testProminentRunActionIncludesFailedJobsThatCanBeRetried() throws {
        let envelope = try JSONDecoder().decode(DesktopCronJobsEnvelope.self, from: Data(#"{"jobs":[{"id":"failed-job","name":"Failed worker","status":"failed","failureCount":3,"controls":["run_now"],"running":false},{"id":"healthy-job","name":"Healthy worker","status":"enabled","controls":["run_now"],"running":false}]}"#.utf8))

        XCTAssertEqual(DesktopCronActionRules.runnableJob(in: envelope.jobs)?.id, "failed-job")
    }

    func testProminentRunActionSkipsRunningOrUnsupportedJobs() throws {
        let envelope = try JSONDecoder().decode(DesktopCronJobsEnvelope.self, from: Data(#"{"jobs":[{"id":"running-job","name":"Running worker","status":"running","controls":["run_now"],"running":true},{"id":"observable-job","name":"Observed worker","status":"failed","controls":[],"running":false}]}"#.utf8))

        XCTAssertNil(DesktopCronActionRules.runnableJob(in: envelope.jobs))
    }
}
