import AppKit
import XCTest
@testable import Hanasand

final class ImageReviewTrashOutcomeTests: XCTestCase {
    func testFailedTrashMovesRemainPendingWhileSuccessfulMovesAreReported() {
        let moved = item("moved.jpg")
        let failed = item("failed.jpg")

        let outcome = ImageReviewTrashOutcome.moveToTrash([moved, failed]) { url in
            if url.lastPathComponent == "failed.jpg" {
                throw NSError(domain: "ImageReviewTrashOutcomeTests", code: 1)
            }
        }

        XCTAssertEqual(outcome.movedIDs, [moved.id])
        XCTAssertEqual(outcome.failedTitles, ["failed.jpg"])
        XCTAssertFalse(outcome.movedIDs.contains(failed.id))
    }

    func testSuccessfulTrashMovesReportEveryRemovedItem() {
        let items = [item("one.jpg"), item("two.jpg")]

        let outcome = ImageReviewTrashOutcome.moveToTrash(items) { _ in }

        XCTAssertEqual(outcome.movedIDs, Set(items.map(\.id)))
        XCTAssertTrue(outcome.failedTitles.isEmpty)
    }

    private func item(_ name: String) -> DesktopImageReviewItem {
        DesktopImageReviewItem(url: URL(fileURLWithPath: "/tmp/\(name)"), image: NSImage(size: CGSize(width: 1, height: 1)))
    }
}
