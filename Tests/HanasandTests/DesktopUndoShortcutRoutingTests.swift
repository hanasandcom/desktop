import XCTest
@testable import Hanasand

final class DesktopUndoShortcutRoutingTests: XCTestCase {
    func testCommandShiftZStaysWithImageUndoOnlyWhileImagesIsSelected() {
        XCTAssertEqual(
            DesktopUndoShortcutRouting.commandShiftZTarget(section: .images, dashboardPath: nil),
            .undoImageDecision
        )
        XCTAssertEqual(
            DesktopUndoShortcutRouting.commandShiftZTarget(section: .dashboard, dashboardPath: "/thesis"),
            .redoThesisDraft
        )
        XCTAssertNil(DesktopUndoShortcutRouting.commandShiftZTarget(section: .dashboard, dashboardPath: "/traffic"))
        XCTAssertNil(DesktopUndoShortcutRouting.commandShiftZTarget(section: .control, dashboardPath: "/thesis"))
    }
}
