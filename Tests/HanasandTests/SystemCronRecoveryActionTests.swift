import Foundation
import XCTest
@testable import Hanasand

final class SystemCronRecoveryActionTests: XCTestCase {
    func testControlRationalePreservesServiceAssumptionsAndModes() throws {
        let envelope = try JSONDecoder().decode(DesktopCronJobsEnvelope.self, from: Data(#"{"jobs":[{"id":"audit","name":"Observed worker","status":"observable","controls":[],"controlMode":"observable_only","assumptions":["The startup-owned worker cannot be safely restarted here.","Replay belongs to the evaluation API."]},{"id":"safe","name":"Safe worker","status":"enabled","controls":["pause","run_now"],"controlMode":"safe_control","assumptions":[]},{"id":"run-only","name":"Run worker","status":"enabled","controls":["run_now"],"controlMode":"run_only"},{"id":"editable","name":"Editable worker","status":"enabled","controls":["pause","edit_schedule"],"controlMode":"editable"},{"id":"malformed","name":"Unknown worker","status":"unknown","controls":[],"controlMode":"future_mode","assumptions":"not an array"}]}"#.utf8))

        let audit = try XCTUnwrap(envelope.jobs.first(where: { $0.id == "audit" }))
        XCTAssertEqual(audit.controlSummary, "Audit only")
        XCTAssertEqual(audit.assumptions, ["The startup-owned worker cannot be safely restarted here.", "Replay belongs to the evaluation API."])
        let safe = try XCTUnwrap(envelope.jobs.first(where: { $0.id == "safe" }))
        XCTAssertEqual(safe.controlSummary, "Safe pause/resume and run now")
        XCTAssertTrue(safe.assumptions.isEmpty)
        XCTAssertEqual(envelope.jobs.first(where: { $0.id == "run-only" })?.controlSummary, "Run now supported")
        XCTAssertEqual(envelope.jobs.first(where: { $0.id == "editable" })?.controlSummary, "Pause/resume and schedule edit")
        let malformed = try XCTUnwrap(envelope.jobs.first(where: { $0.id == "malformed" }))
        XCTAssertEqual(malformed.controlSummary, "No controls available")
        XCTAssertTrue(malformed.assumptions.isEmpty)
    }

    func testProminentRunActionIncludesFailedJobsThatCanBeRetried() throws {
        let envelope = try JSONDecoder().decode(DesktopCronJobsEnvelope.self, from: Data(#"{"jobs":[{"id":"failed-job","name":"Failed worker","status":"failed","failureCount":3,"controls":["run_now"],"running":false},{"id":"healthy-job","name":"Healthy worker","status":"enabled","controls":["run_now"],"running":false}]}"#.utf8))

        XCTAssertEqual(DesktopCronActionRules.runnableJob(in: envelope.jobs)?.id, "failed-job")
    }

    func testProminentRunActionSkipsRunningOrUnsupportedJobs() throws {
        let envelope = try JSONDecoder().decode(DesktopCronJobsEnvelope.self, from: Data(#"{"jobs":[{"id":"running-job","name":"Running worker","status":"running","controls":["run_now"],"running":true},{"id":"observable-job","name":"Observed worker","status":"failed","controls":[],"running":false}]}"#.utf8))

        XCTAssertNil(DesktopCronActionRules.runnableJob(in: envelope.jobs))
    }
}
