import XCTest
@testable import Hanasand

final class IDEWorkspaceLayoutTests: XCTestCase {
    func testExpandedToolsUseCompactRailsAtMinimumSupportedContentWidth() {
        let widths = IDEWorkspaceLayout.widths(contentWidth: 695, toolsExpanded: true)

        XCTAssertGreaterThanOrEqual(widths.navigator, IDEWorkspaceLayout.compactNavigatorWidth)
        XCTAssertLessThan(widths.navigator, IDEWorkspaceLayout.navigatorWidth)
        XCTAssertGreaterThanOrEqual(widths.tools, IDEWorkspaceLayout.compactExpandedToolsWidth)
        XCTAssertLessThan(widths.tools, IDEWorkspaceLayout.expandedToolsWidth)
        XCTAssertGreaterThanOrEqual(widths.editor, IDEWorkspaceLayout.editorMinimumWidth)
        XCTAssertEqual(
            widths.navigator + widths.tools + widths.editor + IDEWorkspaceLayout.dividerWidth * 2,
            695,
            accuracy: 0.001
        )
    }

    func testExpandedLayoutPreservesFullRailWidthsWhenSpaceAllows() {
        let widths = IDEWorkspaceLayout.widths(
            contentWidth: IDEWorkspaceLayout.expandedLayoutBreakpoint,
            toolsExpanded: true
        )

        XCTAssertEqual(widths.navigator, IDEWorkspaceLayout.navigatorWidth)
        XCTAssertEqual(widths.tools, IDEWorkspaceLayout.expandedToolsWidth)
        XCTAssertEqual(widths.editor, IDEWorkspaceLayout.editorMinimumWidth, accuracy: 0.001)
    }

    func testCollapsedToolsKeepTheExistingWideNavigatorAtMinimumContentWidth() {
        let widths = IDEWorkspaceLayout.widths(contentWidth: 695, toolsExpanded: false)

        XCTAssertEqual(widths.navigator, IDEWorkspaceLayout.navigatorWidth)
        XCTAssertEqual(widths.tools, IDEWorkspaceLayout.collapsedToolsWidth)
        XCTAssertGreaterThanOrEqual(widths.editor, IDEWorkspaceLayout.editorMinimumWidth)
    }

    func testExpandedLayoutSwitchesAtBreakpointWithoutShrinkingEditorBelowMinimum() {
        let breakpoint = IDEWorkspaceLayout.expandedLayoutBreakpoint
        let atBreakpoint = IDEWorkspaceLayout.widths(contentWidth: breakpoint, toolsExpanded: true)
        let justBelowBreakpoint = IDEWorkspaceLayout.widths(contentWidth: breakpoint - 1, toolsExpanded: true)

        XCTAssertEqual(atBreakpoint.editor, IDEWorkspaceLayout.editorMinimumWidth, accuracy: 0.001)
        XCTAssertGreaterThanOrEqual(justBelowBreakpoint.editor, IDEWorkspaceLayout.editorMinimumWidth)
        XCTAssertLessThan(justBelowBreakpoint.navigator, atBreakpoint.navigator)
        XCTAssertLessThan(justBelowBreakpoint.tools, atBreakpoint.tools)
        XCTAssertLessThan(atBreakpoint.navigator - justBelowBreakpoint.navigator, 1)
        XCTAssertLessThan(atBreakpoint.tools - justBelowBreakpoint.tools, 1)
        XCTAssertGreaterThanOrEqual(695, IDEWorkspaceLayout.minimumSupportedContentWidth)
    }
}
