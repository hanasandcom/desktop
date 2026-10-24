import XCTest
@testable import Hanasand

final class DevicePhotoReviewNativePanelTests: XCTestCase {
    func testKeepAndDiscardAdvanceThroughTheLoadedPage() {
        var progress = DevicePhotoReviewProgress()
        let ids = ["first", "second", "third"]

        progress.record(.keep, for: "first", photoIDs: ids)
        progress.record(.discard, for: "second", photoIDs: ids)

        XCTAssertEqual(progress.index, 2)
        XCTAssertEqual(progress.decisions["first"], .keep)
        XCTAssertEqual(progress.discardedIDs, ["second"])
    }

    func testUndoReturnsToTheLastDecisionAndRemovesItsPendingDeletion() {
        var progress = DevicePhotoReviewProgress()
        let ids = ["first", "second"]
        progress.record(.keep, for: "first", photoIDs: ids)
        progress.record(.discard, for: "second", photoIDs: ids)

        XCTAssertEqual(progress.undo(photoIDs: ids), "second")
        XCTAssertEqual(progress.index, 1)
        XCTAssertNil(progress.decisions["second"])
        XCTAssertTrue(progress.discardedIDs.isEmpty)
    }

    func testSuccessfulDeleteResetsReviewLikeMobileFlow() {
        var progress = DevicePhotoReviewProgress()
        let ids = ["first", "delete-me", "current"]
        progress.record(.keep, for: "first", photoIDs: ids)
        progress.record(.discard, for: "delete-me", photoIDs: ids)

        progress.resetAfterSuccessfulDeletion()

        XCTAssertEqual(progress.index, 0)
        XCTAssertTrue(progress.decisions.isEmpty)
        XCTAssertTrue(progress.history.isEmpty)
        XCTAssertTrue(progress.discardedIDs.isEmpty)
    }

    func testOutOfOrderDecisionDoesNotChangeProgress() {
        var progress = DevicePhotoReviewProgress()
        let ids = ["first", "second"]

        progress.record(.discard, for: "second", photoIDs: ids)

        XCTAssertEqual(progress.index, 0)
        XCTAssertTrue(progress.decisions.isEmpty)
        XCTAssertTrue(progress.history.isEmpty)
    }
}
