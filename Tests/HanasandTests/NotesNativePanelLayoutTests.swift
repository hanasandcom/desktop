import XCTest
@testable import Hanasand

final class NotesNativePanelLayoutTests: XCTestCase {
    func testNarrowContentStacksNotesListAboveEditor() {
        XCTAssertTrue(NotesNativePanelLayout.usesStackedLayout(contentWidth: 639))
        XCTAssertTrue(NotesNativePanelLayout.usesStackedLayout(contentWidth: 560))
        XCTAssertFalse(NotesNativePanelLayout.usesStackedLayout(contentWidth: 720))
        XCTAssertFalse(NotesNativePanelLayout.usesStackedLayout(contentWidth: 760))
    }

    func testWideContentUsesBoundedSidebarAndPreservesEditorSpace() {
        let width: CGFloat = 984
        let sidebar = NotesNativePanelLayout.sidebarWidth(contentWidth: width)

        XCTAssertEqual(sidebar, 260)
        XCTAssertGreaterThanOrEqual(width - sidebar - 16, 400)
    }

    func testSidebarWidthScalesDownWithoutBecomingUnusable() {
        XCTAssertEqual(NotesNativePanelLayout.sidebarWidth(contentWidth: 760), 243.2, accuracy: 0.001)
        XCTAssertEqual(NotesNativePanelLayout.sidebarWidth(contentWidth: 600), 200)
    }
}
