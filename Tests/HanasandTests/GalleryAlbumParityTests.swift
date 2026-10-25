import XCTest
@testable import Hanasand

final class GalleryAlbumParityTests: XCTestCase {
    func testMixedImageAndVideoAddsUseMediaNeutralFeedback() {
        XCTAssertEqual(
            GalleryAlbumAddFeedback.message(added: 2, requested: 3, itemName: "items"),
            "Added 2 of 3 selected items. 1 skipped because they were already in the album or unavailable to this account."
        )
        XCTAssertEqual(GalleryAlbumAddFeedback.message(added: 2, requested: 2, itemName: "items"), "Added all 2 selected items.")
    }
}
