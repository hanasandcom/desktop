import XCTest
@testable import Hanasand

final class NativeShareWorkspaceNavigationTests: XCTestCase {
    func testShareManagerOpenSelectsNativeShareWorkspaceDetail() {
        let destination = NativeShareManagerNavigation.destination(
            shareID: "share-123", availableShareIDs: ["share-123", "another"]
        )
        XCTAssertEqual(destination?.path, "/s")
        XCTAssertEqual(destination?.detailID, "share-123")
    }

    func testUnknownShareCannotOpenNativeWorkspace() {
        XCTAssertNil(NativeShareManagerNavigation.destination(
            shareID: "missing", availableShareIDs: ["share-123"]
        ))
    }
}
