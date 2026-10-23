import XCTest
@testable import Hanasand

final class BrowserAgentControlsLayoutTests: XCTestCase {
    func testSelectorAndTextUseStackedRowsAtMinimumWindowWidth() {
        let compactWidth = BrowserAgentControlsLayout.compactContentWidth

        XCTAssertGreaterThan(BrowserAgentControlsLayout.combinedRowMinimumWidth, compactWidth)
        XCTAssertLessThanOrEqual(BrowserAgentControlsLayout.inputRowMinimumWidth, compactWidth)
        XCTAssertLessThanOrEqual(BrowserAgentControlsLayout.coordinateRowMinimumWidth, compactWidth)
    }

    func testAllAgentControlsFitTogetherAtCommonWindowWidth() {
        let wideWidth = BrowserAgentControlsLayout.wideContentWidth

        XCTAssertLessThanOrEqual(BrowserAgentControlsLayout.combinedRowMinimumWidth, wideWidth)
    }
}
